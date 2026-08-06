# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative '../i18n'
require_relative '../slug'
require_relative 'meta_text'

module Import
  # Imports a Threads export -- the JSON variant of Meta's "Download
  # your information" with Threads selected, pointed at the unpacked
  # directory. Everything is local: threads/threads_and_replies.json
  # plus media files in the archive.
  #
  # The shape is Meta's oddest yet: every post is a media LIST even when
  # there is no media -- a text post is one entry with an empty uri and
  # the text in its title field. Replies are marked natively
  # (text_app_post.is_reply) and skipped: an archive holds your own
  # standalone posts, same rule as Bluesky and Twitter. The
  # cross_post_source flag is NOT a skip signal here -- on the export
  # this was built against it sat on every single post, tests written
  # in the Threads app included, so it records where a post was SHARED
  # TO, not where it came from.
  class Threads
    def initialize(dir)
      @dir = File.expand_path(dir)
      @json = self.class.posts_file(@dir)
      @replies = 0
    end

    # The unpacked export nests differently per era: threads/ at the
    # top, or under your_instagram_activity/ (Threads lives on the
    # Instagram account, and Meta moves furniture).
    def self.posts_file(dir)
      ['threads/threads_and_replies.json',
       'your_instagram_activity/threads/threads_and_replies.json',
       'threads_and_replies.json']
        .map { |candidate| File.join(dir, candidate) }
        .find { |path| File.exist?(path) }
    end

    def label
      "Threads export (#{File.basename(@dir)})"
    end

    def total
      @total
    end

    def platform_tag
      'threads'
    end

    def each_item(&block)
      parsed = JSON.parse(File.read(@json, encoding: 'utf-8'))
      items = parsed['text_post_app_text_posts'] || []
      items.sort_by! { |i| timestamp_of(i) }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      entries = item['media'].to_a
      return :empty if entries.empty?

      if entries.any? { |e| e.dig('text_app_post', 'is_reply') }
        @replies += 1
        return :reply
      end

      text = MetaText.repair(entries.first['title']).strip
      blocks = text_blocks(text) + media_blocks(entries, text, media)
      return :empty if blocks.empty?

      date = Time.at(timestamp_of(item))
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug = "threads-#{date.strftime('%Y%m%d%H%M%S')}" if slug.empty?

      {
        'slug' => slug,
        'title' => nil,
        'date' => date.iso8601,
        'state' => 'published',
        'tags' => [],
        'content' => blocks,
        'source' => {
          'platform' => 'threads',
          'account' => File.basename(@dir),
          # No ids anywhere in the export -- same minting as Facebook:
          # the timestamp+content pair survives a re-export.
          'original_id' => "#{timestamp_of(item)}-#{Digest::MD5.hexdigest(text + entries.map { |e| e['uri'].to_s }.join(','))[0, 10]}"
        }
      }
    end

    def postscript
      return nil if @replies.zero?

      I18n.t('import.note.threads_replies', count: @replies)
    end

    private

    def timestamp_of(item)
      item['media'].to_a.filter_map { |e| e['creation_timestamp'] }.min.to_i
    end

    # Threads text is bare -- no markup -- but half of what people post
    # there is a link, so bare URLs become link spans rather than
    # staying dead text.
    def text_blocks(text)
      text.split(/\n{2,}/).filter_map do |para|
        clean = para.strip
        next nil if clean.empty?

        block = { 'type' => 'text', 'text' => clean }
        spans = []
        clean.scan(%r{https?://[^\s]+}) do
          match = Regexp.last_match
          spans << { 'type' => 'link', 'url' => match[0],
                     'start' => match.begin(0), 'end' => match.end(0) }
        end
        block['formatting'] = spans unless spans.empty?
        block
      end
    end

    def media_blocks(entries, text, media)
      entries.filter_map do |entry|
        uri = entry['uri'].to_s
        next nil if uri.empty?

        path = [File.join(@dir, uri),
                File.join(@dir, uri.sub(%r{\Ayour_instagram_activity/}, ''))]
               .find { |candidate| File.exist?(candidate) }
        next nil unless path

        filename = media.from_file(path)
        next nil unless filename

        kind = path.match?(/\.(mp4|mov)\z/i) ? 'video' : 'image'
        media_entry = { 'url' => filename }
        if kind == 'image'
          width, height = media.dimensions(filename)
          media_entry['width'] = width if width
          media_entry['height'] = height if height
        end
        block = { 'type' => kind, 'media' => [media_entry] }
        caption = MetaText.repair(entry['title']).strip
        block['caption'] = caption if !caption.empty? && caption != text
        block
      end
    end
  end
end
