# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'tempfile'
require 'uri'
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
    # dropped or never completed. A refused DNS lookup or a bad
    # certificate is not going to fix itself in fifteen seconds.
    TRANSIENT = [Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout].freeze

    # Raised for a failure that may pass on its own, and caught by the
    # retry in http_get. Anything else stays what it was.
    Busy = Class.new(StandardError)

    attr_accessor :keep_permalinks

    # post_pattern is a regex string for page mode: which archived PATHS
    # are posts (as opposed to listings, tag pages, calendars). A
    # platform pack supplies it for hosts it knows; anywhere else the
    # user does, or page mode refuses with samples to build one from.
    def initialize(url, delay: 1.0, post_pattern: nil, mode: :auto, keep_permalinks: false)
      @url = url.sub(%r{/+\z}, '')
      @delay = delay
      @post_pattern = post_pattern && Regexp.new(post_pattern)
      @mode = mode
      @keep_permalinks = keep_permalinks
      @snapshots_read = 0
      @unreadable = 0
      @lost_images = 0
      @unparsed = 0
      @dated_by_capture = 0
      @summary_only = 0
      @full_bodied = 0
      @archived_images = nil
      # Queries the Archive never answered. Kept apart from queries that
      # came back empty, because only the second kind says anything about
      # the blog -- see refuse_unanswered.
      @cdx_failures = []
      @pack = PACKS.find { |p| p.matches?(host) }
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
      notes << "#{@snapshots_read} feed capture(s) read from the Wayback Machine." if @snapshots_read.positive?
      notes << "#{@unreadable} capture(s) were not readable feeds and were skipped." if @unreadable.positive?
      notes << "#{@unparsed} archived page(s) could not be read as posts -- see the skip counts." if @unparsed.positive?
      notes << "#{@dated_by_capture} post(s) carry the capture date -- the page itself said nothing better." if @dated_by_capture.positive?
      notes << "#{@lost_images} image(s) the Archive never saved are lost -- their posts came over without them." if @lost_images.positive?
      # The two things that decide whether a rescue is worth the hours it
      # takes, and neither is visible from the post count alone.
      if @summary_only.positive?
        seen = @summary_only + @full_bodied
        notes << "#{@summary_only} of #{seen} feed item(s) carried a summary, not the whole post -- " \
                 'that blog published excerpts, so those arrive truncated however many captures exist.'
      end
      if @archived_images && @archived_images[:total].zero?
        notes << "The Archive holds no images at all for #{host}: every picture these posts point at is gone."
      elsif @archived_images
        spread = @archived_images[:years].first(12).map { |year, n| "#{year}: #{n}" }.join(', ')
        notes << "The Archive holds #{@archived_images[:total]} image(s) of #{host} (#{spread}) -- " \
                 'pictures from years missing there cannot arrive, whatever the posts reference.'
      end
      # A run that finished still needs to say which questions went
      # unanswered: a feed candidate the Archive refused is a piece of the
      # blog that silently did not come over.
      if @cdx_failures.any?
        notes << "#{@cdx_failures.size} Archive #{@cdx_failures.size == 1 ? 'query' : 'queries'} went " \
                 'unanswered even after retrying -- anything they held is missing from this run. ' \
                 'Re-running is safe and picks it up.'
      end
      notes.empty? ? nil : notes.join("\n  ")
    end

    private

    def map_feed_item(feed, item, media)
      post = feed.map(item, media)
      return post unless post.is_a?(Hash)

      summary_only?(item) ? @summary_only += 1 : @full_bodied += 1

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
        date = Time.strptime(page[:timestamp], '%Y%m%d%H%M%S')
      end

      slug = Slug.slugify(File.basename(page[:path]))
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
      return utf8 if utf8.valid_encoding? && (declared.nil? || declared.match?(/\Autf-?8\z/i))

      source = declared && !declared.match?(/\Autf-?8\z/i) ? declared : 'windows-1250'
      raw.dup.force_encoding(source).encode('UTF-8', invalid: :replace, undef: :replace)
    rescue StandardError
      raw.dup.force_encoding('ISO-8859-1').encode('UTF-8', invalid: :replace, undef: :replace)
    end

    # Every image goes back through the time machine: absolutized
    # against the original host, then asked of the Archive at this
    # page's own moment -- it redirects to the nearest copy it holds.
    def reroute_images(body, page)
      body.gsub(/(<img[^>]*\ssrc=")([^"]+)(")/i) do
        prefix, src, suffix = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
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
    def generic_parse(html)
      body = html[%r{<article[^>]*>(.*?)</article>}m, 1] ||
             html[%r{<div[^>]*class="[^"]*(?:entry-content|post-content|article-content|articleText)[^"]*"[^>]*>(.*)}m, 1]
      return nil unless body

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
        raise "too many redirects (#{url})" if redirects_left.zero?

        http_get(URI.join(url, response['location']).to_s, redirects_left - 1)
      when Net::HTTPServerError, Net::HTTPTooManyRequests
        raise Busy, "HTTP #{response.code} (#{url})"
      else
        raise "HTTP #{response.code} (#{url})"
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

      body = %w[content:encoded description content summary]
             .filter_map { |name| item.elements[name]&.text }.max_by(&:length).to_s
      last = body.scan(/<a[^>]+href="([^"]+)"/im).last
      !last.nil? && last[0].split('#').first == link
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
                                            'collapse' => 'urlkey' })
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

    def cdx_rows(candidate, extra: nil)
      params = { url: candidate, output: 'json', limit: 1000,
                 filter: 'statuscode:200', collapse: 'digest' }
      params = params.merge(limit: 15_000).merge(extra) if extra
      query = URI.encode_www_form(params)
      body = http_get("#{CDX}?#{query}")
      rows = JSON.parse(body)
      header = rows.shift or return []
      ts = header.index('timestamp')
      original = header.index('original')
      mime = header.index('mimetype')
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
      require 'rexml/document'
      root = REXML::Document.new(body).root&.expanded_name
      unless %w[rss feed].include?(root)
        @unreadable += 1
        return nil
      end

      file = Tempfile.create(['wayback', '.xml'])
      file.write(body)
      file.close
      SnapshotFeed.new(file.path, timestamp: capture[:timestamp], keep_permalinks: @keep_permalinks)
    rescue StandardError
      @unreadable += 1
      nil
    end

    # --- platform packs -------------------------------------------------
    #
    # A pack teaches page mode one dead platform: which paths were posts
    # and how its markup spelled title, date and body. Built from real
    # archived pages, not documentation -- there is none left.

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

      # The body div nests freely; counting div tags finds its true end,
      # where any regex would stop at the first nested close.
      def balanced_div(html, opening)
        m = html.match(opening)
        return nil unless m

        index = m.end(0)
        depth = 1
        while depth.positive? && (nxt = html.match(%r{<div\b|</div>}i, index))
          depth += nxt[0].start_with?('</') ? -1 : 1
          index = nxt.end(0)
        end
        return nil if depth.positive?

        html[m.end(0)...(index - '</div>'.length)]
      end
    end

    PACKS = [BlogCz].freeze
  end
end
