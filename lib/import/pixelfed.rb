# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../slug'
require_relative 'html_blocks'

module Import
  # Imports a Pixelfed statuses export -- the "Statuses" JSON from Settings
  # → Data Export. Unlike Mastodon's archive this carries no media files,
  # only links to them, so the photos are downloaded; unlike a feed it
  # carries the whole account rather than a recent page, and states each
  # image's real dimensions, which for a photo network is the difference
  # between an archive and a wall of dropped blocks.
  #
  # Same scope as the other social sources: standalone posts, no replies,
  # no reblogs.
  class Pixelfed
    def initialize(path)
      @path = path
    end

    def label
      "Pixelfed (#{account})"
    end

    def preamble
      "Reading #{@path} (#{(File.size(@path) / 1024.0).round} kB)…"
    end

    def total
      @total
    end

    def each_item(&block)
      items = JSON.parse(File.read(@path, encoding: 'utf-8'))
      items = items['data'] if items.is_a?(Hash)
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      return :reblog if item['reblog']
      return :reply if item['in_reply_to_id']

      blocks = strip_trailing_hashtags(HtmlBlocks.parse(item['content'].to_s).blocks)
      blocks.concat(image_blocks(item, media))
      return :empty if blocks.empty?

      {
        'slug' => build_slug(item, blocks),
        'title' => nil,
        'date' => Time.parse(item['created_at']).iso8601,
        'state' => 'published',
        'tags' => (item['tags'] || []).filter_map { |t| t['name'] }.uniq { |t| t.downcase },
        'content' => blocks,
        'source' => {
          'platform' => 'pixelfed',
          'account' => account,
          'post_url' => item['url'] || item['uri'],
          'original_id' => item['id'].to_s
        }
      }
    end

    private

    def account
      @account ||= begin
        first = JSON.parse(File.read(@path, encoding: 'utf-8')).first || {}
        acct = first.dig('account', 'acct') || first.dig('account', 'username')
        acct.to_s.empty? ? File.basename(@path, '.json') : acct
      rescue StandardError
        File.basename(@path, '.json')
      end
    end

    # A Pixelfed caption ends in a stack of hashtags, one per line, which
    # the paragraph splitter turns into a block each -- five one-word
    # paragraphs of "#sweden", "#malmö" trailing every post. They are
    # already captured as the post's tags, so as prose they are noise;
    # dropped only from the end, since a hashtag used mid-sentence is
    # someone writing, not tagging.
    HASHTAG_LINE = /\A(?:#[[:word:]]+[[:space:]]*)+\z/

    def strip_trailing_hashtags(blocks)
      blocks.pop while blocks.last && blocks.last['type'] == 'text' &&
                      blocks.last['text'].to_s.match?(HASHTAG_LINE)
      blocks
    end

    # The export links to the CDN rather than shipping the files, so these
    # are downloads -- but meta.original carries the real pixel size, so
    # nothing needs measuring afterwards.
    def image_blocks(item, media)
      (item['media_attachments'] || []).filter_map do |att|
        url = att['url'] || att['optimized_url'] || att['remote_url']
        filename = url && media.from_url(url)
        next unless filename

        original = att.dig('meta', 'original') || {}
        entry = { 'url' => filename }
        entry['width'] = original['width'] if original['width']
        entry['height'] = original['height'] if original['height']
        block = { 'type' => att['type'].to_s == 'video' ? 'video' : 'image', 'media' => [entry] }
        alt = att['description'].to_s.strip
        block['alt_text'] = alt unless alt.empty?
        block
      end
    end

    # A Pixelfed caption is often several paragraphs, so the slug comes
    # from the first few words rather than the whole thing -- which is what
    # produced 400-character URLs when this content was first tried through
    # the feed importer.
    def build_slug(item, blocks)
      text = blocks.find { |b| b['type'] == 'text' }&.fetch('text', '').to_s
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "pixelfed-#{item['id']}" : slug
    end
  end
end
