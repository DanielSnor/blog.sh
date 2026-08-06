# frozen_string_literal: true

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
    FEED_PATHS = %w[rss feed atom.xml index.xml rss.xml feed/rss feeds/posts/default].freeze

    attr_accessor :keep_permalinks

    def initialize(url, delay: 1.0, keep_permalinks: false)
      @url = url.sub(%r{/+\z}, '')
      @delay = delay
      @keep_permalinks = keep_permalinks
      @snapshots_read = 0
      @unreadable = 0
      @lost_images = 0
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

    def each_item
      captures = discover
      abort("❌ The Wayback Machine has no feed captures for #{host} -- tried #{feed_candidates.join(', ')}.") if captures.empty?

      # Oldest first: overlapping captures then replay history in order,
      # and the newest version of a post is the one that sticks.
      captures.sort_by! { |c| c[:timestamp] }
      captures.each do |capture|
        feed = snapshot_feed(capture)
        next unless feed

        @snapshots_read += 1
        feed.each_item { |item| yield [feed, item] }
        sleep @delay
      end
    end

    def map(pair, media)
      feed, item = pair
      post = feed.map(item, media)
      return post unless post.is_a?(Hash)

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

    def postscript
      notes = ["#{@snapshots_read} feed capture(s) read from the Wayback Machine."]
      notes << "#{@unreadable} capture(s) were not readable feeds and were skipped." if @unreadable.positive?
      notes << "#{@lost_images} image(s) the Archive never saved are lost -- their posts came over without them." if @lost_images.positive?
      notes.join("\n  ")
    end

    private

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

    # The Archive is slow the way a library is slow -- CDX queries and
    # snapshot fetches routinely take longer than the 30 s budget
    # FeedHttp rightly enforces on living feeds. Patience here, not
    # there.
    def http_get(url, redirects_left = 5)
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
      else
        raise "HTTP #{response.code} (#{url})"
      end
    end

    def cdx_rows(candidate)
      query = URI.encode_www_form(url: candidate, output: 'json', limit: 1000,
                                  filter: 'statuscode:200', collapse: 'digest')
      body = http_get("#{CDX}?#{query}")
      rows = JSON.parse(body)
      header = rows.shift or return []
      ts = header.index('timestamp')
      original = header.index('original')
      mime = header.index('mimetype')
      rows.map { |r| { timestamp: r[ts], original: r[original], mimetype: r[mime] } }
    rescue StandardError
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
  end
end
