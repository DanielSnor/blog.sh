# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
# For $CHILD_STATUS -- the exit status of the build and the deploy is what
# tells "the lock was busy" from "it broke", and $? does not read as either.
require 'English'
require_relative 'post_address'
require_relative 'post_text'
require_relative 'address_guard'
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
  # Mastodon charges every link a FLAT 23 characters, whatever it measures
  # (`configuration.statuses.characters_reserved_per_url` in its own API,
  # 23 since the day the field existed). Counting the address literally
  # spent a budget nobody was charging for: on an address like
  # https://example.com/posts/2026/some-slug/ that is some twenty
  # characters of perex cut off every announcement for nothing.
  #
  # A constant, NOT a maximum: a link shorter than 23 costs 23 too, so
  # [url.length, 23].max would trade this error for its mirror image.
  #
  # Configurable for the same reason toot_length is -- a server that
  # counts differently says so in that field, and a site that has read it
  # can write it down here.
  LINK_LENGTH = SiteConfig.get('mastodon', 'link_length', default: 23)
  # Bluesky's limit is fixed by the AT Protocol and counted in GRAPHEMES,
  # not characters -- hence the separate composition below. It charges an
  # address what the address measures, so nothing like LINK_LENGTH belongs
  # in the Bluesky composer: the two networks disagree, and copying this
  # rule across would make every long-URL announcement one Bluesky refuses.
  BLUESKY_LENGTH = 300

  module_function

  def base_url
    (ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')).to_s.chomp('/')
  end

  # `page:` because a page is served at the root: the announcement for one
  # carried /posts/<year>/<slug>/, an address the site never answers at, so
  # the toot that told the world about a new page linked to a 404 -- and
  # the URL is also what finds the announcement again later, to update or
  # withdraw it.
  def post_url(slug, year, page: false)
    return "#{base_url}/#{slug}/" if page

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
    PostAddress.spend_vacated(updated, updated.delete('unpublished_from'), slug: slug)

    new_path = File.join(CONTENT_DIR, new_year, "#{slug}.json")
    # A different post can already own the address this one is about to
    # take -- and writing there leaves an archive the build refuses to
    # run on. Asked of AddressGuard, and asked on EVERY publish rather
    # than only when the year changes: a draft published onto a page's
    # slug never moved years at all, and the scheduler's cron reaches
    # this line with nobody at the keyboard to read what went wrong.
    taken = AddressGuard.occupant(updated, content_dir: CONTENT_DIR, slug: slug,
                                  except: path, path: new_path)
    abort(I18n.t('cli.post_already_exists', slug: slug, path: taken)) if taken

    if new_year != old_year
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
    # A teaser the author wrote replaces the cut entirely -- that is the
    # whole point of writing one. An empty teaser (the marker on the first
    # line) therefore yields an empty perex rather than falling back, which
    # is the author asking for title and link alone.
    blocks = PostText.teaser_blocks(blocks) || blocks
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
  def compose_toot(title:, slug:, year:, blocks:, tags:, page: false)
    url = post_url(slug, year, page: page)
    hashtags = hashtags_for(tags)
    parts = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }
    # The separators come from the join; the address costs what the network
    # charges for one, not what it measures. See LINK_LENGTH.
    fixed_length = parts.join("\n\n").length
    fixed_length += LINK_LENGTH - url.length unless url.to_s.strip.empty?
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
    # Same rule as perex_for, and here for the same reason its word-boundary
    # trimming had to be copied: these two are structural twins, and every
    # time one of them learned something the other did not, the difference
    # showed up as a broken announcement on one network only.
    blocks = PostText.teaser_blocks(blocks) || blocks
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
  def compose_bluesky_post(title:, slug:, year:, blocks:, tags:, page: false)
    url = post_url(slug, year, page: page)
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
    PostAddress.unlisted?(post)
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
  # What an announcement says about a post, decided in one place because it
  # is a decision rather than a formatting detail -- and because it was
  # wrong, quietly, for a whole class of post.
  #
  # A post that never named itself is named from its own opening, and the
  # preview then has to pick up where that name stopped, or the
  # announcement says the same sentence twice: once as the headline and
  # once again underneath. So the blocks handed on are the REST of the
  # text, not the whole of it. They add back up -- nothing between the two
  # is dropped, including the short word the name may have shed.
  #
  # And a post whose content is a LINK block -- what the feed and Ghost
  # importers produce -- has neither a title of its own nor text to be
  # named from, so this used to hand on nothing: the announcement went out
  # as the address and the hashtags and not one word more, while the page
  # it points at renders the link's title as its heading and the link's
  # description underneath. The one action that cannot be taken back was
  # the one saying least.
  def announcement_parts(post)
    name, rest = PostText.name_and_rest(post)
    link = PostText.link_title_block(post)
    link_name = link && link['title'].to_s.strip
    # The build's order, in post_title_for: an untitled post that carries a
    # link block borrows ITS title, and only a post with no link to borrow
    # from is named by its opening sentence. This had the two the other way
    # round, so a post with both went out announced as one thing while its
    # own <h1>, its tab, its feed item and its link card said another --
    # the engine giving two answers to "what is this post called".
    #
    # link_title_block is nil whenever post['title'] is set, so a link here
    # always means an untitled post with a title to lend.
    title = post['title'] || (link ? link_name : name)
    blocks = if link
               # The build renders a lent title without repeating it and
               # leaves the description; the announcement says the same.
               # With no description the whole post goes -- the opening
               # sentence included, because it did not become the name.
               if link['description'].to_s.strip.empty?
                 post['content']
               else
                 [{ 'type' => 'text', 'text' => link['description'].to_s }]
               end
             elsif name
               [{ 'type' => 'text', 'text' => rest }]
             else
               post['content']
             end
    [title, blocks]
  end

  def announce(post, year:)
    # An announcement is the one act that cannot be taken back, and without
    # a base URL it goes out carrying "/posts/2026/slug/" -- not a link at
    # all on Mastodon, just text. Worse, the returned status URL is then
    # stored on the post, so announced? is true for ever and every later
    # attempt to send a correct one is refused.
    #
    # The interactive path has refused this since 1.2 and doctor calls a
    # missing base_url an error -- but the guard sat in scripts/manage_post.rb,
    # so the SCHEDULED path, the one nobody is watching, sent it anyway. The
    # question belongs to whoever is about to press send.
    if base_url.empty?
      warn I18n.t('cli.announce_no_base_url')
      return false
    end

    slug = post['slug']
    tags = post['tags'] || []
    title, blocks = announcement_parts(post)

    case SiteConfig.comment_network
    when :mastodon
      url = MastodonPoster.publish(compose_toot(title: title, slug: slug, year: year,
                                                blocks: blocks, tags: tags,
                                                page: PostAddress.page?(post)),
                                   idempotency_key: "#{year}/#{slug}")
      url ? { 'mastodon_url' => url } : false
    when :bluesky
      result = BlueskyPoster.publish(compose_bluesky_post(title: title, slug: slug, year: year,
                                                          blocks: blocks, tags: tags,
                                                          page: PostAddress.page?(post)))
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
    # Milliseconds, because clear_deploy_pending compares this against the
    # instant a build started and whole seconds cannot separate two events
    # inside the same one. A marker already on disk with second precision
    # still parses; this only makes new ones answerable.
    File.write(DEPLOY_PENDING, Time.now.iso8601(3))
  rescue StandardError
    nil
  end

  # Cleared only when the marker is OLDER than the moment this run's build
  # read the archive. It used to be cleared whenever a deploy succeeded, with
  # no question about whose debt it was -- and the publishing cron holds the
  # run lock for its whole run, so this is not a rare shape: an author who
  # runs `./blog.sh publish` after the cron's build has already read the
  # archive gets their post published AND announced, is refused the lock, and
  # is told "the site is marked as owing a deploy, so the next scheduled run
  # finishes it". The cron then finished ITS deploy -- which never saw that
  # post -- and deleted the marker. The post was public, its toot was live,
  # its page was on neither the disk nor the server, the next tick found
  # nothing owed, and doctor called the site fine. The CLI's own promise was
  # the thing that turned out to be false.
  def clear_deploy_pending(written_before: nil)
    return unless File.exist?(DEPLOY_PENDING)

    if written_before && (stamp = deploy_pending_at) && stamp > written_before
      return
    end

    File.delete(DEPLOY_PENDING)
  rescue StandardError
    nil
  end

  def deploy_pending_at
    Time.parse(File.read(DEPLOY_PENDING).strip)
  rescue StandardError
    begin
      File.mtime(DEPLOY_PENDING)
    rescue StandardError
      nil
    end
  end

  # Build and deploy as one step (--prune included: after a delete or a
  # year-changing edit, live pages remain on the target that the build no
  # longer generates -- without prune, nothing would ever clean them up).
  #
  # Answers true or false and nothing else: ten callers read it as a
  # yes/no and a third state would quietly read as success in half of
  # them. Which KIND of no it was decides the wording and the marker, not
  # the return value.
  # `full` renders every page instead of only the ones whose inputs moved.
  # Off for everything that publishes, edits or deletes a post -- those know
  # what they changed, and the build cache is exactly the machinery for
  # spending nothing on the rest. It is on only when somebody asks for it by
  # hand (`./blog.sh rebuild --full`), which is what you do when you doubt
  # what is on disk rather than what is in the archive.
  def rebuild_and_deploy(reason, full: false)
    @stopped_on_busy_lock = false
    # Noted before the build reads a single file, so a marker written after
    # this instant is somebody else's debt and survives our success.
    started = Time.now
    puts
    puts "#{reason}…"
    build = [File.join(ROOT, 'build', 'build_blog.rb')]
    build << '--full' if full
    unless system('ruby', *build)
      finish_later('build', $CHILD_STATUS)
      return false
    end

    if system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--prune')
      clear_deploy_pending(written_before: started)
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
