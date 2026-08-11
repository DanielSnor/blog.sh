# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a Ghost JSON export -- the file Ghost Admin's "Export your
  # content" produces (a database dump: every post, page, tag and their
  # joins in one JSON document). Post bodies are in `html`, which is the
  # rendered form of whatever editor wrote them, so one HtmlBlocks pass
  # covers every Ghost version that can produce the export.
  #
  # What the export does NOT carry is the media: images appear only as
  # "__GHOST_URL__/content/images/..." references. That placeholder is the
  # site's own address, which the export deliberately never spells out --
  # so the importer has to be told it, and downloads everything from the
  # live site. Import while the old site is still up; afterwards the
  # references would have nowhere to resolve.
  class Ghost
    # Same writer-not-option shape as Feed: the wizard asks about
    # permalinks after the adapter exists.
    attr_accessor :keep_permalinks

    def initialize(path, site_url:, keep_permalinks: false)
      @path = path
      @site_url = site_url.to_s.sub(%r{/+\z}, '')
      @keep_permalinks = keep_permalinks
      @scheduled = 0
    end

    def label
      "Ghost export (#{site_host})"
    end

    def preamble
      "Reading #{@path} (#{(File.size(@path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def platform_tag
      'ghost'
    end

    def each_item(&block)
      items = data['posts'] || []
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      # Pages are deliberately not posts: an about page or a contact page
      # in the middle of the archive would be timeline noise. The summary
      # counts them so nobody wonders where they went.
      return :page if item['type'] != 'post'

      html = item['html'].to_s.gsub('__GHOST_URL__', @site_url)
      blocks = leading_blocks(item, media) + body_blocks(html, media, item)
      return :empty if blocks.empty?

      state = item_state(item)
      post = {
        'slug' => Slug.slugify(item['slug'].to_s.empty? ? item['title'].to_s : item['slug']),
        'title' => item['title'],
        'date' => item_date(item).iso8601,
        'state' => state,
        'tags' => tags_for(item),
        'content' => blocks,
        'source' => {
          'platform' => 'ghost',
          'account' => site_host,
          'post_url' => post_url(item),
          'original_id' => item['id']
        }
      }
      if @keep_permalinks && state == 'published'
        path = Permalinks.local_path(post_url(item))
        post['redirect_from'] = [path] if path
      end
      post
    end

    def postscript
      return nil if @scheduled.zero?

      I18n.t('import.note.ghost_scheduled', count: @scheduled)
    end

    private

    def data
      @data ||= begin
        parsed = JSON.parse(File.read(@path, encoding: 'utf-8'))
        # Both shapes exist in the wild: a full export wraps the tables in
        # db[0].data, an importer-made file may carry data at the top.
        parsed.dig('db', 0, 'data') || parsed['data'] ||
          abort("#{@path} does not look like a Ghost export (no db[0].data)")
      end
    end

    def site_host
      URI.parse(@site_url).host || @site_url
    rescue URI::InvalidURIError
      @site_url
    end

    # Ghost's default permalink is /slug/ on the site root. A post with a
    # canonical_url on the SAME site knows better -- that is the address
    # the site actually answered at -- but a canonical pointing elsewhere
    # is a syndication note, not an address of ours.
    def post_url(item)
      canonical = item['canonical_url'].to_s
      if canonical.start_with?(@site_url) || canonical.start_with?('/')
        return canonical.start_with?('/') ? "#{@site_url}#{canonical}" : canonical
      end

      "#{@site_url}/#{item['slug']}/"
    end

    # A scheduled Ghost post arrives as a draft, not into the publish
    # queue: its time was a promise made to a different site, and silently
    # entering it into this one's cron would publish -- and announce --
    # posts nobody here reviewed. The postscript says how many wait.
    def item_state(item)
      case item['status']
      when 'published' then 'published'
      when 'scheduled'
        @scheduled += 1
        'draft'
      else 'draft'
      end
    end

    def item_date(item)
      Time.parse(item['published_at'] || item['created_at'])
    rescue StandardError
      Time.now
    end

    def tags_for(item)
      @tag_names ||= (data['tags'] || []).to_h { |t| [t['id'], t['name']] }
      @post_tags ||= (data['posts_tags'] || []).group_by { |pt| pt['post_id'] }
      (@post_tags[item['id']] || [])
        .sort_by { |pt| pt['sort_order'].to_i }
        .filter_map { |pt| @tag_names[pt['tag_id']] }
        # Ghost's internal tags (#hashtag-named) are routing config, not labels.
        .reject { |name| name.start_with?('#') }
    end

    # What Ghost renders above the body, in its order: the feature image,
    # then the excerpt -- imported as a first paragraph, since blog.sh has
    # no separate perex field and a lead paragraph is what it was.
    def leading_blocks(item, media)
      blocks = []
      feature = item['feature_image'].to_s.gsub('__GHOST_URL__', @site_url)
      blocks << { 'type' => 'image', 'media' => [{ 'url' => feature }] } unless feature.empty?
      excerpt = item['custom_excerpt'].to_s.strip
      blocks << { 'type' => 'text', 'text' => excerpt } unless excerpt.empty?
      localize_images(blocks, media, item)
    end

    def body_blocks(html, media, item)
      segments(html).flat_map do |kind, payload|
        case kind
        when :embed then [payload]
        else localize_images(HtmlBlocks.parse(payload).blocks, media, item)
        end
      end
    end

    # Ghost wraps every non-prose card in a <figure class="kg-card ...">.
    # Most of them (images, galleries, buttons, bookmarks) contain markup
    # HtmlBlocks already understands -- but an embed card is an iframe,
    # which HtmlBlocks rightly drops. So embed cards are lifted out before
    # parsing: YouTube becomes the same url+youtube_id video block a
    # hand-written post gets (the build makes the iframe, no foreign HTML
    # in the data), anything else becomes a link to the embedded page --
    # honest, visible, and it survives the platform dying.
    EMBED_CARD = %r{<figure[^>]*class="[^"]*kg-embed-card[^"]*"[^>]*>.*?</figure>}m
    IFRAME_SRC = /<iframe[^>]*\ssrc="([^"]+)"/m
    YOUTUBE_ID = %r{youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{6,})}

    def segments(html)
      parts = []
      last = 0
      html.scan(EMBED_CARD) do
        match = Regexp.last_match
        parts << [:html, html[last...match.begin(0)]]
        parts << embed_segment(match[0])
        last = match.end(0)
      end
      parts << [:html, html[last..]]
      parts.reject { |kind, payload| kind == :html && payload.to_s.strip.empty? }
    end

    def embed_segment(figure)
      src = figure[IFRAME_SRC, 1].to_s
      if (id = src[YOUTUBE_ID, 1])
        [:embed, { 'type' => 'video',
                   'url' => "https://www.youtube.com/watch?v=#{id}",
                   'youtube_id' => id }]
      elsif src.empty?
        # An embed card with no iframe (a bare script embed): nothing
        # portable to keep -- parse whatever text it holds.
        [:html, figure]
      else
        [:embed, { 'type' => 'text', 'text' => src,
                   'formatting' => [{ 'type' => 'link', 'url' => src,
                                      'start' => 0, 'end' => src.length }] }]
      end
    end

    # Same contract as Feed#localize_images: download, measure, or lose
    # the one image rather than the post.
    def localize_images(blocks, media, item)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = absolute(block.dig('media', 0, 'url'))
        filename = url && media.from_url(url)
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end

    def absolute(url)
      return nil if url.to_s.empty?
      return url if url.start_with?('http://', 'https://')
      return "https:#{url}" if url.start_with?('//')

      URI.join("#{@site_url}/", url).to_s
    rescue StandardError
      nil
    end
  end
end
