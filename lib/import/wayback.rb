# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'tempfile'
require 'uri'
require_relative '../i18n'
require_relative 'feed'

module Import
  # Rescues a blog from the Wayback Machine -- for the platform that no
  # longer exists (blog.cz, Posterous, MySpace, a deleted account
  # anywhere). The trick is not scraping pages: the Wayback Machine
  # archived the blog's FEED too, over and over across the years, and
  # each capture carries the posts of its day. Read every distinct
  # capture oldest-first and the whole history reassembles itself --
  # re-import matching merges the overlaps, newer captures win.
  #
  # Images ride the same time machine: every image URL is rerouted
  # through web.archive.org, which redirects to its nearest capture of
  # that file. What the Archive never saw is lost and counted -- this
  # tool recovers what exists, it cannot invent what doesn't.
  class Wayback
    CDX = 'https://web.archive.org/cdx/search/cdx'
    # Where platforms kept their feeds, tried in this order when the
    # given URL is not already one.
    FEED_PATHS = %w[rss feed atom.xml index.xml rss.xml feed/rss rss-kanal feeds/posts/default].freeze
    # The Archive rate-limits, and a rescue is exactly the shape of
    # traffic it rate-limits: dozens of queries in a row from one client.
    # A 5xx during one of those means "not now", not "not there", so it
    # is waited out rather than believed.
    RETRIES = 4
    RETRY_BACKOFF = 15
    # The network failures worth a second try: a connection the Archive
    # dropped, never completed, or REFUSED. Refusal belongs here -- under
    # load the Archive stops answering at the TCP level rather than with a
    # status, and a rescue that downloads images meets that long before it
    # meets a 503. A bad certificate is not going to fix itself in fifteen
    # seconds; a refused connection routinely does.
    TRANSIENT = [Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Errno::EHOSTUNREACH,
                 Errno::ETIMEDOUT, SocketError, Net::OpenTimeout, Net::ReadTimeout].freeze

    # Raised for a failure that may pass on its own, and caught by the
    # retry in http_get. Anything else stays what it was.
    Busy = Class.new(StandardError)

    attr_accessor :keep_permalinks

    # post_pattern is a regex string for page mode: which archived PATHS
    # are posts (as opposed to listings, tag pages, calendars). A
    # platform pack supplies it for hosts it knows; anywhere else the
    # user does, or page mode refuses with samples to build one from.
    # The knobs, with their environment variables as the default for each.
    # ./import.sh builds this object itself and used to pass nothing at
    # all, so its advice ("raise WAYBACK_DELAY", "pass POST_PATTERN")
    # named variables that only scripts/migrate_wayback.rb read -- the
    # person followed it, nothing changed, and a run that needs
    # POST_PATTERN had no way out of the wizard at all.
    def self.from_env(url, **overrides)
      mode = :auto
      mode = :pages if ENV['WAYBACK_MODE'].to_s == 'pages'
      new(url, mode: mode,
          delay: ENV['WAYBACK_DELAY'].to_s.strip.empty? ? 1.0 : ENV['WAYBACK_DELAY'],
          post_pattern: ENV['POST_PATTERN'],
          pack: ENV['WAYBACK_PACK'],
          from: ENV['WAYBACK_FROM'], to: ENV['WAYBACK_TO'],
          **overrides)
    end

    def initialize(url, delay: 1.0, post_pattern: nil, mode: :auto, keep_permalinks: false, pack: nil,
                   from: nil, to: nil)
      # A web.archive.org address is the Archive's copy of a page, not the
      # site. Pasted here -- which is exactly what somebody who has just
      # been LOOKING at the old site in the Archive will do -- every
      # candidate asked the Archive about itself, every answer was empty,
      # and the run ended saying the site had never been captured.
      if url.to_s.match?(%r{\Ahttps?://web\.archive\.org/}i)
        abort("❌ That is the Archive's own address for a copy of a page. Give the ORIGINAL " \
              "address of the site instead -- the part after the timestamp in that URL.")
      end

      @url = url.sub(%r{/+\z}, '')
      @from = stamp(from, 'WAYBACK_FROM')
      @to = stamp(to, 'WAYBACK_TO')
      # Refused with a sentence, the way the two stamps above refuse
      # theirs. Unchecked, a typo ("2", "2s") went through .to_f as the
      # most aggressive run possible against a service this file documents
      # as rate-limiting -- set by somebody trying to be GENTLER -- and a
      # negative value made every request look like the Archive timing out.
      @delay = Float(delay, exception: false)
      abort("❌ WAYBACK_DELAY takes seconds between requests (1, 2.5) -- got #{delay.inspect}") if @delay.nil? || @delay.negative?
      # An empty pattern is no pattern -- '' compiles to //, which matches
      # every archived path: the front page, every monthly listing and the
      # feed itself all became posts, and pack detection was silently off.
      # A pattern that will not compile is refused with the parser's own
      # sentence rather than dumped as a backtrace over the wizard.
      @post_pattern =
        unless post_pattern.to_s.empty?
          begin
            Regexp.new(post_pattern)
          rescue RegexpError => e
            abort("❌ POST_PATTERN is not a usable regular expression: #{e.message}")
          end
        end
      @mode = mode
      @keep_permalinks = keep_permalinks
      @pack_name = pack.to_s.empty? ? nil : pack.to_s
      @snapshots_read = 0
      @unreadable = 0
      @unanswered_captures = 0
      @lost_images = 0
      @unparsed = 0
      @dated_by_capture = 0
      @summary_only = 0
      @summary_rescued = 0
      @full_bodied = 0
      @archived_images = nil
      # Queries the Archive never answered. Kept apart from queries that
      # came back empty, because only the second kind says anything about
      # the blog -- see refuse_unanswered.
      @cdx_failures = []
      @cdx_truncated = []
      # The snapshot files, so the run can take them away after itself --
      # see snapshot_feed.
      @tempfiles = []
      @pack =
        if @pack_name
          PACKS.find { |p| p.key == @pack_name } ||
            abort("❌ Unknown pack '#{@pack_name}'. Built-in packs: #{PACKS.map(&:key).join(', ')}")
        else
          PACKS.find { |p| p.matches?(host) }
        end
      @sniffed = false
    end

    def label
      "Wayback rescue (#{host})"
    end

    def preamble
      "Asking the Wayback Machine what it kept of #{host}…"
    end

    def total
      @total
    end

    # The rescued blog collects under its own domain's tag -- /tag/blog.cz/
    # is the whole saved blog, same convention as a live feed import.
    def platform_tag
      host.sub(/\Awww\./, '')
    end

    # Feeds first -- machine-readable and cheap. A blog the Archive only
    # ever saw as pages (no feed captures) falls through to page mode:
    # every archived post page, newest capture of each, read one by one.
    def each_item(&block)
      probe_images
      begin
        walk_source(&block)
      ensure
        # A rescue reads thousands of captures, each through a temp file,
        # on a disk it has just filled with media. `ensure`, so an
        # interrupted run cleans up after itself too.
        @tempfiles.each { |path| File.delete(path) rescue nil }
        @tempfiles.clear
      end
    end

    def walk_source(&block)
      unless @mode == :pages
        asked = @cdx_failures.size
        captures = discover
        return each_feed_item(captures, &block) unless captures.empty?

        # Every candidate UNANSWERED and every candidate EMPTY both leave
        # no captures here, and only the second is a fact about the blog.
        # Falling through to page mode on the first sent the rescue after
        # a site whose feed was in the Archive all along, and then blamed
        # the site for not having one.
        refuse_unanswered if @cdx_failures.size > asked
      end

      each_page_item(&block)
    end

    def each_feed_item(captures)
      # Oldest first: overlapping captures then replay history in order,
      # and the newest version of a post is the one that sticks.
      captures.sort_by! { |c| c[:timestamp] }
      captures.each do |capture|
        feed = snapshot_feed(capture)
        next unless feed

        @snapshots_read += 1
        feed.each_item { |item| yield [:feed, feed, item] }
        sleep @delay
      end
    end

    def each_page_item
      pages = post_pages
      @total = pages.size
      pages.each do |page|
        yield [:page, page, nil]
        sleep @delay
      end
    end

    def map(pair, media)
      kind, a, b = pair
      kind == :feed ? map_feed_item(a, b, media) : map_page(a, media)
    end

    def postscript
      notes = []
      notes << I18n.t('import.note.wayback_pack_detected', platform: @pack.key) if @sniffed
      notes << I18n.t('import.note.wayback_window', range: human_window) if @from || @to
      notes << I18n.t('import.note.wayback_snapshots', count: @snapshots_read) if @snapshots_read.positive?
      notes << I18n.t('import.note.wayback_unreadable', count: @unreadable) if @unreadable.positive?
      if @unanswered_captures.positive?
        notes << I18n.t('import.note.wayback_unanswered_captures', count: @unanswered_captures)
      end
      unless @cdx_truncated.empty?
        notes << I18n.t('import.note.wayback_cdx_truncated',
                        limit: CDX_LIMIT, list: @cdx_truncated.uniq.first(3).join(', '))
      end
      notes << I18n.t('import.note.wayback_unparsed', count: @unparsed) if @unparsed.positive?
      notes << I18n.t('import.note.wayback_dated_by_capture', count: @dated_by_capture) if @dated_by_capture.positive?
      notes << I18n.t('import.note.wayback_lost_images', count: @lost_images) if @lost_images.positive?
      # The two things that decide whether a rescue is worth the hours it
      # takes, and neither is visible from the post count alone.
      if @summary_only.positive?
        notes << I18n.t('import.note.wayback_summary_only', count: @summary_only, seen: @summary_only + @full_bodied)
      end
      if @summary_rescued.positive?
        notes << I18n.t('import.note.wayback_summary_rescued', count: @summary_rescued, seen: @summary_only)
      end
      if @archived_images && @archived_images[:total].zero?
        notes << I18n.t('import.note.wayback_no_images', host: host)
      elsif @archived_images
        spread = @archived_images[:years].first(12).map { |year, n| "#{year}: #{n}" }.join(', ')
        notes << I18n.t('import.note.wayback_images_spread', count: @archived_images[:total], host: host, spread: spread)
      end
      # A run that finished still needs to say which questions went
      # unanswered: a feed candidate the Archive refused is a piece of the
      # blog that silently did not come over.
      notes << I18n.t('import.note.wayback_unanswered', count: @cdx_failures.size) if @cdx_failures.any?
      notes.empty? ? nil : notes.join("\n  ")
    end

    private

    def map_feed_item(feed, item, media)
      post = feed.map(item, media)
      return post unless post.is_a?(Hash)

      if summary_only?(item)
        @summary_only += 1
        rescued = full_body_blocks(item, post, media)
        if rescued
          drop_unused_media(post['content'], rescued, media)
          post['content'] = rescued
          @summary_rescued += 1
        end
      else
        @full_bodied += 1
      end

      # The Archive sometimes answers an image URL with an HTML page and
      # a straight-faced 200 -- saved as 01.jpg it would render broken.
      # A real archived image always measures; one that doesn't is not
      # an image and is counted as lost. (Only judgeable on a real run:
      # a dry-run downloads nothing.)
      unless media.dry_run?
        post['content'] = post['content'].reject do |block|
          lost = block['type'] == 'image' && !block.dig('media', 0, 'width')
          if lost
            @lost_images += 1
            media.discard(block.dig('media', 0, 'url'))
          end
          lost
        end
        return :empty if post['content'].empty?
      end

      # The re-import identity stays the feed's own (guid/link, stable
      # across captures); the platform says where this copy CAME from.
      post['source'] = post['source'].merge('platform' => 'wayback')
      post
    end

    # --- page mode ------------------------------------------------------

    # Which archived pages are POSTS. The pack knows its platform's URL
    # shape; a user pattern stands in anywhere else; and with neither,
    # refusing with samples beats importing tag pages as articles.
    def post_pages
      asked = @cdx_failures.size
      rows = cdx_rows("#{host}/*", extra: { 'filter' => ['statuscode:200', 'mimetype:text/html'],
                                            'collapse' => 'urlkey' })
      refuse_unanswered if @cdx_failures.size > asked

      paths = rows.group_by { |r| URI.parse(r[:original]).path rescue nil }
      paths.delete(nil)
      sniff_pack(paths)
      posts = paths.select { |path, _| post_path?(path) }
      if posts.empty?
        sample = paths.keys.reject { |p| p == '/' }.first(12)
        # Asking for a pattern and then printing nothing to build one
        # from is worse than saying there is nothing: the operator spent
        # the next ten minutes looking for their own mistake.
        if sample.empty?
          abort("❌ Nothing to rescue: the Archive kept no post pages of #{host}, only its front page.")
        end

        abort("❌ No feed captures, and no way to tell posts from listings on #{host}.\n" \
              "Pass POST_PATTERN (a regex the post paths match). Archived paths look like:\n  " \
              "#{sample.join("\n  ")}")
      end

      # The NEWEST capture of each page: the most complete version of a
      # post the Archive ever saw.
      posts.map { |path, captures| captures.max_by { |c| c[:timestamp] }.merge(path: path) }
           .sort_by { |c| c[:path] }
    end

    # Neither the host nor the operator named a platform -- so one
    # archived page gets fetched and the packs look at its markup.
    # b2evolution is the whole reason this exists: every installation
    # lived on its own domain, so there is no address shape to know it
    # by, and without this the operator's only path was hand-writing
    # POST_PATTERN for software with a perfectly recognizable template.
    # Best-effort by design: a page the Archive won't serve right now
    # just means no pack, and page mode then refuses with samples the
    # way it always has.
    def sniff_pack(paths)
      return if @pack || @post_pattern

      sample = paths['/'] || paths.each_value.first
      return unless sample

      capture = sample.max_by { |c| c[:timestamp] }
      html = to_utf8(http_get("https://web.archive.org/web/#{capture[:timestamp]}id_/#{capture[:original]}"))
      @pack = PACKS.find { |p| p.respond_to?(:detect?) && p.detect?(html) }
      @sniffed = !@pack.nil?
    rescue StandardError
      nil
    end

    def post_path?(path)
      return @post_pattern.match?(path) if @post_pattern
      return @pack.post_path?(path) if @pack

      false
    end

    def map_page(page, media)
      html = http_get("https://web.archive.org/web/#{page[:timestamp]}id_/#{page[:original]}")
      html = to_utf8(html)
      parsed = @pack&.parse(html) || generic_parse(html)
      unless parsed
        @unparsed += 1
        return :unparsed
      end

      body = reroute_images(parsed[:body], page)
      blocks = localize_images(HtmlBlocks.parse(body).blocks, media)
      return :empty if blocks.empty?

      date = parsed[:date]
      unless date
        @dated_by_capture += 1
        # Archive timestamps are UTC by definition; strptime without a
        # zone read the digits in the site's local zone and shifted every
        # capture-dated post by the UTC offset -- across midnight, into
        # the wrong day and the wrong publish order.
        ts = page[:timestamp]
        date = Time.utc(ts[0, 4].to_i, ts[4, 2].to_i, ts[6, 2].to_i,
                        ts[8, 2].to_i, ts[10, 2].to_i, ts[12, 2].to_i).getlocal
      end

      # Without the extension the permalink happened to carry: a decade of
      # blogs served /2009/06/first-post.html, and slugifying that whole
      # made "first-post-html" -- an address with a word in it nobody
      # wrote, on every post of the site.
      slug = Slug.slugify(File.basename(page[:path], '.*'))
      slug = Slug.slugify(parsed[:title].to_s.split(/\s+/).first(10).join(' ')) if slug.empty?

      post = {
        'slug' => slug,
        'title' => parsed[:title].to_s.empty? ? slug : parsed[:title],
        'date' => date.iso8601,
        'state' => 'published',
        'tags' => parsed[:tags] || [],
        'content' => blocks,
        'source' => {
          'platform' => 'wayback',
          'account' => host,
          'post_url' => page[:original],
          'original_id' => page[:path]
        }
      }
      post['redirect_from'] = [page[:path]] if @keep_permalinks
      strip_fake_images(post, media) || post
    end

    # Same 200-that-is-really-HTML defence the feed path has; returns
    # :empty when nothing survives, nil when the post is fine.
    def strip_fake_images(post, media)
      return nil if media.dry_run?

      post['content'] = post['content'].reject do |block|
        lost = block['type'] == 'image' && !block.dig('media', 0, 'width')
        if lost
          @lost_images += 1
          media.discard(block.dig('media', 0, 'url'))
        end
        lost
      end
      post['content'].empty? ? :empty : nil
    end

    # The era this rescues predates UTF-8 as a habit -- Czech pages in
    # particular spoke windows-1250. Net::HTTP hands the body over as
    # BINARY, so the charset declaration is read from the raw bytes
    # FIRST (an ASCII-only pattern is legal against any encoding);
    # matching UTF-8 regexps against the undecided string is exactly
    # the Encoding::CompatibilityError this method exists to prevent.
    def to_utf8(raw)
      declared = raw.b[/charset=["']?([A-Za-z0-9_-]+)/, 1]
      utf8 = raw.dup.force_encoding('UTF-8')
      # The BYTES decide. A declaration is a claim, and a page rebuilt in
      # UTF-8 whose old <meta> still says windows-1250 -- which is most of
      # what a CMS migration leaves behind -- was re-decoded from a claim
      # that had stopped being true, turning every accented letter into
      # mojibake. Valid UTF-8 is not an accident: a windows-1250 page with
      # accents in it is not valid UTF-8.
      return utf8 if utf8.valid_encoding?

      source = declared && !declared.match?(/\Autf-?8\z/i) ? declared : 'windows-1250'
      raw.dup.force_encoding(source).encode('UTF-8', invalid: :replace, undef: :replace)
    rescue StandardError
      raw.dup.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    # Every image goes back through the time machine: absolutized
    # against the original host, then asked of the Archive at this
    # page's own moment -- it redirects to the nearest copy it holds.
    def reroute_images(body, page)
      # Single quotes and bare values as well. Matching only src="…" left
      # <img src='…'> pointing at a host that is gone -- dropped from the
      # post by the fetch that follows, and counted nowhere, so the
      # postscript said no images had been lost.
      body.gsub(/(<img[^>]*\ssrc=)(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i) do
        prefix = Regexp.last_match(1)
        quote = Regexp.last_match(2) ? '"' : (Regexp.last_match(3) ? "'" : '')
        src = Regexp.last_match(2) || Regexp.last_match(3) || Regexp.last_match(4)
        prefix += quote
        suffix = quote
        absolute = begin
          URI.join(page[:original], src).to_s
        rescue StandardError
          src
        end
        if absolute.start_with?('http') && !absolute.include?('web.archive.org')
          "#{prefix}https://web.archive.org/web/#{page[:timestamp]}id_/#{absolute}#{suffix}"
        else
          "#{prefix}#{src}#{suffix}"
        end
      end
    end

    # The fallback for platforms nobody wrote a pack for: honest and
    # modest. It reads what pages declare -- a heading, a time element
    # or article:published_time, an article container -- and gives up
    # loudly (an :unparsed count) rather than guessing at soup.
    # Where a post stops and the page around it begins. Class and id names
    # a decade of themes agree on, plus the two elements that can only be
    # the furniture.
    BODY_END = %r{<(?:footer|aside)\b|
                  <div[^>]*\b(?:class|id)="[^"]*
                  (?:comment|respond|disqus|sidebar|widget|related|share|
                     post-?nav|entry-?meta|author-?bio|tags?-?list)
                  [^"]*"}xi

    def generic_parse(html)
      body = html[%r{<article[^>]*>(.*?)</article>}m, 1] ||
             html[%r{<div[^>]*class="[^"]*(?:entry-content|post-content|article-content|articleText)[^"]*"[^>]*>(.*)}m, 1]
      return nil unless body

      # `(.*)` on that second branch runs to the end of the DOCUMENT: a
      # <div class="entry-content"> has no closing marker a regex can
      # find, so the comment thread, the sidebar, the related-posts strip
      # and the footer all arrived as part of the post. On a blog with
      # comments that is more foreign text than the author's own.
      #
      # Cut at the first thing that announces the end of an article. Not
      # exact -- a regex cannot balance divs -- but every one of these
      # markers is text nobody wants inside a post, so cutting early on a
      # false match costs a paragraph where not cutting costs the page.
      body = body[0, body.index(BODY_END) || body.length] if body.match?(BODY_END)

      title = text_of(html[%r{<h1[^>]*>(.*?)</h1>}m, 1]) ||
              text_of(html[%r{<h2[^>]*>(.*?)</h2>}m, 1]) ||
              text_of(html[%r{<title[^>]*>(.*?)</title>}m, 1])
      stamp = html[/property="article:published_time"[^>]*content="([^"]+)"/, 1] ||
              html[/<time[^>]*datetime="([^"]+)"/, 1]
      date = begin
        stamp && Time.parse(stamp)
      rescue StandardError
        nil
      end
      { title: title, date: date, body: body }
    end

    def text_of(fragment)
      return nil if fragment.nil?

      clean = CGI.unescapeHTML(fragment.gsub(/<[^>]+>/, '')).gsub(/\s+/, ' ').strip
      clean.empty? ? nil : clean
    end

    def localize_images(blocks, media)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = block.dig('media', 0, 'url').to_s
        filename = url.start_with?('http') ? media.from_url(url) : nil
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end

    def host
      URI.parse(@url).host || @url
    rescue URI::InvalidURIError
      @url
    end

    # A Feed pointed at one capture, with every image URL rerouted
    # through the Archive: id_ returns the original bytes, and asking
    # for an image at the capture's own timestamp redirects to the
    # nearest copy the Archive holds.
    class SnapshotFeed < Feed
      def initialize(path, timestamp:, keep_permalinks: false)
        super(path, keep_permalinks: keep_permalinks)
        @timestamp = timestamp
      end

      private

      def absolute(url, base)
        resolved = super
        return resolved unless resolved&.start_with?('http://', 'https://')
        return resolved if resolved.include?('web.archive.org')

        "https://web.archive.org/web/#{@timestamp}id_/#{resolved}"
      end
    end

    def feed_candidates
      return [@url] if @url.match?(%r{(rss|atom|feed|\.xml)([/?#]|\z)}i)

      [@url] + FEED_PATHS.map { |path| "#{@url}/#{path}" }
    end

    # One CDX query per candidate; collapse=digest keeps only captures
    # whose CONTENT differs, which is exactly the set worth reading.
    # text/html rows are dropped unless the user pointed straight at a
    # feed -- a homepage has thousands of captures and none of them are
    # posts in machine-readable form (that is phase 2's job).
    def discover
      explicit = feed_candidates.size == 1
      feed_candidates.flat_map do |candidate|
        rows = cdx_rows(candidate)
        rows = rows.reject { |r| r[:mimetype] == 'text/html' } unless explicit
        sleep @delay
        rows
      end
    end

    # A busy Archive is waited out here, once, for everything that talks
    # to it -- CDX queries, feed captures, archived pages, images. A
    # rescue makes hundreds of these requests over hours, so the odds of
    # meeting a bad minute somewhere in there are close to one.
    def http_get(url, redirects_left = 5)
      attempt = 0
      begin
        attempt += 1
        request(url, redirects_left)
      rescue Busy, *TRANSIENT => e
        raise if attempt > RETRIES

        wait = RETRY_BACKOFF * attempt
        warn "  the Wayback Machine is busy (#{e.message.lines.first.to_s.strip[0, 60]}) -- " \
             "waiting #{wait}s, attempt #{attempt} of #{RETRIES}"
        sleep wait
        retry
      end
    end

    # The Archive is slow the way a library is slow -- CDX queries and
    # snapshot fetches routinely take longer than the 30 s budget
    # FeedHttp rightly enforces on living feeds. Patience here, not
    # there.
    def request(url, redirects_left)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: 30, read_timeout: 180) do |http|
        http.get(uri.request_uri, 'User-Agent' => 'blog.sh importer')
      end
      case response
      when Net::HTTPSuccess then response.body
      when Net::HTTPRedirection
        raise I18n.t('import.wayback_too_many_redirects', url: url) if redirects_left.zero?

        http_get(URI.join(url, response['location']).to_s, redirects_left - 1)
      when Net::HTTPServerError, Net::HTTPTooManyRequests
        raise Busy, I18n.t('import.wayback_http', code: response.code, url: url)
      else
        raise I18n.t('import.wayback_http', code: response.code, url: url)
      end
    end

    # A feed item that ends with a link BACK TO ITSELF is a teaser: that
    # last link is the "read more" the blog appended where it cut the post
    # off, and no number of captures recovers what the feed never sent.
    #
    # Structural on purpose. The obvious test -- look for "read more" --
    # only works in the language it was written in, and the tempting
    # shortcut of "no content:encoded" is wrong too: plenty of feeds carry
    # the whole post in plain description. Where the last link POINTS is
    # neither. Checked against a b2evolution feed whose items were mixed:
    # it named every truncated one and no other.
    def summary_only?(item)
      link = item_link(item)
      return false if link.empty?

      # All text children, same as Feed#text_of: `.text` alone returns the
      # first text node, and a newline before a CDATA section makes that
      # node whitespace -- the body would read as absent.
      body = %w[content:encoded description content summary]
             .filter_map { |name| item.elements[name]&.texts&.map(&:value)&.join }
             .max_by(&:length).to_s
      last = body.scan(%r{<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>}im).last
      return false if last.nil? || last[0].split('#').first != link

      # A trailing self-link is not always a teaser: some generators append
      # a "Permalink" footer to EVERY item, complete posts included -- one
      # such feed made this claim 20 truncations out of 20 full posts.
      # "Permalink" is the generator's word, not the blogger's, so the
      # literal match is not a language guess the way "read more" would be.
      !last[1].gsub(/<[^>]+>/, '').strip.match?(/\Apermalink\z/i)
    end

    # A teaser is what the FEED sent, not what the blog published -- and
    # the Archive very often kept the post's own page beside the feed.
    # The detection above did nothing with itself: the item was counted
    # into a summary line and the cut-off text written as the post, while
    # page mode -- which can read a whole page -- was only ever tried for
    # a blog with NO feed capture at all, never for a single item this
    # tool already knew was truncated.
    #
    # One CDX lookup for that one address, newest capture, read by the
    # same pack/generic_parse page mode uses. Title, date and tags stay
    # the FEED's: they are structured there and guessed on a page. Only
    # the body is replaced, and only when the page really says more than
    # the teaser did -- a page the Archive never kept, one no pack can
    # read, or one that parses to less is left alone and the post keeps
    # the teaser it had.
    #
    # Deliberately not windowed: WAYBACK_FROM/TO says which era of the
    # blog to rescue, and that question was already answered by the feed
    # capture this item came out of. What is wanted here is the best copy
    # of THIS post, whenever the crawler happened to take it.
    def full_body_blocks(item, post, media)
      link = item_link(item)
      return nil if link.empty?

      row = newest_page_capture(link)
      return nil unless row

      html = to_utf8(http_get("https://web.archive.org/web/#{row[:timestamp]}id_/#{row[:original]}"))
      sleep @delay
      parsed = @pack&.parse(html) || generic_parse(html)
      return nil if parsed.nil? || parsed[:body].to_s.strip.empty?

      page = { timestamp: row[:timestamp], original: row[:original], path: link }
      blocks = HtmlBlocks.parse(reroute_images(parsed[:body], page)).blocks
      # Measured BEFORE any picture is registered: media are numbered in
      # the order they are asked for, so registering a body that is then
      # thrown away would move every file in every post after it -- and a
      # re-import would find the old bytes under the new name.
      return nil unless text_length(blocks) > text_length(post['content'])

      localize_images(blocks, media)
    rescue StandardError
      # The teaser is a post; a failed rescue of it is not worth the run.
      nil
    end

    def newest_page_capture(url)
      rows = cdx_rows(url, extra: { 'filter' => %w[statuscode:200 mimetype:text/html] }, windowed: false)
      rows.max_by { |row| row[:timestamp] }
    end

    def text_length(blocks)
      Array(blocks).sum { |block| block['text'].to_s.length }
    end

    # A picture the teaser referenced and the full page does not: its
    # bytes were fetched and numbered while the teaser was the post, and
    # left behind they would sit in the archive with nothing pointing at
    # them.
    def drop_unused_media(old_blocks, new_blocks, media)
      kept = Array(new_blocks).flat_map { |b| Array(b['media']).map { |m| m['url'] } }.compact
      Array(old_blocks).each do |block|
        Array(block['media']).each do |entry|
          name = entry['url']
          media.discard(name) if name && !kept.include?(name)
        end
      end
    end

    def item_link(item)
      node = item.elements['link']
      return '' unless node

      text = node.text.to_s.strip
      text.empty? ? node.attributes['href'].to_s.strip : text
    end

    # What the Archive has of this blog's PICTURES. A feed only references
    # images; whether they arrive depends on whether the crawler ever
    # fetched them, and nothing in the feed says. One CDX query answers it
    # before the run instead of after -- a preview used to promise sixty
    # images for a blog whose pictures the Archive had never once visited.
    def probe_images
      asked = @cdx_failures.size
      rows = cdx_rows("#{host}/*", extra: { 'filter' => ['statuscode:200', 'mimetype:image/.*'],
                                            'collapse' => 'urlkey' }, windowed: false)
      # Unanswered is not empty -- say nothing rather than something wrong.
      return if @cdx_failures.size > asked

      @archived_images = { total: rows.size,
                           years: rows.map { |r| r[:timestamp].to_s[0, 4] }.tally.sort }
    end

    # A query the Archive never answered is not an empty archive, and the
    # difference is the whole message: one is "try again in a minute",
    # the other is "this blog is not in there".
    def refuse_unanswered
      abort("❌ The Wayback Machine did not answer #{@cdx_failures.size} of its queries, so what it " \
            "holds of #{host} is unknown.\n  #{@cdx_failures.last(3).join("\n  ")}\n" \
            '   It rate-limits long rescues. Wait a few minutes and run this again, or pass a larger ' \
            'WAYBACK_DELAY (seconds between queries) to keep under the limit.')
    end

    # "2013", "2013-01", "2013-01-15" -> the digits CDX wants. A typo is
    # worth stopping for rather than ignoring: a window silently dropped
    # would read as a blog the Archive never captured, which is the one
    # mistake this file has already made twice.
    def human_window
      [@from || '…', @to || '…'].join(' .. ')
    end

    def stamp(value, name)
      return nil if value.nil? || value.to_s.strip.empty?

      # The SHAPE, not the digit count. "2013-1-5" is an ordinary way to
      # write a date and its digits are "201315" -- six of them, even, so
      # it passed as a year-month window of month 15, which the Archive
      # reads as no captures at all. A window silently dropped reads as a
      # blog nobody ever captured, which is the mistake this file has
      # already made twice.
      text = value.to_s.strip
      unless text.match?(/\A\d{4}(-\d{2}(-\d{2}([ T]\d{2}(:\d{2}(:\d{2})?)?)?)?)?\z/) ||
             text.match?(/\A\d{4}(\d{2}){0,5}\z/)
        abort("❌ #{name} takes a year, year-month or date (2013, 2013-01, 2013-01-15) -- " \
              "got #{value.inspect}")
      end

      digits = text.gsub(/\D/, '')
      return digits if digits.length.between?(4, 14) && digits.length.even?

      abort("❌ #{name} takes a year, year-month or date (2013, 2013-01, 2013-01-15) -- " \
            "got #{value.inspect}")
    end

    # The window the Wayback Machine's own calendar offers, as CDX
    # parameters. It filters CAPTURES, not posts: a capture from August
    # holds whatever the feed carried that day. Reading late captures is
    # how you reach the end of a blog -- the alternative, reading newest
    # first, would break the rule that makes overlapping captures merge
    # correctly (oldest first, so the newest version of a post wins).
    def window
      { from: @from, to: @to }.compact
    end

    # CDX answers oldest first, which is what makes overlapping captures merge
    # correctly -- and what made a low limit lose the END of a blog rather than
    # its beginning. The feed query asked for 1000 and never looked at whether
    # it got exactly that many back, so a blog the Archive captured more often
    # than that came over as its first 1000 captures and nothing after: the
    # recent half simply missing, while the run reported "1000 feed capture(s)
    # read" as though that were all there was.
    #
    # 1000 was also the odd one out -- the media query in this same method has
    # always asked for 15_000. Both ask for that now, and a result that comes
    # back exactly full is reported rather than trusted, because that is the
    # one shape that means "there was more". The way past it is the window the
    # importer already offers: --from/--to, one span at a time.
    CDX_LIMIT = 15_000

    def cdx_rows(candidate, extra: nil, windowed: true)
      params = { url: candidate, output: 'json', limit: CDX_LIMIT,
                 filter: 'statuscode:200', collapse: 'digest' }
      params = params.merge(extra) if extra
      params = params.merge(window) if windowed
      query = URI.encode_www_form(params)
      body = http_get("#{CDX}?#{query}")
      # An empty body is CDX saying "nothing for that address", which is
      # an answer. JSON.parse raised on it, the rescue below filed it
      # under "the Archive did not answer", and a run whose every
      # candidate came back empty aborted with a network diagnosis --
      # so page mode, which is what such a site needs, was unreachable.
      return [] if body.to_s.strip.empty?

      rows = JSON.parse(body)
      header = rows.shift or return []
      ts = header.index('timestamp')
      original = header.index('original')
      mime = header.index('mimetype')
      @cdx_truncated << candidate if rows.length >= CDX_LIMIT
      rows.map { |r| { timestamp: r[ts], original: r[original], mimetype: r[mime] } }
    rescue StandardError => e
      # Still [], because one unanswered candidate among nine must not
      # end a rescue the other eight can finish -- but recorded, so a run
      # that found nothing can say which kind of nothing it found.
      @cdx_failures << "#{candidate} -- #{e.message.lines.first.to_s.strip[0, 100]}"
      []
    end

    # Fetched once, validated as an actual feed, handed to Feed as a
    # file -- so one mangled capture is a counted skip, not the abort a
    # non-feed source normally deserves.
    def snapshot_feed(capture)
      body = http_get("https://web.archive.org/web/#{capture[:timestamp]}id_/#{capture[:original]}")
      # Same as the feed adapter: rexml is a default gem, and a distro
      # that split it out of its Ruby package should hear what to install
      # rather than a backtrace from the middle of an import.
      begin
        require 'rexml/document'
      rescue LoadError
        abort('❌ This import needs rexml, which your Ruby install is missing -- `gem install rexml` ' \
              'or install your distribution\'s fuller Ruby package.')
      end
      root = REXML::Document.new(body).root&.expanded_name
      unless %w[rss feed].include?(root)
        @unreadable += 1
        return nil
      end

      # Registered for cleanup: Tempfile.create without a block is never
      # unlinked, and a rescue reads thousands of captures -- so a long run
      # left a temp file per capture behind it, on a disk it had just
      # filled with media.
      file = Tempfile.create(['wayback', '.xml'])
      @tempfiles << file.path
      file.write(body)
      file.close
      SnapshotFeed.new(file.path, timestamp: capture[:timestamp], keep_permalinks: @keep_permalinks)
    rescue Busy, *TRANSIENT
      # The Archive stopped answering for this one. Counted apart from a
      # capture that came back and was not a feed: calling a refused
      # connection "not a readable feed" once made a rescue report 81 of
      # 82 captures unreadable, when every one of them was a clean RSS
      # file the moment it was asked for on its own.
      @unanswered_captures += 1
      nil
    rescue StandardError
      @unreadable += 1
      nil
    end

    # --- platform packs -------------------------------------------------
    #
    # A pack teaches page mode one dead platform: which paths were posts
    # and how its markup spelled title, date and body. Built from real
    # archived pages, not documentation -- there is none left.
    #
    # A pack is picked three ways, in this order: by name
    # (WAYBACK_PACK=b2evolution) when the operator already knows what the
    # site ran; by host, for platforms that had one (blog.cz); and by
    # markup, sniffed from one archived page, for software that lived on
    # anyone's domain (see sniff_pack).

    # Shared by the packs: every platform's body div nests freely, and
    # counting div tags finds its true end, where any regex would stop at
    # the first nested close.
    module PackMarkup
      module_function

      def balanced_div(html, opening)
        # Comments are masked (same length, so every index still points
        # into the original) before counting: a commented-out unmatched
        # <div> -- an ad placeholder, a disabled widget, period-typical --
        # inflated the depth and made the whole page unparseable.
        masked = html.gsub(/<!--.*?-->/m) { |c| ' ' * c.length }
        m = masked.match(opening)
        return nil unless m

        index = m.end(0)
        depth = 1
        while depth.positive? && (nxt = masked.match(%r{<div\b|</div>}i, index))
          depth += nxt[0].start_with?('</') ? -1 : 1
          index = nxt.end(0)
        end
        return nil if depth.positive?

        html[m.end(0)...(index - '</div>'.length)]
      end
    end

    # blog.cz (†2020, once the biggest Czech blog platform). Verified
    # against real captures: posts live at /YYMM/slug, the article sits
    # in <div class="article"> with an <h2> title, a Czech long-form
    # date ("30. října 2011 v 18:25") and the body in
    # <div class="articleText">.
    module BlogCz
      MONTHS = %w[ledna února března dubna května června července srpna
                  září října listopadu prosince].freeze
      DATE = /(\d{1,2})\.\s*(#{MONTHS.join('|')})\s*(\d{4})(?:\s*v\s*(\d{1,2}):(\d{2}))?/

      module_function

      def key
        'blogcz'
      end

      def matches?(host)
        host.end_with?('.blog.cz')
      end

      def post_path?(path)
        path.match?(%r{\A/\d{4}/[a-z0-9][a-z0-9-]*\z})
      end

      def parse(html)
        article = html[/<div class="article[" ].*/m]
        return nil unless article

        title = article[%r{<h2[^>]*>(.*?)</h2>}m, 1]
        body = balanced_div(article, /<div class="articleText"[^>]*>/)
        return nil unless body

        date = nil
        if (m = article[0, 2000].match(DATE))
          date = Time.local(m[3].to_i, MONTHS.index(m[2]) + 1, m[1].to_i,
                            m[4].to_i, m[5].to_i)
        end
        { title: CGI.unescapeHTML(title.to_s.gsub(/<[^>]+>/, '')).strip,
          date: date, body: body }
      end

      def balanced_div(html, opening)
        PackMarkup.balanced_div(html, opening)
      end
    end

    # b2evolution -- self-hosted blog software, the workhorse of the
    # 2003-2010 blogosphere's first wave. No host shape to recognize
    # (every installation lived on its own domain), so this pack is
    # chosen by markup or by name, never by address.
    #
    # Verified against a real 2008 skin, not documentation: the body sits
    # in <div class="bText">, rendered by the stock _item_content.inc.php
    # template that skins practically never replaced -- which is what
    # makes this pack general. The title is <h3 class="bTitle"> (an <h2>
    # fallback for skins that used the request title); tags are links in
    # <div class="posttags"> behind a localized label ("Tags:",
    # "Značky:"); ads and search boxes sit OUTSIDE bText, so taking only
    # the balanced div excludes them by construction.
    #
    # The date is the skin's choice. The numeric form b2evolution shipped
    # is y/m/d with a TWO-DIGIT year ("08/12/07" is 2008-12-07 -- not
    # guessable from a rendered page, taken from the template source),
    # tried alongside the four-digit form; anything else falls back to
    # the capture timestamp, which map_page already counts out loud.
    module B2evolution
      DATE = %r{\b(\d{2}|\d{4})/(\d{1,2})/(\d{1,2})\b}

      module_function

      def key
        'b2evolution'
      end

      def matches?(_host)
        false
      end

      # What sniff_pack asks: does this rendered page carry b2evolution's
      # markup? The generator meta is definitive when present; the stock
      # content template's class is the fallback for skins that dropped
      # the meta.
      def detect?(html)
        html.match?(/<meta[^>]+content=["'][^"']*b2evolution/i) || html.include?('class="bText"')
      end

      # The date-form permalinks a stock install produced, with or
      # without the /index.php prefix. Query-string permalinks
      # (?p=123, ?title=slug) collapse to one path in the CDX index and
      # cannot be told apart here -- POST_PATTERN stays the escape hatch
      # for those installs.
      def post_path?(path)
        path.match?(%r{\A(?:/index\.php)?/\d{4}/\d{1,2}/\d{1,2}/[^/]+\z})
      end

      def parse(html)
        body = PackMarkup.balanced_div(html, /<div class="bText"[^>]*>/)
        return nil unless body

        title = html[%r{<h3 class="bTitle"[^>]*>(.*?)</h3>}m, 1] ||
                html[%r{<h2[^>]*>(.*?)</h2>}m, 1]

        date = nil
        if (m = html.match(%r{<div class="date[^"]*"[^>]*>(.*?)</div>}m))
          date = parse_date(m[1])
        end

        tags = []
        if (m = html.match(%r{<div class="posttags"[^>]*>(.*?)</div>}m))
          tags = m[1].scan(%r{<a[^>]*>(.*?)</a>}m).flatten
                     .map { |t| CGI.unescapeHTML(t.gsub(/<[^>]+>/, '')).strip }
                     .reject(&:empty?)
        end

        { title: CGI.unescapeHTML(title.to_s.gsub(/<[^>]+>/, '')).strip,
          date: date, body: body, tags: tags }
      end

      def parse_date(text)
        m = text.match(DATE)
        return nil unless m

        year = m[1].to_i
        # b2evolution predates 1970 by nothing: a two-digit year below 70
        # is this century, the rest were the platform's own lifetime.
        year += year < 70 ? 2000 : 1900 if year < 100
        month = m[2].to_i
        day = m[3].to_i
        return nil unless month.between?(1, 12) && day.between?(1, 31)

        Time.local(year, month, day)
      rescue ArgumentError
        nil
      end
    end

    PACKS = [BlogCz, B2evolution].freeze
  end
end
