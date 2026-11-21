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
    # The date a plan overwrote: the post is going out with the slot it
    # was given, so there is nothing left to put back.
    updated.delete('date_before_schedule')
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

  # A tag as the hashtag it announces under. Mastodon and Bluesky end a
  # hashtag at anything but a letter, a digit or `_`, so a tag that keeps a
  # dot or a hyphen is announced as a shorter one: `blog.sh` became `#blog`,
  # `sean.cz` `#sean`, `self-hosting` `#self` -- and `hudba dana`, with its
  # space simply dropped, `#hudbadana`, which no reader of the site would
  # search for. A run of spaces, dots and hyphens is one `_`, and one at the
  # ends of the tag is nothing at all (`.net` is `#net`). The tag's own page
  # keeps its address: Slug.slugify makes `_`, space, dot and hyphen the
  # same `-`, so this changes what the announcement says and not where a tag
  # lives.
  #
  # Every other character a hashtag cannot hold is the same as a dot (fleet
  # over 1.12): `R&D` was `#R`, `C++` `#C`, `don't` `#don`, and a space
  # beside an emoji left `#kytara_`. Invisible marks (a soft hyphen, a
  # zero-width space) are taken out rather than made a `_`; the text is
  # composed first (NFC), so `é` typed two ways is one hashtag; and a
  # hashtag is at most HASHTAG_GRAPHEMES long -- Bluesky's limit for a tag,
  # past which the whole post is refused -- cut where a `_` is, if one is.
  HASHTAG_GRAPHEMES = 64

  #
  # A `+` or `#` that ends a word is said, not cut: `C++` is `#Cplusplus`
  # and `C#` `#Csharp`, the hashtags those languages go by. Cut, both were
  # `#C`, and the tags `C`, `C#` and `C++` were announced as one (second
  # fleet over 1.12, 02/5).
  SAID = { '+' => 'plus', '#' => 'sharp' }.freeze

  def hashtag_for(tag)
    text = tag.to_s.dup.force_encoding(Encoding::UTF_8).scrub('')
    text = text.unicode_normalize(:nfc).gsub(/\p{Cf}/, '')
    text = text.gsub(/(?<=[[:alnum:]])[+#]+(?![[:word:]])/) { |run| run.chars.map { |c| SAID[c] }.join }
    word = text.gsub(/[^[:word:]]+/, '_').gsub(/\A_+|_+\z/, '')
    word = cut_hashtag(word) if grapheme_length(word) > HASHTAG_GRAPHEMES
    word.empty? ? '' : "##{word}"
  end

  def cut_hashtag(word)
    kept = word.scan(/\X/).first(HASHTAG_GRAPHEMES).join
    at = kept.rindex('_')
    (at && at.positive? ? kept[0, at] : kept).sub(/_+\z/, '')
  end

  # Two tags that come to the same hashtag are announced once: `blog.sh` and
  # `blog-sh` both say `#blog_sh`, and a hashtag is the same whatever its case.
  def hashtags_for(tags)
    tags.map { |t| hashtag_for(t) }.reject(&:empty?).uniq(&:downcase).join(' ')
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

    # Past the limit even without a perex, Mastodon refuses the whole toot
    # and the post goes out unannounced -- what Bluesky's composer has been
    # spared since 1.4. What yields is the same here: tags from the end
    # until the title has room, then the title on a word. The address never.
    if budget.negative?
      linked = ->(list) { [url, hashtags_for(list)].reject { |p| p.to_s.strip.empty? }.join("\n\n").length + LINK_LENGTH - url.length }
      tag_list = Array(tags).dup
      tag_list.pop while !tag_list.empty? && TOOT_LENGTH - linked.call(tag_list) - 2 < MIN_TITLE_GRAPHEMES
      hashtags = hashtags_for(tag_list)
      room = TOOT_LENGTH - linked.call(tag_list) - 2
      title = trim_to_graphemes(title.to_s, room)
      fixed_length = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n").length + LINK_LENGTH - url.length
      budget = TOOT_LENGTH - fixed_length - 2
    end

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

  # The env.sh value an announcement on this site's network needs, or nil
  # when there is no network. Said by name where it is missing, because
  # "announced on Mastodon" on a site with no token is a promise publish
  # then cannot keep (newcomer trial, 25. 9. 2026).
  NETWORK_SECRET = { mastodon: 'MASTODON_ACCESS_TOKEN', bluesky: 'BLUESKY_APP_PASSWORD' }.freeze

  def network_secret
    NETWORK_SECRET[SiteConfig.comment_network]
  end

  # Whether publishing a post here would announce it: a network, and the
  # secret it needs.
  def announces?
    secret = network_secret
    !secret.nil? && !ENV[secret].to_s.empty?
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

  # The announcements a post is owed once its page is live. The toot used to
  # go out BEFORE the build and the deploy, because the page draws its
  # comment thread from the toot's address and so needed it first -- and for
  # as long as the build and the deploy took (a minute or two on a quiet
  # machine, three on a cold disk, more on a large archive) the address in
  # the toot led to a 404, which followers saw and said. Now the page goes
  # out first, the toot after it, and the address it brings is put on the
  # page by a second, quick build.
  #
  # This file is the record of the toots still to send: a path under the
  # content directory to a line. A line is written when a post is published
  # and read when the deploy has gone through -- by the same run, or, when
  # the deploy failed, by the next tick of the publishing cron, which is why
  # it is a file and not a variable. A post whose deploy failed is not
  # announced: a link to a page that is not there is the failure this exists
  # to prevent.
  ANNOUNCE_PENDING = File.join(ROOT, '.announce-pending')

  # A line is `<path under content>\t<when it was owed>`. The time is what
  # lets a run tell its own debts from somebody else's: a build that started
  # before a post was published did not put its page on the server, so that
  # run must not send its toot (the 404 this file exists to prevent, by a
  # different road: a manual publish while the cron's build was running).
  # A line with no time (written by 1.12 before this) is payable by anybody.
  def owed_entries
    File.readlines(ANNOUNCE_PENDING, chomp: true, encoding: 'utf-8').filter_map do |line|
      rel, stamp = line.scrub.strip.split("\t", 2)
      next if rel.to_s.empty?

      [rel, (Time.iso8601(stamp) rescue nil)]
    end.uniq { |rel, _| rel }
  rescue SystemCallError
    []
  end

  def owed_announcements
    owed_entries.map(&:first)
  end

  def relative_to_content(path)
    path.to_s.sub(%r{\A#{Regexp.escape(CONTENT_DIR)}/?}, '')
  end

  # Owed from now: a post owed again (published, taken down, published
  # again) is owed from the later moment.
  def owe_announcement(path)
    rel = relative_to_content(path)
    rest = owed_entries.reject { |owed, _| owed == rel }
    write_owed(rest + [[rel, Time.now]])
  end

  # A post that moves -- a new slug, a date in another year -- takes its
  # debt along, owed from the same moment. Left behind, the line named a
  # file that was no longer there, the next run settled it as a post gone,
  # and the post went out unannounced without a word (second fleet over
  # 1.12, 02/1).
  def move_announcement(from, to)
    old_rel = relative_to_content(from)
    new_rel = relative_to_content(to)
    return if old_rel == new_rel

    entries = owed_entries
    return unless entries.any? { |owed, _| owed == old_rel }

    write_owed(entries.map { |owed, at| owed == old_rel ? [new_rel, at] : [owed, at] }.uniq { |rel, _| rel })
  rescue SystemCallError
    nil
  end

  def settle_announcement(path)
    rel = relative_to_content(path)
    write_owed(owed_entries.reject { |owed, _| owed == rel })
  rescue SystemCallError
    nil
  end

  # Takes the debt off the list and says whether it was there: the one who
  # takes it sends the toot. A manual publish and the cron can both reach
  # the same post (the cron paying what a manual run left owed while that
  # run is still going); whoever claims it first sends, the other does not.
  def claim_announcement(path)
    rel = relative_to_content(path)
    entries = owed_entries
    return false unless entries.any? { |owed, _| owed == rel }

    write_owed(entries.reject { |owed, _| owed == rel })
    true
  end

  def write_owed(entries)
    if entries.empty?
      File.delete(ANNOUNCE_PENDING) if File.exist?(ANNOUNCE_PENDING)
    else
      AtomicWrite.write(ANNOUNCE_PENDING, entries.map { |rel, at| at ? "#{rel}\t#{at.iso8601(3)}" : rel }.join("\n") + "\n")
    end
  end

  # When the last rebuild_and_deploy of this process started reading the
  # archive -- what send_owed_announcements is told, so that it pays only
  # the debts that build could see.
  def last_build_started
    @last_build_started
  end

  # The fields an announcement brought, written onto the post as it is NOW
  # on disk. The copy the sender read is minutes old by the time the toot
  # comes back (a build and a deploy lie between them on a manual publish),
  # and writing that copy back undid whatever was saved in between -- an
  # `edit` made during the deploy, said to be saved, quietly gone.
  #
  # A post no longer there is not written back: it was deleted or renamed
  # while the deploy ran, and writing the old copy brought it back -- a
  # deleted post in the archive again, a renamed one twice (second fleet
  # over 1.12, 02/3). The fields are still handed back, for the caller.
  def record_announcement(path, fields, fallback)
    current = begin
      JSON.parse(File.read(path, encoding: 'utf-8'))
    rescue Errno::ENOENT
      return fallback.merge(fields)
    rescue SystemCallError, JSON::ParserError
      fallback
    end
    AtomicWrite.write_json(path, current.merge(fields))
    current.merge(fields)
  end

  # Sends every owed announcement whose post is still published, still
  # unannounced and still announceable, and writes what came back onto the
  # post. Returns [sent, failed]. A failure is not retried: the post is out,
  # a second toot would stand beside the first if the network had only been
  # slow to say so, and `./blog.sh toot` is there for a person to try again.
  # The caller rebuilds when `sent` is not zero -- that build is what puts
  # the toot's address on the page.
  #
  # built_since: when the build that just went live started. A debt owed
  # after that moment is a post that build did not see: it stays owed, for
  # the run that published it or the next tick.
  def send_owed_announcements(built_since: nil)
    sent = 0
    failed = 0
    now = Time.now
    owed_entries.each do |rel, owed_at|
      # A debt owed after the build began is a post the build did not see.
      # One owed in the future is a clock that went back: no build will ever
      # start after it, and every tick rebuilt and redeployed waiting for
      # one (second fleet over 1.12, 02/2) -- it is paid.
      next if built_since && owed_at && owed_at > built_since && owed_at <= now

      path = File.join(CONTENT_DIR, rel)
      post = begin
        JSON.parse(File.read(path, encoding: 'utf-8'))
      rescue SystemCallError, JSON::ParserError
        nil
      end
      if post.nil? || post['state'] != 'published' || announced?(post) || unlisted?(post)
        settle_announcement(path)
        next
      end
      next unless claim_announcement(path)

      fields = announce(post, year: File.basename(File.dirname(path)))
      case fields
      when Hash
        record_announcement(path, fields, post)
        sent += 1
      when false
        failed += 1
        # Without base_url nothing was sent, and the token is not the reason.
        warn I18n.t(base_url.empty? ? 'cron.announce_failed_base_url' : 'cron.announce_failed', slug: post['slug'])
      end
    end
    [sent, failed]
  end

  # An unset DEPLOY_BACKEND is Surfer, as DeployBackend.pick and doctor read
  # it -- looked up by name it was nothing, and a publish that had just
  # uploaded said the site went nowhere (fleet, 26. 9. 2026).
  def deploys_somewhere?
    require_relative 'deploy_backend'
    name = ENV['DEPLOY_BACKEND'].to_s
    backend = name.empty? ? DeployBackend::Surfer : DeployBackend::BACKENDS[name]
    !backend.nil? && backend.configured?
  end

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
  def rebuild_and_deploy(reason, full: false, force: false)
    @stopped_on_busy_lock = false
    # Noted before the build reads a single file, so a marker written after
    # this instant is somebody else's debt and survives our success.
    started = Time.now
    @last_build_started = started
    puts
    puts "#{reason}…"
    build = [File.join(ROOT, 'build', 'build_blog.rb')]
    build << '--full' if full
    unless run_build(build)
      return false if @stopped_on_busy_lock

      finish_later('build', $CHILD_STATUS)
      return false
    end

    # --force is the deploy's: its guard says to run again with it, and
    # `./blog.sh rebuild --force` is how that is said from here.
    extra = force ? ['--force'] : []
    if system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--prune', *extra)
      clear_deploy_pending(written_before: started)
      return true
    end

    finish_later('deploy', $CHILD_STATUS)
    false
  end

  # Which languages a rebuild produces: the site's own, and every other one
  # `site.locales` names. One run per language, all of them into the SAME
  # public.nosync -- the tree is the merge (build_blog.rb's CONTENT_ROOT),
  # so the deploy that follows sees one site and nothing has to be copied
  # or reconciled afterwards.
  def publish_languages
    own = SiteConfig.get('site', 'lang', default: 'en').to_s
    named = Array(SiteConfig.get('site', 'locales', default: nil)).map { |code| code.to_s.strip }
    ([own] + named.reject(&:empty?)).uniq
  end

  # One build, or one per language under a single lock.
  #
  # 🪤 The lock is the orchestrator's here. A build takes its own -- unless
  # it was told where to write, which is exactly what each language run is
  # told -- so without this the runs would go unguarded while a scheduled
  # publish walked in between two of them and deployed half a site.
  def run_build(build)
    langs = publish_languages
    return system('ruby', *build) if langs.length < 2

    public_dir = File.join(ROOT, 'public.nosync')
    held = RunLock.hold(ROOT, label: 'build') do
      langs.all? do |lang|
        system({ 'BLOG_SH_PUBLIC_DIR' => public_dir, 'BLOG_SH_LANG' => lang }, 'ruby', *build)
      end
    end
    return held unless held == RunLock::BUSY

    @stopped_on_busy_lock = true
    warn I18n.t('cli.build_busy')
    mark_deploy_pending
    warn I18n.t('cli.deploy_pending_marked')
    false
  end

  # Says which of the two things happened and leaves the marker behind so
  # the next scheduled run picks the site back up.
  #
  # The two are told apart in the LAST line too. "The next scheduled run
  # finishes it, once the other run is done" is true of a lock two runs
  # met at; after a failed build or a guard's stop there is no other run,
  # and no scheduled run can fix a typo in site.yml -- the newcomer trial
  # (25. 9. 2026) read it after every failure and waited for nothing.
  #
  # A refused sign-in is told apart too: "a transfer that broke off only
  # needs ./scripts/deploy-web.sh again" stood under Surfer's 401, where
  # running it again changes nothing until env.sh does (26. 9. 2026).
  def finish_later(step, status)
    busy = RunLock.busy_exit?(status)
    @stopped_on_busy_lock = busy
    require_relative 'deploy_backend'
    refused = step == 'deploy' && status.respond_to?(:exitstatus) && status.exitstatus == DeployBackend::REFUSED_EXIT
    warn I18n.t("cli.#{step}_#{busy ? 'busy' : refused ? 'refused' : 'failed'}")
    mark_deploy_pending
    warn I18n.t(busy ? 'cli.deploy_pending_marked' : 'cli.deploy_pending_marked_failed')
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
