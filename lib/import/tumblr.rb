# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'permalinks'

module Import
  # Imports a Tumblr blog through the API in NPF format. Every post on the
  # blog is taken -- drafts included, kept as drafts -- since unlike the
  # social-network adapters there's no reply/repost distinction to make.
  #
  # All media is downloaded, so nothing stays hotlinked to Tumblr's CDN and
  # an import of a few thousand posts runs for hours.
  class Tumblr
    PAGE_SIZE = 20

    # Same writer-not-option shape as Feed, for the same reason: the
    # wizard asks about permalinks after the adapter exists.
    attr_accessor :keep_permalinks

    def initialize(blog, api_key:, keep_permalinks: false)
      @blog = blog
      @api_key = api_key
      @account = blog.split('.').first
      @keep_permalinks = keep_permalinks
      @unmapped_permalinks = 0
    end

    def label
      "Tumblr (#{@blog})"
    end

    # Known only once the first page comes back, which is why this is read
    # after iteration starts rather than up front.
    def total
      @total
    end

    def each_item
      offset = 0
      loop do
        data = fetch_page(offset)
        posts = data.dig('response', 'posts') || []
        @total ||= data.dig('response', 'blog', 'total_posts')
        break if posts.empty?

        posts.each { |post| yield post }

        offset += posts.size
        break if @total && offset >= @total
      end
    end

    def map(item, media)
      blocks = (item['content'] || []).filter_map { |b| map_block(b, media) }

      # A reblog carries its own content in `trail`. Since every post being
      # imported is the account's own, that content is simply appended -- no
      # separate attribution is kept.
      (item['trail'] || []).each do |entry|
        (entry['content'] || []).each do |b|
          mapped = map_block(b, media)
          blocks << mapped if mapped
        end
      end

      title, blocks = extract_title(blocks)
      return :empty if blocks.empty? && title.nil?

      state = item['state'] == 'published' ? 'published' : 'draft'
      post = {
        'slug' => build_slug(item),
        'title' => title,
        'date' => Time.parse(item['date']).iso8601,
        'state' => state,
        'tags' => item['tags'] || [],
        'content' => blocks,
        'source' => {
          'platform' => 'tumblr',
          'account' => @account,
          'post_url' => item['post_url'],
          'original_id' => item['id']
        }
      }
      # post_url carries whatever domain the blog answers at -- the custom
      # domain if it has one, which is the only case the wizard says yes in.
      if @keep_permalinks && state == 'published'
        path = Permalinks.local_path(item['post_url'])
        path ? post['redirect_from'] = [path] : @unmapped_permalinks += 1
      end
      post
    end

    def postscript
      return nil if @unmapped_permalinks.zero?

      I18n.t('import.note.tumblr_unmapped', count: @unmapped_permalinks)
    end

    private

    def fetch_page(offset, retries = 3)
      uri = URI("https://api.tumblr.com/v2/blog/#{@blog}/posts")
      uri.query = URI.encode_www_form(api_key: @api_key, npf: true, limit: PAGE_SIZE, offset: offset)
      data = JSON.parse(Net::HTTP.get(uri))

      # A rejected key or a misspelled blog still returns valid JSON, with the
      # reason in `meta` and an empty Array where `response` would be an
      # object. Without this the first thing a new user sees is a TypeError
      # from Hash#dig several frames away from the actual problem.
      status = data.dig('meta', 'status')
      unless status.nil? || status == 200
        abort("❌ Tumblr API returned #{status} #{data.dig('meta', 'msg')} for #{@blog} -- check the API key and the blog name.")
      end

      data
    rescue StandardError
      raise if retries.zero?

      sleep 1
      fetch_page(offset, retries - 1)
    end

    # Tumblr's own first-class title is a leading heading1 block, so it's
    # lifted out of the content rather than duplicated in it.
    def extract_title(blocks)
      first = blocks.first
      return [nil, blocks] unless first && first['type'] == 'text' && first['subtype'] == 'heading1'

      [first['text'], blocks[1..]]
    end

    def map_block(block, media)
      case block['type']
      when 'text' then text_block(block)
      when 'image' then image_block(block, media)
      when 'video' then video_block(block, media)
      when 'audio' then audio_block(block, media)
      when 'link' then link_block(block, media)
      end
    end

    def text_block(block)
      out = { 'type' => 'text', 'text' => block['text'] }
      out['subtype'] = block['subtype'] if block['subtype']
      out['formatting'] = block['formatting'] if block['formatting'] && !block['formatting'].empty?
      out
    end

    def image_block(block, media)
      largest = (block['media'] || []).max_by { |m| m['width'].to_i }
      filename = largest && media.from_url(largest['url'])
      {
        'type' => 'image',
        'media' => [{ 'url' => filename, 'width' => largest && largest['width'], 'height' => largest && largest['height'] }],
        'alt_text' => block['alt_text'],
        'caption' => block['caption']
      }.compact
    end

    def video_block(block, media)
      poster = (block['poster'] || []).first
      poster_filename = poster && media.from_url(poster['url'])

      # Self-hosted videos (provider "tumblr") carry a direct downloadable
      # file in `media`; YouTube/Instagram-style embeds don't -- they only
      # ever give an oEmbed iframe/blockquote, which stays external.
      item = block['media']
      media_filename = item && media.from_url(item['url'])

      {
        'type' => 'video',
        'provider' => block['provider'],
        'url' => block['url'],
        'embed_html' => embed_html_for(block),
        'media' => media_filename ? [{ 'url' => media_filename, 'width' => item['width'], 'height' => item['height'] }] : nil,
        'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
      }.compact
    end

    # Self-hosted audio carries a downloadable file; SoundCloud/Spotify-style
    # embeds only ever hand over an iframe, which stays external -- same
    # split as video. Title and artist become the caption, since that's
    # what a music post shows.
    def audio_block(block, media)
      item = block['media']
      media_filename = item && media.from_url(item['url'])
      caption = [block['title'], block['artist']].compact.reject(&:empty?).join(' — ')

      {
        'type' => 'audio',
        'provider' => block['provider'],
        'url' => block['url'],
        'embed_html' => embed_html_for(block),
        'media' => media_filename ? [{ 'url' => media_filename }] : nil,
        'caption' => (caption unless caption.empty?)
      }.compact
    end

    # Tumblr bakes its own sandbox origin (safe.txmblr.com) into the iframe
    # src. YouTube checks `origin` against the actual embedding page and
    # rejects playback (error 153) if it doesn't match, so strip it -- an
    # embed with no origin param is accepted from any domain.
    def embed_html_for(block)
      html = block['embed_html']
      return nil if html.to_s.strip.empty?

      html.gsub(/(?:&amp;|&)origin=[^&"]*/, '')
    end

    def link_block(block, media)
      poster = (block['poster'] || []).first
      poster_filename = poster && media.from_url(poster['url'])
      {
        'type' => 'link',
        'url' => block['url'],
        'title' => block['title'],
        'description' => block['description'],
        'site_name' => block['site_name'],
        'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
      }.compact
    end

    def build_slug(item)
      slug = Slug.slugify(item['slug'])
      slug = Slug.slugify(item['summary']) if slug.empty?
      slug.empty? ? "post-#{item['id']}" : slug
    end
  end
end
