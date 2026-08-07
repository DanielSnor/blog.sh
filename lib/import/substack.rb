# frozen_string_literal: true

require 'csv'
require 'cgi'
require 'json'
require 'time'
require 'uri'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a Substack export -- the unpacked ZIP from Settings → Exports,
  # which is posts.csv (metadata) plus posts/<id>.<slug>.html (bodies as
  # web HTML). The export is the author's, so it carries the FULL text of
  # paid posts too; they import like any other, with the paywall marker
  # removed.
  #
  # Two things the export honestly does not have: tags (Substack keeps
  # them only on the live site) and, occasionally, the HTML of the newest
  # posts -- those are skipped and counted rather than imported empty.
  class Substack
    attr_accessor :keep_permalinks

    def initialize(dir, site_url: nil, keep_permalinks: false)
      @dir = dir
      @site_url = site_url.to_s.sub(%r{/+\z}, '')
      @keep_permalinks = keep_permalinks
    end

    def label
      "Substack export (#{account})"
    end

    def preamble
      "Reading #{File.join(@dir, 'posts.csv')}…"
    end

    def total
      @total
    end

    def platform_tag
      'substack'
    end

    def each_item(&block)
      rows = CSV.read(File.join(@dir, 'posts.csv'), headers: true)
      # Oldest first, numeric id as the tiebreaker -- the export's own
      # order is not guaranteed, and imported slugs collide less
      # confusingly when the earlier post got there first.
      items = rows.sort_by { |r| [r['post_date'].to_s, numeric_id(r)] }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      case item['type']
      when 'thread' then return :thread
      when 'page' then return :page
      end

      html_path = File.join(@dir, 'posts', "#{item['post_id']}.html")
      # Substack sometimes exports the newest posts as CSV rows with no
      # HTML file at all -- an empty post would look imported and be
      # nothing, so the honest move is a counted skip.
      return :missing_html unless File.exist?(html_path)

      html = preprocess(File.read(html_path, encoding: 'utf-8'))
      parsed = HtmlBlocks.parse(html)
      blocks = leading_blocks(item, media) +
               localize_images(parsed.blocks, media)
      return :empty if blocks.empty?

      state = item['is_published'].to_s.casecmp('true').zero? ? 'published' : 'draft'
      # A row without a date -- most plausibly a never-published draft --
      # used to TypeError out of the whole item and count as a nameless
      # :error. The send timestamp stands in when there is one; a post
      # with neither is skipped under a name the summary can print.
      raw_date = [item['post_date'], item['email_sent_at']].find { |v| !v.to_s.strip.empty? }
      return :undated unless raw_date

      slug = slug_of(item)
      post = {
        'slug' => slug,
        'title' => item['title'].to_s.empty? ? slug : CGI.unescapeHTML(item['title'].to_s),
        'date' => Time.parse(raw_date).iso8601,
        'state' => state,
        'tags' => [],
        'content' => blocks,
        'source' => {
          'platform' => 'substack',
          'account' => account,
          'post_url' => @site_url.empty? ? nil : "#{@site_url}/p/#{slug}",
          'original_id' => numeric_id(item)
        }.compact
      }
      post['redirect_from'] = ["/p/#{slug}"] if @keep_permalinks && state == 'published'
      post
    end

    private

    # post_id is "<numeric id>.<slug>" -- both halves are useful: the
    # number is the stable identity re-imports match on, the rest is the
    # public slug and the /p/<slug> path in one.
    def slug_of(item)
      Slug.slugify(item['post_id'].to_s.sub(/\A\d+\./, ''))
    end

    def numeric_id(item)
      item['post_id'].to_s[/\A\d+/].to_i
    end

    def account
      return URI.parse(@site_url).host || @site_url unless @site_url.empty?

      File.basename(File.expand_path(@dir))
    rescue URI::InvalidURIError
      @site_url
    end

    # What Substack shows above the body: the podcast player (for podcast
    # posts, the mp3 is right in the CSV), then the subtitle -- imported
    # as a first paragraph, blog.sh having no separate perex field.
    # Subtitles arrive with HTML entities baked in and need decoding.
    def leading_blocks(item, media)
      blocks = []
      podcast = item['podcast_url'].to_s
      unless podcast.empty?
        filename = media.from_url(podcast)
        blocks << { 'type' => 'audio', 'media' => [{ 'url' => filename }] } if filename
      end
      subtitle = CGI.unescapeHTML(item['subtitle'].to_s).strip
      blocks << { 'type' => 'text', 'text' => subtitle } unless subtitle.empty?
      blocks
    end

    # The parts of Substack's web markup that must not survive into an
    # archive: the paywall marker (the full text follows it -- the export
    # is the author's), subscribe/share/comment furniture, widgets that
    # only worked on Substack, and comment threads. Removed BEFORE
    # HtmlBlocks so none of it can leak through as stray text.
    STRIP = [
      %r{<div[^>]*class="[^"]*paywall-jump[^"]*"[^>]*>.*?</div>}m,
      %r{<div[^>]*class="[^"]*subscription-widget-wrap[^"]*"[^>]*>.*?</div>}m,
      %r{<p[^>]*class="[^"]*button-wrapper[^"]*"[^>]*>.*?</p>}m,
      %r{<div[^>]*class="[^"]*poll-embed[^"]*"[^>]*>.*?</div>}m,
      %r{<div[^>]*class="[^"]*native-video-embed[^"]*"[^>]*>.*?</div>}m,
      %r{<div[^>]*class="[^"]*comment\b[^"]*"[^>]*>.*?</div>}m
    ].freeze

    # An embedded/digest post card carries its target in a data-attrs JSON
    # attribute (sometimes entity-encoded twice); the durable part is the
    # link, so that is what it becomes.
    CARD = %r{<div[^>]*class="[^"]*(?:digest-post-embed|embedded-post-wrap)[^"]*"[^>]*data-attrs="([^"]*)"[^>]*>.*?</div>}m

    def preprocess(html)
      html = STRIP.reduce(html) { |acc, re| acc.gsub(re, '') }
      html = html.gsub(CARD) do
        attrs = decode_attrs(Regexp.last_match(1))
        url = attrs['canonical_url'].to_s
        title = attrs['title'].to_s
        url.empty? ? '' : %(<p><a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(title.empty? ? url : title)}</a></p>)
      end
      rewrite_cdn(html)
    end

    def decode_attrs(raw)
      once = CGI.unescapeHTML(raw)
      JSON.parse(once)
    rescue JSON::ParserError
      begin
        JSON.parse(CGI.unescapeHTML(once))
      rescue JSON::ParserError
        {}
      end
    end

    # Substack serves every image through a resizing CDN wrapper whose
    # last path segment is the URL-encoded original -- unwrap it and the
    # full-size file downloads from the source. The old bucketeer S3
    # bucket is dead; its files moved to substack-post-media wholesale.
    FETCH_URL = %r{https://substackcdn\.com/image/fetch/[^"'\s)]*?/(https?%3A[^"'\s)]+)}

    def rewrite_cdn(html)
      html.gsub(FETCH_URL) { CGI.unescape(Regexp.last_match(1)) }
          .gsub('https://bucketeer-e05bbc84-baa3-437e-9518-adb32be77984.s3.amazonaws.com',
                'https://substack-post-media.s3.amazonaws.com')
    end

    # Same contract as the other importers: download, measure, or lose the
    # one image rather than the post.
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
  end
end
