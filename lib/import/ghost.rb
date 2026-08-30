# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'pages_note'
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
      @members = 0
      @page_paths = []
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
      # A page is imported AS a page rather than skipped. It was skipped
      # while the engine had nowhere to put one: an about or a contact page
      # dropped into the middle of the archive would have been timeline
      # noise. Now it keeps its address and stays out of the stream, which
      # is what it was on the old site too -- and a migration that silently
      # left the About page behind was the worst kind of loss, because the
      # site looked complete.
      is_page = item['type'] != 'post'

      html = item['html'].to_s.gsub('__GHOST_URL__', @site_url)
      blocks = leading_blocks(item, media) + body_blocks(html, media, item)
      return :empty if blocks.empty?

      state = item_state(item)
      tags = tags_for(item)
      # Ghost gates a members-only or paid post at serve time and ships
      # the WHOLE body in the export regardless. Written as published,
      # every word anybody paid for was on the open web the moment the
      # site was built -- with no tag, no count and no line in the run.
      # Both siblings protect them: beehiiv drafts a premium issue and
      # tags it, Substack tags a paid one. A draft is the reversible half
      # of that pair, so the person migrating decides post by post what
      # the public archive gets.
      if members_only?(item)
        @members += 1
        state = 'draft'
        tags += [MEMBERS_TAG] unless tags.include?(MEMBERS_TAG)
      end
      post = {
        'slug' => Slug.slugify(item['slug'].to_s.empty? ? item['title'].to_s : item['slug']),
        'title' => item['title'],
        'date' => item_date(item).iso8601,
        'state' => state,
        'tags' => tags,
        'content' => blocks,
        'source' => {
          'platform' => 'ghost',
          'account' => site_host,
          'post_url' => post_url(item),
          'original_id' => item['id']
        }
      }
      if is_page
        post['page'] = true
        # Only a page that is actually published answers at that address.
        # A Ghost draft arrives as a draft here too, so it lives under
        # /draft/<token>/ -- and the note this list feeds tells the reader
        # to put these addresses in `nav:`, where a draft's root path would
        # be a menu item leading to 404.
        @page_paths << "/#{post['slug']}/" if state == 'published'
      end
      if @keep_permalinks && state == 'published'
        path = Permalinks.local_path(post_url(item))
        # A page already lands at the root, so on Ghost -- where a page
        # lived at /about/ too -- the redirect would point the new address
        # at itself. The build warns about exactly that, once per build,
        # forever.
        post['redirect_from'] = [path] if path && !(is_page && path == "/#{post['slug']}/")
      end
      post
    end

    def postscript
      notes = []
      notes << I18n.t('import.note.ghost_scheduled', count: @scheduled) if @scheduled.positive?
      notes << I18n.t('import.note.ghost_members', count: @members) if @members.positive?
      notes.compact!
      notes.empty? ? nil : notes.join("\n  ")
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
    # Ghost's visibility column: public | members | paid | tiers. Anything
    # that is not public was gated, and an export written before the
    # column existed says nothing -- which is public, the way it was.
    MEMBERS_TAG = 'ghost-members'

    def members_only?(item)
      visibility = item['visibility'].to_s.strip.downcase
      !visibility.empty? && visibility != 'public'
    end

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
      unless feature.empty?
        block = { 'type' => 'image', 'media' => [{ 'url' => feature }] }
        # The caption and the alt text an editor typed under the feature
        # image live in the export's posts_meta table, which nothing here
        # ever opened -- 8 of the 118 posts in the export this was measured
        # against lost one. Body images kept theirs all along; the lead
        # photo arrived bare, and nothing said so.
        meta = post_meta(item)
        caption = caption_text(meta['feature_image_caption'])
        alt = meta['feature_image_alt'].to_s.strip
        block['caption'] = caption if caption
        block['alt_text'] = alt unless alt.empty?
        blocks << block
      end
      excerpt = item['custom_excerpt'].to_s.strip
      blocks << { 'type' => 'text', 'text' => excerpt } unless excerpt.empty?
      localize_images(blocks, media, item)
    end

    def post_meta(item)
      @posts_meta ||= (data['posts_meta'] || []).to_h { |row| [row['post_id'], row] }
      @posts_meta[item['id']] || {}
    end

    # Ghost writes the caption as HTML -- a <span>, often with a link in
    # it. The schema's caption is a plain string, so it is read the way
    # HtmlBlocks reads a <figcaption>: tags out, entities decoded.
    def caption_text(html)
      return nil if html.to_s.strip.empty?

      text = HtmlBlocks.parse("<p>#{html}</p>").blocks
                       .select { |block| block['type'] == 'text' }
                       .map { |block| block['text'].to_s }
                       .join(' ').strip
      text.empty? ? nil : text
    end

    def body_blocks(html, media, item)
      segments(html).flat_map do |kind, payload|
        case kind
        when :embed then [payload]
        when :video then video_blocks(payload, media)
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
    #
    # A video card is lifted for the opposite reason: HtmlBlocks understands
    # its markup all too well. Ghost writes the whole player into the export
    # -- two buttons, a seek slider and the spans holding the clock -- around
    # a <video> that HtmlBlocks drops, so an uploaded film left three
    # paragraphs of control panel behind ("0:00", "/0:15") and nothing said
    # the film was gone. The mp4 is a file like any picture in the post, so
    # it is downloaded and handed to the video block build_blog.rb already
    # draws a player for. The same promise the embed cards get: what was
    # uploaded outlives the platform it was uploaded to.
    CARD = %r{<figure[^>]*class="[^"]*kg-(embed|video)-card[^"]*"[^>]*>.*?</figure>}m
    IFRAME_SRC = /<iframe[^>]*\ssrc="([^"]+)"/m
    YOUTUBE_ID = %r{youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{6,})}
    VIDEO_TAG = /<video[^>]*>/
    FIGCAPTION = %r{<figcaption[^>]*>(.*?)</figcaption>}m

    def segments(html)
      parts = []
      last = 0
      html.scan(CARD) do
        match = Regexp.last_match
        parts << [:html, html[last...match.begin(0)]]
        parts << (match[1] == 'video' ? [:video, match[0]] : embed_segment(match[0]))
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

    # Nothing of the player survives except the file it was playing and the
    # caption underneath it. The dimensions come from the <video> element
    # rather than from the downloaded bytes: MediaDimensions reads image
    # headers, and an mp4 is not one.
    #
    # A file that could not be fetched costs the block, not the post --
    # Media has already recorded the address, so the summary names the loss
    # instead of the post quietly arriving without it.
    def video_blocks(figure, media)
      tag = figure[VIDEO_TAG].to_s
      src = tag[/\ssrc="([^"]*)"/, 1].to_s
      filename = src.empty? ? nil : media.from_url(absolute(src))
      return [] unless filename

      entry = { 'url' => filename }
      %w[width height].each do |dimension|
        value = tag[/\s#{dimension}="(\d+)"/, 1]
        entry[dimension] = value.to_i if value
      end
      block = { 'type' => 'video', 'media' => [entry] }
      caption = card_caption(figure)
      block['caption'] = caption unless caption.empty?
      [block]
    end

    # The caption is the one part of a card a person wrote, so it is read
    # the way prose is read -- entities and all -- rather than by stripping
    # angle brackets.
    def card_caption(figure)
      inner = figure[FIGCAPTION, 1]
      return '' unless inner

      HtmlBlocks.parse(inner).blocks
                .select { |block| block['type'] == 'text' }
                .map { |block| block['text'] }.join(' ').strip
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
