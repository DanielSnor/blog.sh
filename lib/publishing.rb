# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
# For $CHILD_STATUS -- the exit status of the build and the deploy is what
# tells "the lock was busy" from "it broke", and $? does not read as either.
require 'English'
require_relative 'post_address'
require_relative 'site_config'
require_relative 'atomic_write'
require_relative 'post_writer'
require_relative 'post_versions'
require_relative 'mastodon_poster'
require_relative 'bluesky_poster'
require_relative 'i18n'
require_relative 'run_lock'

# lib/publishing.rb -- the mechanics of making a draft public, shared by
# the interactive CLI (scripts/manage_post.rb) and the scheduled-publish
# cron (scripts/publish_scheduled.rb). The split is decisions vs
# execution: the CLI owns every prompt (which date to use, whether to toot
# outside the recency window), the cron owns no prompt at all -- a schedule
# IS the decision -- and both execute through here, so the two paths can't
# drift apart.
#
# What the cron does have to decide alone is whether to ANNOUNCE, which is
# the one thing here that cannot be undone. The rules it decides by live in
# this file rather than in either caller (TOOT_RECENCY_WINDOW and the two
# predicates under it): the window was a constant inside the CLI once, and
# the caller that could not ask anybody was the caller that did not have it.
module Publishing
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  MEDIA_DIR = File.join(ROOT, 'media.nosync')

  PEREX_LENGTH = 250
  # Mastodon's default status limit -- but instances routinely raise it,
  # so mastodon.toot_length in config/site.yml can too; the perex budget
  # scales with it.
  TOOT_LENGTH = SiteConfig.get('mastodon', 'toot_length', default: 500)
  # Bluesky's limit is fixed by the AT Protocol and counted in GRAPHEMES,
  # not characters -- hence the separate composition below.
  BLUESKY_LENGTH = 300

  module_function

  def base_url
    (ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')).to_s.chomp('/')
  end

  def post_url(slug, year)
    "#{base_url}/posts/#{year}/#{slug}/"
  end

  # Moves a post's media directory into another year. Delegates to
  # PostWriter.move_media_dir for the two cautions a bare mv lacks: the
  # year folder under media.nosync/ may not exist yet (mkdir_p, or the mv
  # raises ENOENT -- that one used to kill the whole scheduled-publish
  # batch), and the target slug directory may already exist as an orphan,
  # where mv would NEST the source inside it and the page would silently
  # lose its files. One implementation, both call paths.
  def relocate_media(slug, from_year, to_year)
    return if from_year == to_year

    PostWriter.move_media_dir(File.join(MEDIA_DIR, from_year, slug),
                              File.join(MEDIA_DIR, to_year, slug))
    # The edit history is keyed by year/slug exactly like the media, so it
    # crosses the year boundary with the post too. Left behind, the [v]
    # dialog went silent and the orphaned directory sat waiting to be
    # inherited by whichever future post is born under the same year/slug
    # -- the trash has always moved versions with the post (delete and
    # restore both do); a date change owes them the same ride.
    PostVersions.move(slug, from_year, from_content_dir: CONTENT_DIR,
                      to_dir: File.join(PostVersions.versions_root(CONTENT_DIR), to_year, slug))
  end

  # Rewrites a draft as published under `date`: drops the draft-only
  # fields (draft_token, the scheduled flag), moves the JSON -- and the
  # post's media directory -- into the right year when the date changed
  # it, and returns [new_path, updated_post]. Media files themselves are
  # never rewritten, only moved.
  def publish(path, post, date:)
    slug = post['slug']
    old_year = File.basename(File.dirname(path))
    new_year = date.year.to_s

    updated = post.merge('state' => 'published', 'date' => date.iso8601)
    updated.delete('draft_token')
    updated.delete('scheduled')
    # A post that was unpublished and renamed while a draft comes back
    # under a new address; the marker cmd_unpublish left behind becomes a
    # redirect from the old one. Coming back under the SAME address just
    # consumes the marker -- and the current address is also dropped from
    # former_slugs, so a rename back to an earlier slug can never leave
    # an address redirecting to itself (or a build warning that never
    # goes away).
    # A page's debt is written as "/old-slug/" and belongs in redirect_from;
    # a post's is "<year>/<slug>" and belongs in former_slugs. One function
    # knows which (lib/post_address.rb), because this was decided in five
    # places and each got it wrong at a different time.
    PostAddress.spend_vacated(updated, updated.delete('unpublished_from'), slug: slug, year: new_year)

    new_path = File.join(CONTENT_DIR, new_year, "#{slug}.json")
    if new_year != old_year
      # A different post can already own <new_year>/<slug> -- writing
      # there would replace it wholesale, and the build's duplicate
      # check never fires because only one file remains.
      abort(I18n.t('cli.post_already_exists', slug: slug, path: new_path)) if File.exist?(new_path)

      FileUtils.mkdir_p(File.dirname(new_path))
      relocate_media(slug, old_year, new_year)
    end

    # Write first, delete second. A failure in between leaves the post
    # twice (recoverable: delete the copy in the year it left), where the
    # other order left no copy of it at all.
    AtomicWrite.write_json(new_path, updated)
    File.delete(path) if File.expand_path(new_path) != File.expand_path(path)
    [new_path, updated]
  end

  # Up to `max_length` chars of the post's plain text (capped at
  # PEREX_LENGTH), trimmed to a whole word and marked with an ellipsis if
  # it got cut off. Soft line breaks the author typed inside a paragraph
  # are invisible in HTML but visible in a plain-text toot -- so all
  # internal whitespace collapses to single spaces first.
  def perex_for(blocks, max_length = PEREX_LENGTH)
    limit = [max_length, PEREX_LENGTH].min
    plain = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip
    return plain if plain.length <= limit
    return '' if limit <= 0

    # limit - 1, because the ellipsis is a character too: budgeted at the
    # full limit, a perex that had to be cut came out exactly one unit
    # over the network's maximum and the whole announcement was rejected.
    # The word boundary is [[:space:]], not \s, so a non-breaking space --
    # which Czech typography puts after single-letter prepositions, and
    # which \s does not match -- still counts as one.
    "#{plain[0, limit - 1].sub(/[[:space:]]+[^[:space:]]*\z/, '')}…"
  end

  def hashtags_for(tags)
    tags.map { |t| "##{t.to_s.gsub(/\s+/, '')}" }.join(' ')
  end

  # title/url/hashtags must never be truncated (a cut-off URL is a dead
  # link, a cut-off hashtag is a broken one) -- only the perex shrinks to
  # make the whole toot fit under Mastodon's TOOT_LENGTH limit.
  def compose_toot(title:, slug:, year:, blocks:, tags:)
    url = post_url(slug, year)
    hashtags = hashtags_for(tags)
    fixed_length = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n").length
    budget = TOOT_LENGTH - fixed_length - 2 # 2 = the "\n\n" the perex adds once inserted

    [title, perex_for(blocks, budget), url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
  end

  def grapheme_length(text)
    text.scan(/\X/).length
  end

  # How much of the 300 the title is worth keeping room for before tags
  # start being dropped. A headline cut to nothing announces nothing.
  MIN_TITLE_GRAPHEMES = 40

  # Cuts a title down to fit, on a word boundary where there is one. Only
  # ever reached when the address and the tags alone leave no room -- see
  # compose_bluesky_post.
  def trim_to_graphemes(text, limit)
    return text if grapheme_length(text) <= limit
    return '' if limit <= 1

    "#{text.scan(/\X/).first(limit - 1).join.sub(/[[:space:]]+[^[:space:]]*\z/, '')}…"
  end

  # Same word-boundary trimming as perex_for, but budgeted in graphemes --
  # what Bluesky actually counts (an emoji or "ř" is one grapheme, not
  # one-plus bytes or codepoints).
  def perex_by_graphemes(blocks, max_graphemes)
    limit = [max_graphemes, PEREX_LENGTH].min
    plain = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip
    return plain if grapheme_length(plain) <= limit
    return '' if limit <= 0

    # limit - 1 and a [[:space:]] boundary, exactly as perex_for above:
    # its structural twin got this and this one did not, so when the cut
    # fell inside a run with no ASCII space (a long URL, an NBSP-joined
    # Czech line) the sub removed nothing and the perex came back one
    # grapheme over. Bluesky then rejected the whole record, the post went
    # live with no announcement and no comment thread, and nothing said so.
    "#{plain.scan(/\X/).first(limit - 1).join.sub(/[[:space:]]+[^[:space:]]*\z/, '')}…"
  end

  # The Bluesky counterpart of compose_toot: same never-truncate rule for
  # title/url/hashtags, 300-grapheme budget. Links and hashtags become
  # clickable via facets, which BlueskyPoster builds from this text.
  def compose_bluesky_post(title:, slug:, year:, blocks:, tags:)
    url = post_url(slug, year)
    hashtags = hashtags_for(tags)
    fixed = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
    budget = BLUESKY_LENGTH - grapheme_length(fixed) - 2

    # A long title plus many tags can fill the 300 graphemes on their own,
    # and the preview then has nothing left to give up. Bluesky refuses
    # the whole record at that point, so the post goes out with no
    # announcement at all -- the one outcome worse than a shortened one.
    # What yields, in order: the title (trimmed, on a word boundary), then
    # tags from the end. The address never does -- a cut address is a dead
    # one -- and no tag is ever half-written, because half a tag is a
    # different tag.
    if budget.negative?
      tag_list = Array(tags).dup
      loop do
        hashtags = hashtags_for(tag_list)
        room = BLUESKY_LENGTH - grapheme_length([url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")) - 2
        break if room >= MIN_TITLE_GRAPHEMES || tag_list.empty?

        tag_list.pop
      end
      hashtags = hashtags_for(tag_list)
      room = BLUESKY_LENGTH - grapheme_length([url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")) - 2
      title = trim_to_graphemes(title.to_s, room)
      fixed = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
      budget = BLUESKY_LENGTH - grapheme_length(fixed) - 2
    end

    [title, perex_by_graphemes(blocks, budget), url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
  end

  # How far a post's date may sit from "now" and still be announced by
  # itself. A post dated outside it is being backfilled -- an old thread
  # rebuilt, an archive imported, a release post written down after the
  # fact -- and an announcement would put a years-old page into a live
  # timeline as if it had just been written.
  #
  # It lives here, with the announcement it governs, because BOTH callers
  # need it and only one of them used to have it: the window was a
  # constant inside the interactive CLI, so the scheduled-publish cron --
  # the one caller with nobody at a terminal to catch the mistake --
  # announced whatever it published, however old. That is not theory; it
  # happened, to five backdated release posts in one tick.
  TOOT_RECENCY_WINDOW = 24 * 60 * 60

  # Deliberately symmetric: a date far in the FUTURE is the same kind of
  # mistake as one far in the past (a typo'd year, most often), and the
  # interactive path has always asked about both.
  def within_recency_window?(date)
    (date - Time.now).abs <= TOOT_RECENCY_WINDOW
  end

  # Whether this post has already been announced once. The fields are the
  # announcement: they are what `unpublish` deletes the toot by, what the
  # page renders its comment thread from, and what a second announcement
  # would overwrite -- leaving the first thread live, with its replies,
  # and nothing anywhere pointing at it. Any of them counts, because a
  # site that changed networks has the other one's field still on its
  # older posts, and neither wants announcing twice.
  def announced?(post)
    %w[mastodon_url bluesky_url bluesky_uri].any? { |field| !post[field].to_s.strip.empty? }
  end

  # The address behind announced?, for the messages that name what already
  # exists: first non-empty of the three fields, in the order a reader
  # would recognize.
  def announcement_url(post)
    %w[mastodon_url bluesky_url bluesky_uri].map { |field| post[field].to_s.strip }.find { |v| !v.empty? }
  end

  # Mirrors build_blog.rb's truthy? on purpose, and deliberately NOT the
  # CLI's stricter frontmatter reading: the builder decides which posts
  # the site hides, and every announcer must skip at least everything the
  # builder hides. The cron once kept its own, narrower list of yeses --
  # [true, 'true', 'yes', 1] -- so a flag written by a script as "1" or
  # "Yes" hid the post from every listing and put its address on a public
  # timeline anyway. CLI-authored posts never feel the difference (the
  # frontmatter normalizes the flag to a boolean on save); a JSON written
  # by hand or by a script -- the 17 Aug incident's own vector -- is
  # exactly who this is for.
  def unlisted?(post)
    value = post['unlisted']
    return false if value.nil? || value == false

    !%w[false no 0].include?(value.to_s.strip.downcase)
  end

  # Sends the announcement to whichever network the site configured and
  # returns the post fields to store ('mastodon_url', or 'bluesky_url' +
  # 'bluesky_uri'). The caller decides WHETHER to announce (recency
  # window, prompts); this decides only how.
  #
  # Three outcomes, not two. nil means there was nothing to send -- no
  # comment network is configured, which is a setting, not a fault.
  # false means the send was ATTEMPTED and failed: an expired token, an
  # instance that did not answer, a text the network refused. Both used to
  # be nil, so the scheduled-publish cron could not tell them apart: it
  # published the post, swallowed the failure, exited 0, and left no trace
  # on disk that an announcement was ever owed. Nothing retried it, and
  # nobody found out.
  def announce(post, year:)
    title = post['title']
    slug = post['slug']
    blocks = post['content']
    tags = post['tags'] || []

    case SiteConfig.comment_network
    when :mastodon
      url = MastodonPoster.publish(compose_toot(title: title, slug: slug, year: year,
                                                blocks: blocks, tags: tags),
                                   idempotency_key: "#{year}/#{slug}")
      url ? { 'mastodon_url' => url } : false
    when :bluesky
      result = BlueskyPoster.publish(compose_bluesky_post(title: title, slug: slug, year: year,
                                                          blocks: blocks, tags: tags))
      result ? { 'bluesky_url' => result[:url], 'bluesky_uri' => result[:uri] } : false
    end
  end

  # The marker the publishing cron looks for: it means "the site owes the
  # world a deploy". Written here rather than only by the cron, because
  # the case that needs it most is the manual one -- ./blog.sh publish
  # announces the post BEFORE it builds, so a build that does not happen
  # leaves an announcement pointing at a page nobody will ever upload.
  # The next cron tick reads this and finishes the job.
  DEPLOY_PENDING = File.join(ROOT, '.deploy-pending')

  # The scheduler's heartbeat. Its MTIME is the whole content -- the file
  # says nothing except "something ran the queue at this moment".
  SCHEDULER_HEARTBEAT = File.join(ROOT, '.last-scheduled-run')

  def mark_scheduler_alive
    File.write(SCHEDULER_HEARTBEAT, Time.now.iso8601)
  rescue StandardError
    # A heartbeat that cannot be written must never stop the publishing
    # it exists to describe.
    nil
  end

  def scheduler_last_run
    return nil unless File.exist?(SCHEDULER_HEARTBEAT)

    Time.parse(File.read(SCHEDULER_HEARTBEAT).strip)
  rescue StandardError
    begin
      File.mtime(SCHEDULER_HEARTBEAT)
    rescue StandardError
      nil
    end
  end

  def mark_deploy_pending
    File.write(DEPLOY_PENDING, Time.now.iso8601)
  rescue StandardError
    nil
  end

  def clear_deploy_pending
    File.delete(DEPLOY_PENDING) if File.exist?(DEPLOY_PENDING)
  rescue StandardError
    nil
  end

  # Build and deploy as one step (--prune included: after a delete or a
  # year-changing edit, live pages remain on the target that the build no
  # longer generates -- without prune, nothing would ever clean them up).
  #
  # Answers true or false and nothing else: ten callers read it as a
  # yes/no and a third state would quietly read as success in half of
  # them. Which KIND of no it was decides the wording and the marker, not
  # the return value.
  def rebuild_and_deploy(reason)
    @stopped_on_busy_lock = false
    puts
    puts "#{reason}…"
    unless system('ruby', File.join(ROOT, 'build', 'build_blog.rb'))
      finish_later('build', $CHILD_STATUS)
      return false
    end

    if system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--prune')
      clear_deploy_pending
      return true
    end

    finish_later('deploy', $CHILD_STATUS)
    false
  end

  # Says which of the two things happened and leaves the marker behind so
  # the next scheduled run picks the site back up.
  def finish_later(step, status)
    busy = RunLock.busy_exit?(status)
    @stopped_on_busy_lock = busy
    warn I18n.t("cli.#{step}_#{busy ? 'busy' : 'failed'}")
    mark_deploy_pending
    warn I18n.t('cli.deploy_pending_marked')
  end

  # Whether the most recent rebuild_and_deploy came back false because
  # another run held the lock, told apart from "something broke". A
  # separate question on purpose: the return value stays a plain yes/no
  # (see rebuild_and_deploy), and the caller whose EXIT CODE has to tell
  # the two apart -- ./blog.sh rebuild -- asks here after reading the no.
  def stopped_on_busy_lock?
    @stopped_on_busy_lock == true
  end
end
