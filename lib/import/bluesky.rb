# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative '../feed_http'
require_relative '../slug'

module Import
  # Imports an account's own Bluesky posts through the public AppView --
  # the same unauthenticated API the sidebar widget and the comment
  # threads already read, so an import needs no app password.
  #
  # Scope mirrors the Twitter importer, for the same reason: what belongs
  # in an archive is what you wrote standalone. Replies are excluded by
  # the server (filter=posts_no_replies), reposts and quote-posts here.
  # Note that self-threads go with the replies -- only a thread's opening
  # post survives, since every continuation is a reply to it.
  class Bluesky
    APPVIEW = 'https://public.api.bsky.app'
    PAGE_SIZE = 100

    def initialize(handle)
      @handle = handle.to_s.sub(/\A@/, '')
    end

    def label
      "Bluesky (@#{@handle})"
    end

    def each_item
      cursor = nil
      loop do
        page = fetch_page(cursor)
        items = page['feed'] || []
        break if items.empty?

        items.each { |item| yield item }

        cursor = page['cursor']
        break if cursor.to_s.empty?
      end
    end

    def map(item, media)
      return :repost if item['reason']

      post = item['post']
      record = post['record'] || {}
      embed = post['embed'] || {}
      return :quote if quote?(embed)

      text, formatting = build_text(record)
      blocks = []
      unless text.empty?
        block = { 'type' => 'text', 'text' => text }
        block['formatting'] = formatting unless formatting.empty?
        blocks << block
      end
      blocks.concat(embed_blocks(embed, media))
      return :empty if blocks.empty?

      rkey = post['uri'].to_s.split('/').last
      {
        'slug' => build_slug(text, rkey),
        'title' => nil,
        'date' => Time.parse(record['createdAt']).iso8601,
        'state' => 'published',
        'tags' => tags_from(record),
        'content' => blocks,
        'source' => {
          'platform' => 'bluesky',
          'account' => @handle,
          'post_url' => "https://bsky.app/profile/#{post.dig('author', 'handle') || @handle}/post/#{rkey}",
          'original_id' => rkey
        }
      }
    end

    private

    # Retried like Tumblr's fetch_page: an account over PAGE_SIZE posts
    # pages, and a single transient 5xx/429 from the AppView used to kill
    # the whole run mid-import -- the one adapter that pages over a public
    # API was also the one without a retry.
    def fetch_page(cursor, retries = 3)
      url = +"#{APPVIEW}/xrpc/app.bsky.feed.getAuthorFeed" \
             "?actor=#{URI.encode_www_form_component(@handle)}" \
             "&limit=#{PAGE_SIZE}&filter=posts_no_replies"
      url << "&cursor=#{URI.encode_www_form_component(cursor)}" if cursor
      JSON.parse(FeedHttp.get(url))
    rescue StandardError
      raise if retries.zero?

      sleep 1
      fetch_page(cursor, retries - 1)
    end

    def quote?(embed)
      type = embed['$type'].to_s
      type.start_with?('app.bsky.embed.record')
    end

    # Facet offsets are UTF-8 *byte* positions -- the AT Protocol's
    # contract, and the mirror image of the .bytesize arithmetic in
    # BlueskyPoster. The schema's formatting spans are Unicode codepoint
    # offsets, so every boundary has to be converted or every span after
    # the first non-ASCII character lands in the wrong place (which for
    # Czech text means essentially all of them).
    def build_text(record)
      text = record['text'].to_s
      formatting = []

      (record['facets'] || []).each do |facet|
        byte_start = facet.dig('index', 'byteStart')
        byte_end = facet.dig('index', 'byteEnd')
        next unless byte_start && byte_end

        span = { 'start' => codepoint_offset(text, byte_start),
                 'end' => codepoint_offset(text, byte_end) }
        next if span['start'] >= span['end']

        (facet['features'] || []).each do |feature|
          case feature['$type'].to_s
          when 'app.bsky.richtext.facet#link'
            formatting << span.merge('type' => 'link', 'url' => feature['uri'])
          when 'app.bsky.richtext.facet#mention'
            # The DID is stable but unreadable; the visible text is already
            # "@handle", so link it to the profile that handle resolves to.
            handle = text[span['start']...span['end']].to_s.sub(/\A@/, '')
            formatting << span.merge('type' => 'link', 'url' => "https://bsky.app/profile/#{handle}")
          end
          # #tag needs no span: the schema has no tag type, the "#word" is
          # already in the text, and tags_from puts it in the post's tags.
        end
      end

      [text, formatting]
    end

    def codepoint_offset(text, byte_offset)
      prefix = text.byteslice(0, byte_offset).to_s
      prefix.force_encoding(Encoding::UTF_8).scrub.length
    end

    # Both the facet tags and any trailing plain "#word" the author never
    # facetted, deduplicated case-insensitively the way a tag list should be.
    def tags_from(record)
      tags = (record['facets'] || []).flat_map do |facet|
        (facet['features'] || []).filter_map do |feature|
          feature['tag'] if feature['$type'].to_s == 'app.bsky.richtext.facet#tag'
        end
      end
      tags.uniq { |tag| tag.downcase }
    end

    def embed_blocks(embed, media)
      case embed['$type'].to_s
      when 'app.bsky.embed.images#view' then image_blocks(embed['images'], media)
      when 'app.bsky.embed.video#view' then video_blocks(embed, media)
      when 'app.bsky.embed.external#view' then external_blocks(embed['external'], media)
      else []
      end
    end

    def image_blocks(images, media)
      (images || []).filter_map do |image|
        filename = media.from_url(image['fullsize'])
        next unless filename

        { 'type' => 'image',
          'media' => [{ 'url' => filename,
                        'width' => image.dig('aspectRatio', 'width'),
                        'height' => image.dig('aspectRatio', 'height') }.compact],
          'alt_text' => (image['alt'] unless image['alt'].to_s.empty?) }.compact
      end
    end

    # Bluesky serves video as an HLS playlist (.m3u8 of segments), not as a
    # file that can be downloaded and played locally -- so what gets
    # imported is the poster frame plus, from `source.post_url`, a way back
    # to the original. Deliberately an image rather than a video block with
    # no media: a `video` carrying only a URL renders as "video
    # unavailable", which is a worse thing to leave in an archive than the
    # frame the author actually chose.
    def video_blocks(embed, media)
      filename = media.from_url(embed['thumbnail'])
      return [] unless filename

      [{ 'type' => 'image',
         'media' => [{ 'url' => filename,
                       'width' => embed.dig('aspectRatio', 'width'),
                       'height' => embed.dig('aspectRatio', 'height') }.compact],
         'alt_text' => (embed['alt'] unless embed['alt'].to_s.empty?) }.compact]
    end

    def external_blocks(external, media)
      return [] unless external && !external['uri'].to_s.empty?

      block = { 'type' => 'link', 'url' => external['uri'] }
      block['title'] = external['title'] unless external['title'].to_s.empty?
      block['description'] = external['description'] unless external['description'].to_s.empty?
      poster = media.from_url(external['thumb'])
      block['poster'] = [{ 'url' => poster }] if poster
      [block]
    end

    def build_slug(text, rkey)
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "bsky-#{rkey}" : slug
    end
  end
end
