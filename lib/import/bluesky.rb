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

    # The members of app.bsky.embed.record#view's union that are NOT a
    # quoted post. A post carrying one of these is the author writing
    # about something they made or recommend, with nobody else's words in
    # it -- see quote?.
    SHARED_RECORDS = %w[
      app.bsky.feed.defs#generatorView
      app.bsky.graph.defs#listView
      app.bsky.labeler.defs#labelerView
      app.bsky.graph.defs#starterPackViewBasic
    ].freeze

    # Where those four live on the web, keyed by the collection segment of
    # their at:// URI. A labeler has no page of its own -- its URI ends in
    # app.bsky.labeler.service/self -- so it points at the profile running
    # it. Handles and DIDs both resolve in these paths, which is why the
    # DID from the URI is a usable fallback when the view carries no
    # creator.
    SHARED_PATHS = {
      'app.bsky.feed.generator' => 'profile/%<handle>s/feed/%<rkey>s',
      'app.bsky.graph.list' => 'profile/%<handle>s/lists/%<rkey>s',
      'app.bsky.graph.starterpack' => 'starter-pack/%<handle>s/%<rkey>s',
      'app.bsky.labeler.service' => 'profile/%<handle>s'
    }.freeze

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

    # A record embed is not only a quoted post: the same embed shares a
    # feed generator, a list, a labeler or a starter pack (the lexicon's
    # union says so, and 4 of the 100 posts on @bsky.app's own timeline
    # are exactly that -- 5 of 29 on @skyfeed.xyz's). Those used to be
    # skipped as :quote, which threw the author's own text away under a
    # reason that was not even true. Anything else stays a quote,
    # including a record embed we cannot identify: an unrecognised record
    # is far likelier to be somebody else's post than a fifth kind of
    # thing, so the old default is the safe one.
    def quote?(embed)
      return false unless embed['$type'].to_s.start_with?('app.bsky.embed.record')

      shared_record(embed).nil?
    end

    # The shared feed/list/labeler/starter pack inside a record embed, or
    # nil when the embed holds a quoted post. recordWithMedia nests one
    # level deeper -- its `record` is a whole record#view. Unwrapped by
    # the OUTER type rather than by looking for a nested `record` key,
    # because the views themselves have one too (starterPackViewBasic
    # carries the raw starter pack record under exactly that name).
    def shared_record(embed)
      record = if embed['$type'].to_s == 'app.bsky.embed.recordWithMedia#view'
                 embed.dig('record', 'record')
               else
                 embed['record']
               end
      return nil unless record.is_a?(Hash) && SHARED_RECORDS.include?(record['$type'].to_s)

      record
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

    # A post keeps its hashtags in two places, and only one of them is the
    # facets: app.bsky.feed.post also has a `tags` array, which the lexicon
    # describes as "additional hashtags, in addition to any included in
    # post text and facets". Clients fill it for tags the author did not
    # write into the text at all -- at://did:plc:gq4fo3u6tqzzdkjlwzpb23tj/
    # app.bsky.feed.post/3mqukh4pq6s2k carries tags ["anisota"] with no
    # facet and no "#" anywhere in its text -- so reading the facets alone
    # dropped those posts' whole classification on the floor. Merged and
    # deduplicated case-insensitively the way a tag list should be, since
    # the same tag may well arrive from both sides.
    def tags_from(record)
      facet_tags = (record['facets'] || []).flat_map do |facet|
        (facet['features'] || []).filter_map do |feature|
          feature['tag'] if feature['$type'].to_s == 'app.bsky.richtext.facet#tag'
        end
      end
      # The tags array is written by clients, not by the engine that
      # builds facets, so what arrives is whatever an author typed: a
      # leading "#" they kept out of habit, or the padding left behind by
      # a text field. Both spellings mean the same tag, and left as they
      # came they would make two.
      (facet_tags + Array(record['tags']))
        .map { |tag| tag.to_s.strip.sub(/\A#+/, '') }
        .reject(&:empty?)
        .uniq { |tag| tag.downcase }
    end

    def embed_blocks(embed, media)
      case embed['$type'].to_s
      when 'app.bsky.embed.images#view' then image_blocks(embed['images'], media)
      # The carousel embed that arrived with the 10-photos-per-post
      # change. It is a separate lexicon, not a longer images#view, and it
      # keeps its pictures under `items` -- so it fell through to the
      # empty default and every photo vanished without even a media
      # failure to show for it. #viewImage carries the same fullsize/alt/
      # aspectRatio fields as an images#view image, hence no new mapper.
      when 'app.bsky.embed.gallery#view' then image_blocks(embed['items'], media)
      when 'app.bsky.embed.video#view' then video_blocks(embed, media)
      when 'app.bsky.embed.external#view' then external_blocks(embed['external'], media)
      when 'app.bsky.embed.record#view' then shared_blocks(embed)
      when 'app.bsky.embed.recordWithMedia#view'
        shared_blocks(embed) + embed_blocks(embed['media'] || {}, media)
      else []
      end
    end

    # What a shared feed, list, labeler or starter pack becomes: a link
    # block, the same shape an external embed gets, so the archive records
    # WHAT was shared and still points at it. Not optional decoration --
    # without it a post that shared a feed and wrote no text of its own
    # would carry no blocks at all and disappear as :empty, which is the
    # loss quote? was just fixed to prevent. Nothing is downloaded: the
    # only picture on offer is the maker's avatar, which is not this
    # post's content.
    def shared_blocks(embed)
      record = shared_record(embed)
      return [] unless record

      url = shared_url(record)
      return [] unless url

      block = { 'type' => 'link', 'url' => url }
      title = record['displayName'] || record['name'] ||
              record.dig('record', 'name') || record.dig('creator', 'displayName')
      description = record['description'] || record.dig('record', 'description') ||
                    record.dig('creator', 'description')
      block['title'] = title unless title.to_s.empty?
      block['description'] = description unless description.to_s.empty?
      [block]
    end

    def shared_url(record)
      # at://{authority}/{collection}/{rkey}
      parts = record['uri'].to_s.split('/')
      pattern = SHARED_PATHS[parts[3].to_s]
      rkey = parts[4].to_s
      return nil if pattern.nil? || (rkey.empty? && pattern.include?('rkey'))

      handle = record.dig('creator', 'handle').to_s
      handle = parts[2].to_s if handle.empty?
      return nil if handle.empty?

      "https://bsky.app/#{format(pattern, handle: handle, rkey: rkey)}"
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
