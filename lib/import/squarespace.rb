# frozen_string_literal: true

require 'cgi'
require_relative 'feed'

module Import
  # Imports a Squarespace export -- the "WordPress format" XML from
  # Settings → Import/Export. It is WXR in spirit and Feed reads it, but
  # every deviation matters and each one is handled here:
  #
  # The wxr_version marker WXR detection keys on may be missing; the slug
  # lives only in the <link>, which is a RELATIVE path (and "/null" on
  # drafts); a post's feature image is a separate attachment item sitting
  # right after it; and the body markup keeps its images' URLs in
  # data-src, its audio in a data-attributed div and its video as
  # HTML-escaped markup in an attribute -- all invisible to a straight
  # HTML parse, which would quietly lose every one of them.
  class Squarespace < Feed
    IMAGE_EXT = /\.(jpe?g|gif|png|svgz?|ico|webp)\z/i

    def label
      title = channel_title
      title.empty? ? 'Squarespace export' : "Squarespace (#{title})"
    end

    def platform_tag
      'squarespace'
    end

    def map(item, media)
      post = super
      return post unless post.is_a?(Hash)

      post['source']['platform'] = 'squarespace'
      # The export escapes the title TWICE ("&amp;amp;" for a plain "&"),
      # so what comes out of the XML is still HTML, while the body next to
      # it went through HtmlBlocks and had its entities decoded. One post
      # then said "Skillman &amp; Hackett" in the heading and "Skillman &
      # Hackett" in its own first sentence -- the template escapes on
      # output, so the reader saw the entity spelled out. Same decoder as
      # the body, so both agree on what the post is called.
      post['title'] = HtmlBlocks.decode_entities(post['title'].to_s)
      post['content'] = restore_media(post['content'], media)
      feature = feature_image_for(item, media)
      post['content'] = feature + post['content']
      return :empty if post['content'].empty?

      post
    end

    private

    # Squarespace exports have shipped without wp:wxr_version; the wp:
    # namespace on items is just as decisive, and without SOME marker the
    # whole file would be read as a plain feed -- every draft published,
    # every page imported.
    def wordpress?
      return @wordpress unless @wordpress.nil?

      @wordpress = super || !document.elements['rss/channel/item/wp:post_type'].nil?
    end

    # Answered before Feed decides the post is empty -- see Feed#map. A
    # photo post whose body parses to nothing, or one whose only block was
    # the newsletter form stripped in body_html, used to be refused as
    # :empty and its picture with it: map() adds the image, and map() only
    # runs on a post Feed did not already throw away. Nothing is fetched
    # here, so the media numbering is exactly what it was.
    def extra_leading?(item)
      !feature_attachment_url(item).nil?
    end

    # The export escapes titles twice, and the decode in map() happens on
    # the finished post -- too late for the slug, which is built from this.
    # A draft (whose <link> is "/null", so the title is all there is) was
    # filed under skillman-amp-hackett-draft while its own heading read
    # "Skillman & Hackett Draft", and that address is the one the author
    # publishes under later.
    def slug_title(item)
      HtmlBlocks.decode_entities(super)
    end

    # The <link> is a relative path; everything downstream (post_url,
    # redirect_from, image absolutizing) expects a full URL, and the
    # channel's own link is the base the export means.
    def item_link(item)
      raw = text_of(item, 'link')
      return raw if raw.empty? || raw.start_with?('http://', 'https://')

      URI.join(channel_link, raw).to_s
    rescue URI::InvalidURIError, ArgumentError
      raw
    end

    def channel_link
      text_of(document.elements['rss/channel'], 'link')
    end

    # No wp:post_name in these exports -- the link's last segment is the
    # slug the site actually published under. "/null" (drafts) folds to
    # nothing and falls through to the title fallback.
    def item_slug(item)
      slug = Slug.slugify(File.basename(URI.parse(item_link(item)).path.to_s, '.html'))
      slug.empty? || slug == 'null' ? super : slug
    rescue URI::InvalidURIError
      super
    end

    # The markup fixes, before HtmlBlocks sees any of it. Images: the URL
    # is in data-src, and the noscript fallback would double every one --
    # dropped wholesale, the primary copy survives via the data-src move.
    # Audio and video ride through the parse as sentinel paragraphs (the
    # payload CGI-escaped so no URL character can break the pattern) and
    # become native blocks in map(). Newsletter forms have nothing to say
    # in an archive.
    def body_html(item)
      html = super
      html = html.gsub(%r{<noscript>.*?</noscript>}m, '')
                 .gsub(/<img([^>]*?)\bdata-src=/, '<img\1src=')
                 .gsub(%r{<div[^>]*class="[^"]*newsletter-form-wrapper[^"]*"[^>]*>.*?</div>}m, '')
      html = html.gsub(%r{<div[^>]*class="[^"]*sqs-audio-embed[^"]*"[^>]*>}m) do |tag|
        url = tag[/data-url="([^"]+)"/, 1].to_s
        title = tag[/data-title="([^"]+)"/, 1].to_s
        url.empty? ? tag : "<p>@@sqs-audio:#{CGI.escape(url)}:#{CGI.escape(title)}@@</p><div>"
      end
      html.gsub(%r{<div[^>]*class="[^"]*sqs-video-wrapper[^"]*"[^>]*data-html="([^"]*)"[^>]*>}m) do
        embedded = CGI.unescapeHTML(Regexp.last_match(1))
        # The escaped markup quotes src either way -- providers differ.
        src = embedded[/<iframe[^>]*\ssrc=["']([^"']+)["']/, 1].to_s
        src.empty? ? '<div>' : "<p>@@sqs-video:#{CGI.escape(src)}@@</p><div>"
      end
    end

    def restore_media(blocks, media)
      blocks.filter_map do |block|
        text = block['type'] == 'text' ? block['text'].to_s : ''
        if (m = text.match(/\A@@sqs-audio:([^:@]*):([^@]*)@@\z/))
          filename = media.from_url(CGI.unescape(m[1]))
          next nil unless filename

          audio = { 'type' => 'audio', 'media' => [{ 'url' => filename }] }
          title = CGI.unescape(m[2])
          audio['caption'] = title unless title.empty?
          audio
        elsif (m = text.match(/\A@@sqs-video:([^@]*)@@\z/))
          video_block(CGI.unescape(m[1]))
        else
          block
        end
      end
    end

    # YouTube gets the url+youtube_id block hand-written posts have; any
    # other player becomes a link to what it embedded -- visible, honest,
    # and it survives the player dying.
    def video_block(src)
      if (id = src[%r{youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{6,})}, 1])
        { 'type' => 'video', 'url' => "https://www.youtube.com/watch?v=#{id}", 'youtube_id' => id }
      else
        { 'type' => 'text', 'text' => src,
          'formatting' => [{ 'type' => 'link', 'url' => src, 'start' => 0, 'end' => src.length }] }
      end
    end

    # The address of that attachment, or nil. Separate from the block it
    # becomes, because the emptiness test above needs the answer without
    # downloading anything.
    def feature_attachment_url(item)
      index = entries.index(item)
      neighbour = index && entries[index + 1]
      return nil unless neighbour && text_of(neighbour, 'wp:post_type') == 'attachment'

      url = text_of(neighbour, 'wp:attachment_url')
      url.match?(IMAGE_EXT) || url.include?('images.unsplash.com') ? url : nil
    end

    # The feature image is the NEXT item in the export -- an attachment
    # carrying wp:attachment_url -- which Feed would only ever count as
    # skipped. A lookahead turns it into the post's first image.
    def feature_image_for(item, media)
      url = feature_attachment_url(item)
      return [] unless url

      filename = media.from_url(url)
      return [] unless filename

      entry = { 'url' => filename }
      width, height = media.dimensions(filename)
      entry['width'] = width if width
      entry['height'] = height if height
      [{ 'type' => 'image', 'media' => [entry] }]
    end
  end
end
