# frozen_string_literal: true

require 'json'
require 'set'
require 'fileutils'
require 'net/http'
require 'uri'
require 'timeout'
require 'time'
require_relative 'entity_text'
require_relative 'post_address'
require_relative 'slug'
require_relative 'i18n'
require_relative 'path_glob'
require_relative 'content_type'
require_relative 'video_probe'
require_relative 'yaml_compat'

# What `./blog.sh check` finds. Doctor's counterpart, and deliberately a
# separate thing: doctor answers "is this installation sound", reads a
# handful of config values and takes a second, while this walks every post
# and every media file in the archive. Rolled into one command, the fast
# half would stop being run.
#
# It reads the CONTENT rather than the built site. A finding has to name a
# post and a slug -- something to go and fix -- rather than a file under
# public.nosync, and it must work before a build has ever run. Judging
# links still needs to know what addresses the build produces, so those are
# derived here from the same rules build_blog.rb uses.
#
# It only ever reports. Nothing here deletes an orphaned media directory or
# rewrites a post: the whole value of the tool is that its output can be
# trusted, and a checker that also acts is one that has to be trusted twice.
module Checker
  # `count` is how many findings the line stands for: 1 for an ordinary
  # finding, and for a "...and N more" line the N that was not printed --
  # which is what lets the summary total the archive instead of the screen.
  # `kind` and `data` are the finding itself; `text` and `fix` are one way
  # of saying it. Until 1.4 there was only the sentence, which meant nothing
  # downstream could act on a finding without parsing prose -- and the lists
  # were already capped at twenty by the time anyone saw them, so the rest
  # was not merely unsaid but gone. `./blog.sh check --json` prints the
  # whole list, and it costs nothing to keep: the screen is still built from
  # the same objects.
  Finding = Struct.new(:level, :text, :fix, :count, :kind, :data, keyword_init: true) do
    def error?
      level == :error
    end

    def warn?
      level == :warn
    end
  end

  # Everything a page of this site can be, other than a post: the generated
  # pages and the roots. A link to one of these is fine even though no post
  # produces it.
  #
  # The four files at the end are written by every build, unconditionally,
  # and they were missing -- so a post linking to its own site's feed was
  # reported as a dead link, with the advice that it was probably a permalink
  # left over from an import. A checker that is confidently wrong about a
  # working address costs more than one that says nothing, which is the rule
  # the comment on known_paths sets out and this list was breaking.
  # /archive/ and /tag/ are deliberately NOT here. They were, and neither
  # is unconditional: the map needs one post in the stream and the tag
  # index needs one tag on one of them. A menu entry pointing at either
  # was then ticked as sound by doctor while it 404'd from every page of
  # the site -- the exact failure check_nav exists to prevent. They are
  # worked out in known_paths instead, from the same condition the build
  # guards them with.
  FIXED_PATHS = ['/', '/search/', '/markdown/',
                 '/rss.xml', '/sitemap.xml', '/robots.txt', '/404.html'].freeze

  # A listing's later pages live under <listing>/page/N/, whatever the
  # listing is -- the front page, a tag, a series, a content type. How many
  # there are depends on site.page_size, so counting them here is exactly
  # the second opinion known_paths refuses to give; the base address is the
  # thing worth checking, and it is checked. Trailing digits only, so a post
  # whose slug happens to be "page" is unaffected.
  PAGE_SUFFIX = %r{/page/\d+/?\z}.freeze

  module_function

  def t(key, **vars)
    I18n.t("check.#{key}", **vars)
  end

  # doctor's strings, by name, for the one file both commands read. See
  # check_config for why they are shared rather than copied.
  def dt(key, **vars)
    I18n.t("doctor.#{key}", **vars)
  end

  def ok(text, kind: nil, data: nil)
    Finding.new(level: :ok, text: text, count: 1, kind: kind, data: data)
  end

  def warn(text, fix = nil, kind: nil, data: nil)
    Finding.new(level: :warn, text: text, fix: fix, count: 1, kind: kind, data: data)
  end

  def error(text, fix = nil, kind: nil, data: nil)
    Finding.new(level: :error, text: text, fix: fix, count: 1, kind: kind, data: data)
  end

  # config/site.yml -- the one thing outside the archive this file looks at.
  #
  # check is what people run before a build, and for a config the build
  # would refuse it used to answer that the archive was sound: exit 0, and
  # "errors": 0 in --json. doctor stops on such a file and so does the
  # build; check read it only to pick the language it would print in,
  # swallowed the parse error there and never looked again. Reported from
  # the outside in issue #48, by somebody who edited site.yml, was told
  # nothing was wrong, and then watched the rebuild refuse it.
  #
  # The strings are doctor's on purpose. Two commands that describe the
  # same broken file differently are worse than one that says nothing, and
  # sharing the wording is the only way they stay in step; a test pins that
  # they still report the same four cases. SiteConfig stays at arm's length
  # for the reason request() gives -- it aborts the process on exactly the
  # file this is about.
  def check_config(root)
    path = File.join(root, 'config', 'site.yml')
    unless File.exist?(path)
      return [error(dt('site_yml_missing'), dt('site_yml_missing_fix'), kind: :config_missing)]
    end

    data = YamlCompat.load_file(path)
    return [] if data.is_a?(Hash)

    [error(dt('site_yml_empty'), dt('site_yml_missing_fix'), kind: :config_empty)]
  rescue Psych::SyntaxError => e
    [error(dt('site_yml_syntax', message: e.problem.to_s),
           dt('site_yml_syntax_fix', line: e.line, column: e.column),
           kind: :config_syntax,
           data: { 'line' => e.line, 'column' => e.column, 'message' => e.problem.to_s })]
  rescue SystemCallError => e
    # Exists but cannot be opened: the wrong owner after a wizard ran under
    # sudo is the usual story, and it deserves its own sentence rather than
    # a parse error about a file nobody could read in the first place.
    [error(dt('site_yml_unreadable', message: e.message), dt('site_yml_unreadable_fix'),
           kind: :config_unreadable)]
  end

  # How many findings of one kind a screen is willing to show. The rest ride
  # along as a single "...and N more", whose count is what lets the summary
  # total the archive rather than the screen.
  CAP = 20

  # Capping happens here, in one place, and only when a cap is asked for:
  # the checks build every finding they have and hand the whole list over.
  # `--json` passes nil and gets all of them.
  def capped(findings, cap)
    return findings if cap.nil? || findings.size <= cap

    findings.first(cap) + more(findings.size - cap, findings.first.level)
  end

  def run(root:, progress: nil, online: false, online_progress: nil, cap: CAP)
    # First, and carried through the early returns below: an archive with
    # no posts in it and a config the build refuses is still a config the
    # build refuses.
    config = check_config(root)
    posts = load_posts(root)
    # "No posts" only when there is genuinely nothing -- not when every
    # file present was unreadable. load_posts drops the broken ones and
    # remembers them; firing the empty-archive early return before
    # check_unbuildable had a chance to surface them called an archive the
    # build dies on "empty" and exited 0, the exact silent drop the
    # @unreadable machinery exists to prevent.
    if posts.empty?
      unbuildable = check_unbuildable(posts, cap)
      # Parked leftovers are asked about here too. A crash mid-swap can
      # leave every post in the archive standing under a parking name, and
      # an archive that reads as empty ONLY because its posts are hidden
      # is the one case where "no posts yet" is the worst thing to say:
      # it is the answer that sends the author away.
      parked = check_parked_leftovers(root, posts)
      return config + unbuildable + parked if config.any? || unbuildable.any? || parked.any?

      return [warn(t('no_posts'), kind: :no_posts)]
    end

    known = known_paths(posts)
    findings = config
    findings.concat(check_unbuildable(posts, cap))
    findings.concat(check_parked_leftovers(root, posts))
    findings.concat(check_media(root, posts, progress, cap))
    findings.concat(check_degenerate_images(posts, cap))
    findings.concat(check_internal_links(posts, known, cap))
    findings.concat(check_relative_links(posts, cap))
    findings.concat(check_orphan_media(root, posts, cap))
    findings.concat(check_stray_media(root, posts, cap))
    findings.concat(check_redirects(posts, cap))
    findings.concat(check_redirect_entries(posts, cap))
    findings.concat(check_series_names(posts, cap))
    findings.concat(check_duplicate_addresses(posts))
    findings.concat(check_html_entities(posts, cap))
    local_clean = findings.none? { |f| f.error? || f.warn? }
    findings << ok(t('all_clear', posts: posts.size), kind: :all_clear, data: { 'posts' => posts.size }) if local_clean

    if online
      cache = Cache.new(File.join(root, 'tmp', 'link-check.json'))
      findings.concat(check_external_links(posts, cache: cache, online_progress: online_progress, cap: cap))
      cache.save
    end
    findings
  end

  # --- reading the archive ------------------------------------------------

  def load_posts(root)
    @unreadable = []
    dir = File.join(root, 'content.nosync', 'posts')
    PathGlob.under(dir, '*', '*.json').sort.filter_map do |path|
      raw = File.read(path, encoding: 'utf-8')
      # A file that is not valid UTF-8 is one the build dies on -- JSON's
      # own parser raises deep in a C extension, a raw backtrace with no
      # post named. Caught here so check reports it (and check exits
      # non-zero) instead of parsing far enough to call the archive sound.
      raise JSON::ParserError, 'not valid UTF-8' unless raw.valid_encoding?

      post = JSON.parse(raw)
      # Not a post object either -- the build stops on both, and "not a
      # Hash" used to leave here as quietly as a syntax error.
      raise JSON::ParserError, "not a post object (#{post.class})" unless post.is_a?(Hash)

      post['__path'] = path
      post['__year'] = File.basename(File.dirname(path))
      post
    rescue StandardError => e
      # Remembered, not discarded. A file the checker cannot read is a file
      # the BUILD refuses to run on -- and dropping it silently meant check
      # counted the archive minus that post and called the whole thing
      # sound, while the next build stopped dead on it.
      @unreadable << [path, "#{e.class}: #{e.message.lines.first.to_s.strip[0, 90]}"]
      nil
    end
  end

  def unreadable_files
    @unreadable ||= []
  end

  # Files the checker could not read, and posts whose date it could not
  # parse: both are states the build refuses to run on, so a check that
  # calls the archive sound while either is present is telling the author
  # the opposite of what they are about to find out.
  # Text that still carries HTML entities instead of the characters they
  # stand for: "journalists &amp; writers" reads as "journalists &amp;
  # writers" on the page, because the build escapes it again -- correctly,
  # since as far as it knows the ampersand is what the author wrote.
  #
  # Where they come from: Twitter escapes <, > and & in its archive and says
  # nothing about it, and the importer only learned to decode them in 1.4.
  # Every archive imported before that carries them, and an upgrade cannot
  # help -- the entities are in the posts by then. Reported from one such
  # site, and true of 10 posts on another.
  #
  # A warning rather than an error, and offered rather than applied: an
  # author writing ABOUT html has every right to "&amp;" in their text, and
  # nothing here can tell the two apart.
  # No cap here, and none anywhere else in a check either: capping is
  # `capped`'s job, done once, and `--json` asks for all of them by passing
  # nil. Slicing here took that nil and died on it -- which took the whole
  # --json document with it, along with its count, its total and its kinds.
  def check_html_entities(posts, cap = nil)
    found = posts.filter_map do |post|
      next if draft?(post)

      # The TITLE too, and a link block's title and description. The whole
      # point of this finding is archives imported before 1.4, and a
      # Twitter or Ghost import puts `journalists &amp; writers` in a
      # post's title as readily as in its body -- where it is worse,
      # because that string is the heading, the browser tab, the feed
      # item and the link card. It was neither reported nor repairable.
      texts = Array(post['content']).select { |b| b.is_a?(Hash) && b['type'] == 'text' }
      hits = texts.filter_map { |b| b['text'].to_s[EntityText::ANY_ENTITY] if EntityText.entities?(b['text']) }
      links = Array(post['content']).select { |b| b.is_a?(Hash) && b['type'] == 'link' }
      hits += ([post['title']] + links.flat_map { |b| [b['title'], b['description']] })
              .filter_map { |v| v.to_s[EntityText::ANY_ENTITY] if EntityText.entities?(v) }
      next if hits.empty?

      [post, hits.uniq]
    end

    capped(found.map do |post, hits|
      warn(t('post_entities', slug: post['slug'], entities: hits.first(3).join(' ')),
           t('post_entities_fix'), kind: :post_entities,
           # file_year, not date_year: the repair opens this as a PATH,
           # and a post whose date was corrected across a year boundary
           # keeps its file where it was so its address does not move.
           # Every other finding in this file records __year already.
           data: { 'slug' => post['slug'].to_s, 'year' => PostAddress.file_year(post).to_s,
                   'entities' => hits })
    end, cap)
  end

  def check_unbuildable(posts, cap = CAP)
    findings = unreadable_files.map do |path, reason|
      error(t('post_unreadable', file: short_path(path), reason: reason),
            t('post_unreadable_fix'), kind: :post_unreadable,
            data: { 'file' => path, 'reason' => reason })
    end
    # A `type:` the engine does not know is stored on the post and read by
    # nobody: `ContentType.dominant` honours the eight it has and otherwise
    # works the type out from the blocks, so somebody who wrote
    # `type: story` gets no listing, no menu item, no icon -- and no word
    # about why. Promised in issue #42 to the person who tried it.
    #
    # The fix line names the tag route rather than only the eight names: a
    # tag in `nav:` gives a listing, pagination, a menu item and an RSS
    # feed of its own, which is what somebody reaching for a new type is
    # usually after.
    posts.each do |post|
      type = post['type'].to_s
      next if type.empty? || ContentType::PRIORITY.include?(type)

      findings << warn(t('post_unknown_type', slug: post['slug'], type: type),
                          t('post_unknown_type_fix'), kind: :post_unknown_type,
                          data: { 'slug' => post['slug'].to_s, 'type' => type })
    end

    # A page whose slug is one of the addresses the engine writes itself.
    # The build refuses to write it and says so on the terminal -- but a
    # rebuild scrolls past, and this tool then called the archive sound
    # about a page that is not on the site at all. The names come from
    # PostAddress rather than a second list here: the two refusing
    # different sets is the same bug with an extra step.
    posts.each do |post|
      next unless PostAddress.page?(post)
      next unless PostAddress::RESERVED_ROOT_SEGMENTS.include?(post['slug'].to_s.downcase)

      findings << error(t('page_reserved_slug', slug: post['slug']),
                        t('page_reserved_slug_fix'), kind: :page_reserved_slug,
                        data: { 'slug' => post['slug'].to_s })
    end

    posts.each do |post|
      # A post whose content is not a list of blocks. Every reader here
      # wraps it in Array() so the check itself survives such a file --
      # and that made this tool say "the archive is sound" about a post
      # the build dies on with a raw NoMethodError, which is the exact
      # thing check_unbuildable exists to prevent. Surviving it is not the
      # same as blessing it.
      # The `.nil?` exemption used to sit here, and it was the hole: a post
      # with no `content` key at all -- or "content": null -- was waved
      # through as sound and the build then died on it. A post the build
      # cannot read is unbuildable whether the key is the wrong TYPE or
      # missing altogether; surviving a file is not the same as blessing it.
      # ...and every entry in it has to be a block. A null among them is
      # dropped by the build now rather than killing it, but a post with a
      # hole where a block should be is still a post somebody has to look
      # at -- and this is the tool whose job is to say so.
      unless post['content'].is_a?(Array) && post['content'].all? { |b| b.is_a?(Hash) }
        findings << error(t('post_content_unreadable', file: short_path(post['__path'].to_s),
                                                       value: post['content'].class.to_s),
                          t('post_content_unreadable_fix'), kind: :post_content_unreadable,
                          data: { 'file' => post['__path'].to_s })
      end
      # A slug is one path segment. A hand-edited or imported one carrying a
      # slash or a `..` turns the post's address into a path that climbs
      # out of where the build writes -- the build chokes on it while check
      # called the archive sound. The engine's own slugs are [a-z0-9-];
      # only the genuinely dangerous shapes are flagged, so a unicode slug
      # from an import is left alone.
      slug = post['slug'].to_s
      if slug.include?('/') || slug.split(/[\\\/]/).include?('..') || slug.start_with?('.') || slug.include?("\0")
        findings << error(t('post_bad_slug', file: short_path(post['__path'].to_s), slug: slug.inspect),
                          t('post_bad_slug_fix'), kind: :post_bad_slug,
                          data: { 'file' => post['__path'].to_s, 'slug' => slug })
      end
      next if parseable_date?(post['date'])

      findings << error(t('post_date_unreadable', file: short_path(post['__path'].to_s),
                                                  value: post['date'].inspect),
                        t('post_date_unreadable_fix'), kind: :post_date_unreadable,
                        data: { 'file' => post['__path'].to_s })
    end
    capped(findings, cap)
  end

  # Files a queue move stepped aside and a crash left behind. The parking
  # name is dotted precisely so nothing mistakes it for content -- which
  # also means nothing would ever find one again without this: a post, its
  # pictures or its history can sit a rename away from existing, invisible
  # to every listing, until the same slug moves again. The message carries
  # the path, and says which of three things the file is.
  def check_parked_leftovers(root, posts)
    strays = PathGlob.under(root, 'content.nosync', 'posts', '*', '.*queue-move*') +
             PathGlob.under(root, 'media.nosync', '*', '.*queue-move*') +
             PathGlob.under(root, 'content.nosync', 'versions', '*', '.*queue-move*')
    return [] if strays.empty?

    # Every post the archive still holds, keyed by what a queue move does
    # NOT rewrite -- because the one question worth asking about a parked
    # file is whether the post inside it exists anywhere else. Built only
    # when there is something to ask it about: this walks the whole archive.
    live = posts.to_h { |post| [post_identity(post), post['__path'].to_s] }
    strays.sort.map do |path|
      # Three different states, and telling them apart is the difference
      # between a repair and a second data loss.
      #
      # The post in the parked file is still in the archive somewhere: a
      # stale copy the interrupted move left behind, safe to remove once
      # it has been compared against the live one.
      #
      # It is nowhere else and its own name is free: one rename puts it
      # back, which is what the parking name is shaped for.
      #
      # It is nowhere else and its name is TAKEN. Whether the name is free
      # was once asked on its own, and read as "the post it belongs to is
      # back in place" -- which parking guarantees is false: a post is only
      # ever parked because ANOTHER post is moving to its address, so
      # whatever stands at that name is the other half of the swap. The
      # parked file can then be the only copy of its post there is, and
      # nothing may be renamed over it or deleted unread.
      home = parked_home(path)
      identity = parked_identity(path)
      elsewhere = identity && live[identity]
      rel = path.sub("#{root}/", '')
      fix = if elsewhere
              t('parked_leftover_fix_stale', live: elsewhere.sub("#{root}/", ''))
            elsif home && File.exist?(home)
              t('parked_leftover_fix_blocked', home: home.sub("#{root}/", ''))
            else
              t('parked_leftover_fix')
            end
      error(t('parked_leftover', file: rel), fix,
            kind: :parked_leftover, data: { 'file' => rel, 'stale' => !elsewhere.nil? })
    end
  end

  # What a queue move rewrites, and therefore what a post's identity
  # cannot be made of: write_scheduled_date hands the post the target date
  # and sets the scheduled flag. `__path` and `__year` are the checker's
  # own bookkeeping and were never in the file.
  MOVED_BY_QUEUE = %w[date scheduled __path __year].freeze

  # A post as something two files can be compared by. Sorted, so the same
  # post written twice compares equal whatever order its keys came back in.
  def post_identity(post)
    JSON.generate(post.reject { |key, _| MOVED_BY_QUEUE.include?(key) }.sort)
  end

  # The same, read off a parked file. Only a parked POST can answer this: a
  # parked media or versions folder is a directory, with nothing in it that
  # says whether the post it belongs to still has a copy elsewhere -- so it
  # is never called stale, which is the safe half of not knowing.
  def parked_identity(path)
    return nil unless path.end_with?('.json') && File.file?(path)

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    post.is_a?(Hash) ? post_identity(post) : nil
  rescue StandardError
    nil
  end

  # The name a parked file or directory would return to:
  # `.<name>.queue-move.<pid>[-n][.<ext>]` -> `<name>[.<ext>]` beside it.
  def parked_home(path)
    base = File.basename(path)
    m = base.match(/\A\.(.+)\.queue-move\.\d+(?:-\d+)?(\.[^.]+)?\z/)
    return nil unless m

    File.join(File.dirname(path), "#{m[1]}#{m[2]}")
  end

  # A String, and then a parseable one. The `.to_s` used to do both jobs and
  # hid the first: a post file whose date is a JSON NUMBER -- 20260608
  # rather than "2026-06-08", which is what a hand-edited or externally
  # generated file gets -- parsed happily here and was blessed, while the
  # build calls Time.parse(post['date']) with no coercion and dies on it.
  # check said "the archive is sound" and exited 0, the very next build
  # exited 1 with a TypeError naming no post at all. check_unbuildable
  # exists precisely so that cannot happen.
  def parseable_date?(value)
    return false unless value.is_a?(String)
    return false if value.strip.empty?

    Time.parse(value)
    true
  rescue StandardError
    false
  end

  def short_path(path)
    File.join(File.basename(File.dirname(path)), File.basename(path))
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  # Shared with the build and the repair pass (lib/post_address.rb), so all
  # three answer this with one voice. Note it reads the year off the post's
  # DATE, like the build does: the directory the file sits in can differ
  # from the date after a correction, and the address follows the date.
  def post_path(post)
    PostAddress.path(post)
  end

  # Every address the build will answer at: the posts themselves, the tag
  # listings, the redirect stubs a post carries, and the fixed pages.
  #
  # Type listings are deliberately absent. Which types exist is decided by
  # a heuristic in build_blog.rb (dominant_content_type), and copying it
  # here would give this tool a second opinion that drifts from the first
  # -- a checker that reports links as dead because it disagrees with the
  # build is worse than one that says nothing about them. /type/ links are
  # therefore accepted without inspection.
  # The tags that will actually have a page: carried by a post in the
  # stream. A tag only a draft, a page or an unlisted post wears never gets
  # one, so a menu item pointing at it is dead on every page of the site.
  # Shared with doctor rather than worked out twice -- this is exactly the
  # kind of list that drifts.
  def stream_tags(posts)
    posts.reject { |post| draft?(post) || PostAddress.page?(post) || PostAddress.unlisted?(post) }
         .flat_map { |post| Array(post['tags']).map { |tag| Slug.slugify(tag.to_s) } }
         .select { |slug| Slug.pageable?(slug) }.to_set
  end

  def known_paths(posts)
    paths = Set.new(FIXED_PATHS)
    # How many posts in the STREAM carry each series -- the same set the
    # build groups into SERIES_MAP, so drafts, pages and unlisted posts do
    # not count towards a series page existing.
    series_sizes = Hash.new(0)
    posts.each do |post|
      next if draft?(post) || PostAddress.page?(post) || PostAddress.unlisted?(post)

      slug = Slug.slugify(post['series'].to_s)
      series_sizes[slug] += 1 unless slug.empty?
    end
    # Whether the two roots exist at all, decided by the same conditions
    # the build guards them with rather than assumed.
    stream_post = false
    stream_tag = false
    posts.each do |post|
      paths << post_path(post)
      # A year of the archive index exists when a post in the stream lives
      # in it -- worked out from the posts rather than written down, because
      # a hand-kept list of years is a list that goes stale on new year's
      # day. The year is the ADDRESS's, matching what the build groups by:
      # taking the displayed date instead would invent /archive/2015/ for a
      # post served under 2014 and call the site's own link dead.
      in_stream = !(draft?(post) || PostAddress.page?(post) || PostAddress.unlisted?(post))
      if in_stream
        stream_post = true
        year = PostAddress.date_year(post)
        paths << "/archive/#{year}/" if year
      end
      # A tag page is built from the STREAM, exactly like a series page:
      # a tag carried only by a draft, a page or an unlisted post never
      # gets one. Counting those tags as known made every link to such a
      # tag look sound -- including the ones the site puts in its own menu,
      # on every page, where doctor then called the menu fine.
      (in_stream ? Array(post['tags']) : []).each do |tag|
        slug = Slug.slugify(tag.to_s)
        next if slug.empty?

        stream_tag = true
        paths << "/tag/#{slug}/"
        # A tag the site names in its menu gets a feed of its own. Which
        # tags those are is a config question, so the feed is accepted
        # wherever the tag itself is known rather than worked out again.
        paths << "/tag/#{slug}/rss.xml"
      end
      # Series listings are derived the same way tag listings are -- from a
      # key the post carries -- so unlike the content types there is nothing
      # to guess and no second opinion to drift. One rule of the build does
      # carry over, though: a series only gets a page once two posts in the
      # stream share it -- a "series" of one is a post. Accepting the
      # address for every carrier of the key waved through dead links to
      # pages the build never writes.
      series = Slug.slugify(post['series'].to_s)
      paths << "/series/#{series}/" if series_sizes[series] >= 2
      # Only for a post the site actually serves: the build writes a
      # redirect stub for a post's old addresses, and a draft has no page
      # to redirect TO -- so counting its former addresses as known let a
      # link to one pass as sound while the reader gets a 404.
      if in_stream || !draft?(post)
        Array(post['former_slugs']).each { |former| paths << "/posts/#{former}/" }
        # ...and only the ones the build will actually serve. It refuses a
        # redirect_from whose first segment belongs to the site itself, or
        # whose shape it cannot make a directory of, and says so once in
        # the middle of a build log. Counting those among the addresses
        # the site answers at passed every link to them as sound -- under
        # a closing sentence that names redirects by name.
        Array(post['redirect_from']).each do |origin|
          paths << origin.to_s if PostAddress.redirect_refusal(origin).nil?
        end
      end
    end
    # The map exists once one post is in the stream; the tag index once
    # one of those carries a tag. A site whose tags all live on drafts,
    # pages or unlisted posts has neither.
    paths << '/archive/' if stream_post
    paths << '/tag/' if stream_tag
    paths
  end

  # --- the checks ----------------------------------------------------------


  # Where this post's media are, asked the same way the build asks: the
  # year of the FILE, and -- for an archive written before that was settled
  # -- the year of the date if the first has nothing. Answering it
  # differently from the build is what let one of them report a hole the
  # other one had never noticed.
  # The reader's question about a media file: is there a plain, readable,
  # non-empty file at this path? A directory, a permission bit and an
  # interrupted download all answer File.exist? and all break the page.
  def readable_media_file?(path)
    File.file?(path) && File.readable?(path) && !File.size?(path).nil?
  end

  # Which of the three it was. The sentence used to list all three every
  # time -- "empty, unreadable, or not a file at all" -- so whoever read
  # it had to go and look themselves, and the three want different
  # answers: a folder is deleted, a permission bit is chmod'ed, an empty
  # file is fetched again. Asked in the order the failures shadow each
  # other in: a directory is unreadable AND sizeless, so it has to be
  # named first.
  def unusable_media_cause(path)
    return 'dir' if File.directory?(path)
    # A symlink whose target is gone answers File.readable? with false, so
    # it was reported as a missing read permission and the fix text told the
    # author to chmod a file that is not there. The advice cannot work, and
    # following it teaches them the tool is wrong about something else too.
    # Asked before readable? for the same reason `dir` is: the shapes shadow
    # each other, so the more specific one has to be named first.
    return 'broken_link' if File.symlink?(path) && !File.exist?(path)
    return 'unreadable' unless File.readable?(path)

    'empty'
  end

  def media_dir_for(root, post)
    by_file = File.join(root, 'media.nosync', post['__year'].to_s, post['slug'].to_s)
    return by_file if Dir.exist?(by_file)

    by_date = File.join(root, 'media.nosync', PostAddress.date_year(post), post['slug'].to_s)
    Dir.exist?(by_date) ? by_date : by_file
  end

  # Which file on disk a reference means -- the one question both media
  # checks were answering differently, and the reason `--repair` could put
  # a live photograph in the trash.
  #
  # `File.exist?` asks the VOLUME, and on macOS the volume resolves both
  # letter case and unicode normalisation: a post naming IMG_2043.JPG finds
  # img_2043.jpg and the page renders. `Dir.children` compares bytes, so
  # the same file, seen from the other side, belonged to nobody -- a stray.
  # One said the archive was whole, the other offered to tidy the photograph
  # away, and both were reading the same directory.
  #
  # Three ways a name can be claimed, in this order:
  #   :exact    -- the directory holds it byte for byte.
  #   :identity -- the volume resolves the reference to a file the directory
  #                writes differently. Decided by dev+ino (File.identical?),
  #                which is the volume's OWN notion of sameness: two
  #                spellings of one file share it, two real files never do.
  #   :fold     -- the volume resolves nothing (Linux, case-sensitive APFS)
  #                but exactly one file differs only in case or unicode
  #                form. Two candidates mean two files, and then the machine
  #                does not guess: the reference is simply missing.
  def claim_media(dir, urls)
    children = Dir.exist?(dir) ? Dir.children(dir).reject { |f| f.start_with?('.') } : []
    by_fold = children.group_by { |name| fold_name(name) }

    urls.to_h do |url|
      [url, claim_one(dir, url, children, by_fold)]
    end
  end

  def claim_one(dir, url, children, by_fold)
    # The name being in the directory is not the same as the file being
    # there: a dangling symlink is listed by Dir.children and opens to
    # nothing. The build copies by reading, so it reported the picture as
    # MISSING while check -- trusting the name alone -- called the archive
    # sound and left the page pointing at an address with no file behind it.
    return [url, :exact] if children.include?(url) && File.exist?(File.join(dir, url))

    referenced = File.join(dir, url)
    if File.exist?(referenced)
      same = children.find { |name| File.identical?(referenced, File.join(dir, name)) }
      return [same, :identity] if same
    end

    folded = by_fold[fold_name(url)]
    folded && folded.size == 1 ? [folded.first, :fold] : nil
  end

  # Case and unicode form removed, and nothing else: this is only ever used
  # to ask "could these two spellings be one file", never to rename anything.
  def fold_name(name)
    # scrub FIRST: an export that lied about its encoding can put a byte in
    # a filename that is not valid UTF-8 at all, and both unicode_normalize
    # and downcase raise on it -- which used to take the whole run down,
    # because the rescue called the very method that had just raised.
    clean = name.to_s.scrub
    clean.unicode_normalize(:nfc).downcase
  rescue ArgumentError, Encoding::CompatibilityError
    clean.b.downcase
  end

  # Kept here rather than borrowed from the markdown parser: this walks an
  # archive that may hold videos no parser of ours ever wrote, and the
  # question is only what to open, not what to accept.
  VIDEO_EXTENSIONS = %w[.mp4 .mov .m4v].freeze

  # A post whose media never arrived. The import summary said so at the
  # time and nothing has said so since, which is why a whole archive can
  # carry these for years without anyone knowing.
  def check_media(root, posts, progress, cap = CAP)
    missing = []
    misnamed = []
    unusable = []
    tail_index = []
    posts.each_with_index do |post, index|
      progress&.call(index + 1, posts.size)
      dir = media_dir_for(root, post)
      rel_dir = dir.sub("#{File.join(root, 'media.nosync')}/", '')
      urls = media_urls(post).reject { |url| url.empty? || url.include?('://') }
      claim_media(dir, urls).each do |url, claim|
        # Present under its name and useless to a reader: empty (an
        # interrupted download), unreadable (a permission bit), or not a
        # file at all (a directory where a picture should be). File.exist?
        # says yes to every one of them, the page shows a broken picture,
        # and the copy into public.nosync either carries the defect to the
        # server or stops the build with a raw Errno -- so the test here is
        # the reader's, not the name's. Its own kind and its own sentence,
        # because "missing from its media directory" is false about a file
        # somebody is looking straight at.
        if claim && !readable_media_file?(File.join(dir, claim.first))
          unusable << [post['slug'], claim.first, post['__year'], rel_dir,
                       unusable_media_cause(File.join(dir, claim.first))]
        elsif claim.nil?
          missing << [post['slug'], url, post['__year']]
        elsif claim.last == :exact && VIDEO_EXTENSIONS.include?(File.extname(claim.first).downcase) &&
              VideoProbe.faststart?(File.join(dir, claim.first)) == false
          # Not a hole and not a fault -- the video plays. It simply makes
          # every reader wait for the whole file before the first frame,
          # because the index a player needs to start sits behind the
          # picture. A recorder cannot write it anywhere else; a repack
          # afterwards can. Asked only of a file whose name matched
          # exactly, so this never opens a file the checks above are
          # already unhappy about.
          tail_index << [post['slug'], claim.first, post['__year'], rel_dir]
        elsif claim.last != :exact
          # Whether this post ALSO refers to the correct spelling somewhere
          # else. The repair pass refuses the rename in that case -- two
          # blocks would end up sharing one url and which picture was lost
          # is not a machine's question -- but it refused at apply time,
          # after offering the rename in full and taking the keypress. The
          # answer is known here, so the offer is never made.
          misnamed << [post['slug'], url, claim.first, claim.last, post['__year'], rel_dir,
                       urls.include?(claim.first)]
        end
      end
    end
    return [] if missing.empty? && misnamed.empty? && unusable.empty? && tail_index.empty?

    capped(missing.map do |slug, url, year|
      error(t('media_missing', slug: slug, file: url), t('media_missing_fix'),
            kind: :media_missing, data: { 'slug' => slug, 'file' => url, 'year' => year })
    end, cap) +
      capped(unusable.map do |slug, file, year, rel, cause|
        error(t('media_unusable', slug: slug, file: file, cause: t("media_cause_#{cause}")),
              t('media_unusable_fix'),
              kind: :media_unusable,
              data: { 'slug' => slug, 'file' => file, 'year' => year, 'dir' => rel, 'cause' => cause })
      end, cap) +
      # Not "missing" -- the file is right there, under a spelling the post
      # does not use. Whether it is broken depends on the volume: where the
      # filesystem resolves the difference the page renders today (a
      # warning), where it does not the hole is already there (an error).
      # And when the two spellings look identical on screen -- NFC against
      # NFD -- the sentence has to say so, or it reads as nonsense.
      capped(misnamed.map do |slug, url, actual, how, year, rel, in_use|
        key = url.unicode_normalize(:nfc) == actual.unicode_normalize(:nfc) &&
              url.downcase != actual.downcase ? 'media_misnamed_form' : 'media_misnamed'
        text = t(key, slug: slug, file: url, actual: actual)
        data = { 'slug' => slug, 'file' => url, 'actual' => actual, 'year' => year,
                 'match' => how.to_s, 'dir' => rel, 'actual_in_use' => in_use }
        fix = t(in_use ? 'media_misnamed_both_fix' : 'media_misnamed_fix')
        how == :fold ? error(text, fix, kind: :media_misnamed, data: data)
                     : warn(text, fix, kind: :media_misnamed, data: data)
      end, cap) +
      capped(tail_index.map do |slug, file, year, rel|
        warn(t('media_tail_index', slug: slug, file: file), t('media_tail_index_fix'),
             kind: :media_tail_index,
             data: { 'slug' => slug, 'file' => file, 'year' => year, 'dir' => rel })
      end, cap)
  end

  # Images the build will drop on the floor: a size of 1px or less is the
  # tracking pixel rule, and the block goes with its caption. Nothing on
  # the rendered page shows that anything used to be there.
  def check_degenerate_images(posts, cap = CAP)
    found = posts.flat_map do |post|
      (Array(post['content']) || []).filter_map do |block|
        next unless block.is_a?(Hash) && block['type'] == 'image'

        media = (block['media'] || []).first || {}
        w = Integer(media['width'], exception: false)
        h = Integer(media['height'], exception: false)
        next if w.nil? || h.nil?

        [post['slug'], media['url'].to_s, w, h] if w <= 1 || h <= 1
      end
    end
    return [] if found.empty?

    capped(found.map do |slug, url, w, h|
      warn(t('image_degenerate', slug: slug, file: url, width: w, height: h), t('image_degenerate_fix'),
           kind: :image_degenerate, data: { 'slug' => slug, 'file' => url, 'width' => w, 'height' => h })
    end, cap)
  end


  # Percent escapes undone and nothing else -- no "+" for space, which is a
  # rule of query strings, not of paths, and turning a literal plus into a
  # space is how a working address becomes a broken one.
  def percent_decoded(path)
    decoded = path.to_s.gsub(/%[0-9A-Fa-f]{2}/) { |escape| escape[1, 2].hex.chr }
                  .force_encoding(Encoding::UTF_8)
    decoded.valid_encoding? ? decoded : path.to_s
  end

  # Links from one post to another address on this site that nothing will
  # ever answer at -- the residue of an import that rewrote permalinks, or
  # of a slug that was renamed before renaming kept a redirect.
  def check_internal_links(posts, known, cap = CAP)
    dead = []
    posts.each do |post|
      internal_links(post).each do |url|
        path = url.split('#').first.split('?').first.to_s
        next if path.empty? || path.start_with?('/type/') || path.start_with?('/assets/')
        # Both spellings: a browser writes an accented address with percent
        # escapes, and the addresses this site answers at are written plain.
        # Comparing only the literal one reported a working link as dead --
        # for ever, because repairing it changes nothing a literal
        # comparison can see.
        next if [path, percent_decoded(path)].any? { |form| known.include?(form) || known.include?("#{form}/") }

        # A later page of a listing is judged by the listing it belongs to.
        base = path.sub(PAGE_SUFFIX, '/')
        next if base != path && (known.include?(base) || known.include?("#{base}/"))

        dead << [post['slug'], url, post['__year']]
      end
    end
    return [] if dead.empty?

    capped(dead.map do |slug, url, year|
      error(t('link_dead', slug: slug, url: url), t('link_dead_fix'),
            kind: :link_dead, data: { 'slug' => slug, 'url' => url, 'year' => year })
    end, cap)
  end

  # Links that are written relative to wherever they happen to be read
  # from. `./?item=other-post`, `photo/index.php?gallery=3`, `../about/` --
  # the shapes a dynamic site could afford and a static one cannot.
  #
  # These were invisible here until now, and not because nobody looked:
  # internal_links keeps what starts with a slash and external_links keeps
  # what carries a scheme, so a relative address fell between the two and
  # was checked by neither, `--online` included.
  #
  # What makes it worth its own kind is that these are not 404s. A static
  # host ignores the query string, so /posts/2005/a-post/?item=another-post
  # answers 200 with the post the reader is already on. Nothing fails,
  # nothing is logged, and the reader simply never arrives -- which is why
  # 73 of them sat in one archive through every audit it ever had.
  def check_relative_links(posts, cap = CAP)
    found = posts.flat_map do |post|
      all_links(post).select { |url| relative_link?(url) }.map { |url| [post['slug'], url, post['__year']] }
    end
    return [] if found.empty?

    capped(found.map do |slug, url, year|
      error(t('link_relative', slug: slug, url: url), t('link_relative_fix'),
            kind: :link_relative, data: { 'slug' => slug, 'url' => url, 'year' => year })
    end, cap)
  end

  # Media directories no post claims. Pure disk, invisible from anywhere --
  # left behind by a delete, a rename, or an import that ran twice.
  def check_orphan_media(root, posts, cap = CAP)
    media_root = File.join(root, 'media.nosync')
    return [] unless Dir.exist?(media_root)

    # BOTH years a post can own media under: the folder its file sits in,
    # and the year in its date. The two differ whenever a date was
    # corrected across a New Year -- which the engine treats as ordinary
    # and the build reads media from either -- so counting only the folder
    # called a directory the site is serving from "orphaned", and
    # --repair then offered to put a live photograph in the trash.
    owned = posts.flat_map do |post|
      slug = post['slug'].to_s
      [File.join(post['__year'].to_s, slug), File.join(PostAddress.date_year(post), slug)]
    end.to_set
    orphans = PathGlob.under(media_root, '*', '*').select { |p| File.directory?(p) }.filter_map do |dir|
      rel = dir.sub("#{media_root}/", '')
      rel unless owned.include?(rel)
    end
    return [] if orphans.empty?

    capped(orphans.map do |rel|
      warn(t('media_orphan', dir: rel), t('media_orphan_fix'),
           kind: :media_orphan, data: { 'dir' => rel })
    end, cap)
  end

  # The same leftovers one level down: files inside a directory a post
  # DOES own, that the post no longer references. A source that dropped a
  # picture leaves its file behind -- an import only ever adds -- and
  # until now nothing anywhere could see it: check_media asks whether
  # referenced files exist, never whether existing files are referenced.
  # After the renumbering fix these strays are the one shape of orphan
  # left standing, and they were invisible from every side.
  def check_stray_media(root, posts, cap = CAP)
    strays = posts.flat_map do |post|
      dir = media_dir_for(root, post)
      next [] unless Dir.exist?(dir)

      # A stray is a file no reference CLAIMS -- not a file whose name no
      # reference spells the same way. That difference is the whole of the
      # blocker this check used to feed.
      claimed = claim_media(dir, media_urls(post)).values.compact.map(&:first).to_set
      rel_dir = dir.sub("#{File.join(root, 'media.nosync')}/", '')
      Dir.children(dir).reject { |f| f.start_with?('.') }
         .reject { |f| claimed.include?(f) }
         .map { |f| [post['slug'], f, post['__year'], rel_dir] }
    end
    return [] if strays.empty?

    # `dir` is the directory that was actually walked -- which, for a post
    # whose file sits in another year than its date, is not the one `year`
    # names. --repair rebuilt the path from `year` and offered to trash a
    # file at an address that does not exist, and failed every time.
    capped(strays.map do |slug, file, year, rel|
      warn(t('media_stray', slug: slug, file: file), t('media_stray_fix'),
           kind: :media_stray, data: { 'slug' => slug, 'file' => file, 'year' => year, 'dir' => rel })
    end, cap)
  end

  # Two posts that would be served at one address. The build refuses to run
  # at all in this state (it would write one over the other and mix their
  # media), so a check that calls the archive sound is telling the author
  # the opposite of what they are about to find out.
  def check_duplicate_addresses(posts, cap = CAP)
    # Grouped by EVERY key a post can collide on, and drafts included --
    # both of them mirroring what the build actually refuses to run on.
    # One key per post was the hole: a page went into the page group and
    # out of the year group, so a page and a post sharing a slug in one
    # year never met here -- while the build, which keys both of them by
    # year and slug, stopped dead on exactly that pair. check handed out a
    # clean bill for an archive that could not be built at all.
    ordered = {}
    posts.each do |post|
      PostAddress.collision_keys(post).each { |key| (ordered[key] ||= []) << post }
    end
    colliding = ordered.select { |_, group| group.size > 1 }
    return [] if colliding.empty?

    # Two pages of one slug dated in one year collide on both of their
    # keys. Report the pair once, under the key that names the address a
    # reader would actually type.
    by_files = {}
    colliding.each do |key, group|
      files = group.map { |post| post['__path'].to_s }.sort
      by_files[files] = [key, group] if by_files[files].nil? || key.first == 'page'
    end

    capped(by_files.values.map { |key, group| duplicate_finding(key, group) }, cap)
  end

  # A page has no year in its address, so a message built from one sends
  # the reader to a URL the site does not answer at -- and "give it a date
  # in another year", the advice that ends the other message, changes
  # nothing at all for two pages.
  def duplicate_finding(key, group)
    slug = group.first['slug'].to_s
    files = group.map { |post| post['__path'].to_s }
    # The address does not find the files. A page collides on its slug
    # however far apart the two dates are, so the reader would be grepping
    # the archive for the pair they have to choose between -- and choosing
    # between them IS the fix, so the fix says which two.
    where = files.map do |file|
      "\n   - #{File.join(File.basename(File.dirname(file)), File.basename(file))}"
    end.join
    if key.first == 'page'
      error(t('address_duplicate_page', slug: slug, count: group.size),
            t('address_duplicate_page_fix') + where,
            kind: :address_duplicate,
            data: { 'slug' => slug, 'address' => "/#{slug}/", 'files' => files })
    else
      error(t('address_duplicate', year: key.first, slug: slug, count: group.size),
            t('address_duplicate_fix') + where,
            kind: :address_duplicate,
            data: { 'year' => key.first, 'slug' => slug,
                    'address' => "/posts/#{key.first}/#{slug}/", 'files' => files })
    end
  end

  # Two posts claiming one old address. The build answers with whichever it
  # rendered last, so the loser's readers land on the winner's post and no
  # warning is printed anywhere.
  # Two series whose slugs differ by a character are usually one series
  # with a typo in it -- and the archive keeps the mistake invisible: the
  # misspelling founds its own series, and with fewer than two members it
  # never even gets a page to be noticed on. The draft preview says this
  # at writing time; this is the net for the typo made half a year ago.
  #
  # Two guards against crying wolf, because a check nobody believes is a
  # check nobody runs. Slugs whose difference is digits only are left
  # alone -- rok-2025 next to rok-2026 is two year-series, not a typo.
  # And a distance of two only counts when one side has a single post:
  # two established series that merely have similar names are not news.
  def check_series_names(posts, cap = nil)
    groups = posts.reject { |p| draft?(p) }
                  .group_by { |p| Slug.slugify(p['series'].to_s) }
                  .reject { |slug, _| slug.empty? }
    findings = []
    groups.keys.sort.combination(2) do |a, b|
      next if numberless(a) == numberless(b)

      distance = edit_distance(a, b)
      next if distance > 2
      next if distance == 2 && [groups[a].size, groups[b].size].min > 1

      names = [a, b].map { |slug| groups[slug].map { |p| p['series'].to_s.strip }.uniq.first }
      findings << warn(t('series_similar', a: names[0], count_a: groups[a].size,
                                           b: names[1], count_b: groups[b].size),
                       t('series_similar_fix'),
                       kind: :series_similar,
                       data: { 'a' => names[0], 'posts_a' => groups[a].size,
                               'b' => names[1], 'posts_b' => groups[b].size })
    end
    capped(findings, cap)
  end

  # What is left of a slug once its numbers are gone -- and once the
  # separators those numbers were holding apart have closed up behind
  # them. Dropping the digits alone was not enough: a version suffix
  # takes a separator with it, so "blog-sh-v1-2" and "blog-sh-v1-2-1"
  # came out as "blog-sh-v-" and "blog-sh-v--", which is a difference,
  # and every series named after a release was reported as a typo of the
  # patch release beside it. Found on this engine's own site, on the day
  # its posts were first grouped by version.
  #
  # It stays narrow on purpose: only runs of digits and the separators
  # they leave behind are collapsed, so "photo-2024" and "photos-2024"
  # -- a real typo, one letter apart -- are still two different things.
  def numberless(slug)
    slug.gsub(/\d+/, '').squeeze('-').chomp('-')
  end

  # Plain Levenshtein over two short slugs; nothing here is hot.
  def edit_distance(a, b)
    return (a.length - b.length).abs if a.empty? || b.empty?

    previous = (0..b.length).to_a
    a.each_char.with_index do |ca, i|
      current = [i + 1]
      b.each_char.with_index do |cb, j|
        current << [previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)].min
      end
      previous = current
    end
    previous.last
  end

  # Every redirect_from the build will refuse to serve, said here instead
  # of once in the middle of a build log nobody keeps. The two refusals are
  # kept apart because they are different mistakes: a reserved first
  # segment is a redirect somebody wrote by hand into the site's own
  # namespace, an unusable one is a shape no directory can be made of.
  def check_redirect_entries(posts, cap = nil)
    findings = posts.flat_map do |post|
      Array(post['redirect_from']).filter_map do |origin|
        refusal = PostAddress.redirect_refusal(origin)
        next if refusal.nil?

        warn(t("redirect_from_#{refusal}", slug: post['slug'].to_s, entry: origin.to_s),
             t("redirect_from_#{refusal}_fix"),
             kind: :"redirect_from_#{refusal}",
             data: { 'slug' => post['slug'].to_s, 'entry' => origin.to_s,
                     'year' => PostAddress.file_year(post).to_s })
      end
    end
    capped(findings, cap)
  end

  def check_redirects(posts, cap = nil)
    claims = Hash.new { |h, k| h[k] = [] }
    posts.each do |post|
      Array(post['redirect_from']).each { |origin| claims[origin.to_s] << post['slug'] }
      Array(post['former_slugs']).each { |former| claims["/posts/#{former}/"] << post['slug'] }
    end
    capped(claims.filter_map do |origin, slugs|
      next if slugs.uniq.size < 2

      error(t('redirect_collision', origin: origin, slugs: slugs.uniq.join(', ')), t('redirect_collision_fix'),
            kind: :redirect_collision, data: { 'origin' => origin, 'slugs' => slugs.uniq })
    end, cap)
  end

  # --- the outside world (--online only) -----------------------------------

  # Asked for by name, never as part of an ordinary run: this is the only
  # part of check that leaves the machine, it takes minutes rather than a
  # second, and over an archive going back twenty years it will find things
  # nobody can do anything about.
  #
  # What counts as a finding is deliberately narrow. A host that does not
  # resolve, and a 404/410, are the web saying "this is gone". A timeout, a
  # refused connection, a 5xx, a TLS error, a 403 -- those are the web
  # saying "not right now", and reporting them turns one flaky evening into
  # forty findings that are all still fine tomorrow. A checker nobody
  # believes is worse than no checker.
  ONLINE_GONE = [404, 410].freeze
  # Politeness rather than throughput: one request at a time, and a pause
  # between two requests to the SAME host. An archive with two hundred
  # links to one site should not read as an attack on it.
  ONLINE_HOST_PAUSE = 1.0

  def check_external_links(posts, cache: nil, online_progress: nil, cap: CAP)
    urls = external_urls(posts)
    return [] if urls.empty?

    results = {}
    last_seen = {}
    urls.each_with_index do |url, index|
      online_progress&.call(index + 1, urls.size)
      cached = cache && cache.fetch(url)
      if cached
        results[url] = cached
        next
      end

      host = begin
        URI.parse(url).host
      rescue URI::InvalidURIError
        nil
      end
      if host && last_seen[host]
        wait = ONLINE_HOST_PAUSE - (Time.now - last_seen[host])
        sleep(wait) if wait.positive?
      end
      verdict = probe(url)
      last_seen[host] = Time.now if host
      results[url] = verdict
      cache&.store(url, verdict)
    end

    gone = results.select { |_, verdict| verdict[:gone] }
    return [ok(t('online_ok', count: urls.size), kind: :online_ok, data: { 'checked' => urls.size })] if gone.empty?

    owners = url_owners(posts)
    capped(gone.keys.map do |url|
      error(t('link_gone', slug: owners[url].to_s, url: url, reason: gone[url][:reason]),
            t('link_gone_fix'),
            kind: :link_gone,
            data: { 'slug' => owners[url].to_s, 'url' => url, 'reason' => gone[url][:reason] })
    end, cap)
  end

  # HEAD first: a link checker has no use for the body, and a HEAD over a
  # few thousand links is the difference between minutes and an afternoon.
  #
  # But HEAD is never believed when it says the page is GONE. Some servers
  # answer it with 405 or 501 while serving GET perfectly; worse, some
  # answer 404 to HEAD and 200 to GET for the very same address --
  # bsky.app does exactly this on profile pages, and the first run of this
  # check over a real archive reported thirty-four live links as dead
  # because of it. So anything that looks fatal is confirmed with a GET,
  # which costs one extra request per apparently-dead link and buys the
  # only thing this tool has: being right.
  RETRY_WITH_GET = ([405, 501] + ONLINE_GONE).freeze

  def probe(url, redirects_left = 4)
    uri = URI.parse(url)
    return { gone: false } unless uri.is_a?(URI::HTTP) && uri.host

    res = request(uri, Net::HTTP::Head)
    res = request(uri, Net::HTTP::Get) if res.is_a?(Net::HTTPResponse) && RETRY_WITH_GET.include?(res.code.to_i)

    case res
    when :dns
      { gone: true, reason: t('reason_no_host') }
    when :unreachable, nil
      { gone: false }
    else
      code = res.code.to_i
      if [301, 302, 303, 307, 308].include?(code) && res['location'] && redirects_left.positive?
        return probe(URI.join(url, res['location']).to_s, redirects_left - 1)
      end

      ONLINE_GONE.include?(code) ? { gone: true, reason: code.to_s } : { gone: false }
    end
  rescue URI::Error
    { gone: false }
  end

  def request(uri, klass)
    # Required here rather than at the top of the file, and it is not
    # tidiness: feed_http reads SiteConfig at LOAD time, and doctor --
    # which shares this file's knowledge of what addresses exist --
    # has to run on a config nothing else can read. Requiring it up
    # there killed doctor on an unreadable site.yml, which is the one
    # case doctor exists for. Same lazy-require reasoning as rexml in
    # the sidebar fetchers (docs/decisions.md).
    require_relative 'feed_http'
    req = klass.new(uri)
    req['User-Agent'] = FeedHttp::USER_AGENT
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 10, read_timeout: 15) do |http|
      http.request(req)
    end
  rescue SocketError
    # The host does not resolve at all -- a dead domain, which is the one
    # network condition that will still be true tomorrow.
    :dns
  rescue StandardError, Timeout::Error
    :unreachable
  end

  def external_urls(posts)
    posts.flat_map { |post| all_links(post) }
         .select { |url| url.start_with?('http://', 'https://') }
         .uniq
  end

  # Which post to name in the finding. The first one that carries the link:
  # the same dead address usually sits in several, and listing all of them
  # would bury the twenty findings under their own footnotes.
  def url_owners(posts)
    posts.each_with_object({}) do |post, acc|
      all_links(post).each { |url| acc[url] ||= post['slug'] }
    end
  end

  # --- shared --------------------------------------------------------------

  # Long lists are capped rather than printed in full: a thousand identical
  # findings is not more information than twenty, and it buries every other
  # kind. The count of what was left out is part of the report, though --
  # silently truncating would read as "that was all of it". The line takes
  # the level of the kind it truncates, so twenty-five missing files do not
  # end in a tail that reads as housekeeping, and it carries the count of
  # what it stands for, so the summary can say how big the problem is
  # rather than how long the printout was.
  def more(remaining, level)
    return [] unless remaining.positive?

    [Finding.new(level: level, text: t('and_more', count: remaining), count: remaining,
                 kind: :and_more, data: { 'count' => remaining })]
  end

  # Both places a block keeps a file: the media themselves and a video's
  # poster. The poster was missing from this list for as long as the list
  # existed, which cut both ways at once -- a poster file that vanished
  # was never reported missing, and the stray check below would have
  # reported every poster that exists as a leftover.
  def media_urls(post)
    (Array(post['content']) || []).flat_map do |block|
      next [] unless block.is_a?(Hash)

      %w[media poster].flat_map do |key|
        Array(block[key]).filter_map { |m| m['url'].to_s if m.is_a?(Hash) }
      end
    end
  end

  def internal_links(post)
    all_links(post).select { |url| url.start_with?('/') }
  end

  # A scheme is anything up to the first colon that looks like one, so this
  # keeps http, https, mailto, tel and data out of the relative bucket
  # without naming them: a link the browser hands to another program is not
  # this check's business.
  SCHEME = /\A[a-z][a-z0-9+.\-]*:/i

  # Everything that is neither rooted at the site (check_internal_links
  # owns those) nor absolute (check_external_links, and only with
  # --online). A bare fragment is left alone on purpose: `#footnote-2`
  # resolving against the page it is written on is the whole point of it.
  def relative_link?(url)
    text = url.to_s.strip
    return false if text.empty? || text.start_with?('/', '#')

    !text.match?(SCHEME)
  end

  # Both places a link can live: a block that is a link card, and a
  # formatting span inside any text the post carries.
  def all_links(post)
    (Array(post['content']) || []).flat_map do |block|
      next [] unless block.is_a?(Hash)

      urls = []
      urls << block['url'].to_s if block['type'] == 'link'
      Array(block['formatting']).each do |span|
        urls << span['url'].to_s if span.is_a?(Hash) && span['type'] == 'link'
      end
      Array(block['items']).each do |item|
        Array(item.is_a?(Hash) ? item['formatting'] : nil).each do |span|
          urls << span['url'].to_s if span.is_a?(Hash) && span['type'] == 'link'
        end
      end
      urls
    end.reject(&:empty?)
  end

  # Remembers what an address answered, so a second run only asks about the
  # links it has not seen lately. Without it nobody runs this twice: a few
  # thousand requests is minutes, and most of the answers were the same
  # yesterday.
  #
  # A failure to read or write it is not an error -- the check simply asks
  # the network again, which is the thing it was going to do anyway.
  class Cache
    MAX_AGE = 14 * 24 * 60 * 60

    def initialize(path)
      @path = path
      @data = File.exist?(path) ? (JSON.parse(File.read(path, encoding: 'utf-8')) || {}) : {}
      @data = {} unless @data.is_a?(Hash)
      @dirty = false
    rescue StandardError
      @data = {}
      @dirty = false
    end

    def fetch(url)
      entry = @data[url]
      return nil unless entry.is_a?(Hash) && entry['at'].is_a?(Numeric)
      return nil if Time.now.to_i - entry['at'] > MAX_AGE

      { gone: entry['gone'] ? true : false, reason: entry['reason'] }
    end

    def store(url, verdict)
      @data[url] = { 'gone' => verdict[:gone], 'reason' => verdict[:reason], 'at' => Time.now.to_i }
      @dirty = true
    end

    def save
      return unless @dirty

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(@data), encoding: 'utf-8')
    rescue StandardError
      nil
    end
  end
end
