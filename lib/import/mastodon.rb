# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../slug'
require_relative 'html_blocks'

module Import
  # Imports a Mastodon account export -- the zip you get from Settings →
  # Import and export → Request your archive, unpacked. That's an
  # ActivityPub outbox plus the media files themselves, so this needs no
  # network and no token, and it holds the whole account rather than the
  # last page an API would hand out.
  #
  # Scope matches the other social sources: standalone posts only. Boosts
  # are someone else's writing, and replies are conversation -- on a
  # typical account they are the majority of everything (2984 of 5532 in
  # the archive this was built against).
  class Mastodon
    def initialize(export_dir)
      @export_dir = export_dir
    end

    def label
      "Mastodon (#{handle})"
    end

    def preamble
      "Reading #{outbox_path} (#{(File.size(outbox_path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def each_item(&block)
      items = JSON.parse(File.read(outbox_path, encoding: 'utf-8'))['orderedItems'] || []
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      return :boost unless item['type'] == 'Create'

      object = item['object'] || {}
      return :reply if object['inReplyTo']

      blocks = HtmlBlocks.parse(object['content'].to_s).blocks
      blocks.concat(attachment_blocks(object, media))
      return :empty if blocks.empty?

      {
        'slug' => build_slug(object, blocks),
        # A content warning summarises what follows, which is what a title
        # is -- so the post keeps its warning instead of losing it, and the
        # listing shows why it was hidden.
        'title' => presence(object['summary']),
        'date' => Time.parse(object['published']).iso8601,
        'state' => 'published',
        'tags' => hashtags(object),
        'content' => blocks,
        'source' => {
          'platform' => 'mastodon',
          'account' => handle,
          'post_url' => object['url'] || object['id'],
          'original_id' => object['id'].to_s.split('/').last
        }
      }
    end

    private

    def outbox_path
      File.join(@export_dir, 'outbox.json')
    end

    def handle
      @handle ||= begin
        actor = JSON.parse(File.read(File.join(@export_dir, 'actor.json'), encoding: 'utf-8'))
        name = actor['preferredUsername']
        host = URI.parse(actor['id'].to_s).host rescue nil
        [name, host].compact.join('@')
      rescue StandardError
        File.basename(@export_dir)
      end
    end

    # Attachment urls are paths inside the export ("/media_attachments/…"),
    # so this is a copy rather than a download -- and the width/height the
    # archive records mean nothing has to be measured afterwards.
    def attachment_blocks(object, media)
      (object['attachment'] || []).filter_map do |att|
        path = File.join(@export_dir, att['url'].to_s.sub(%r{\A/}, ''))
        filename = media.from_file(path)
        next unless filename

        entry = { 'url' => filename }
        entry['width'] = att['width'] if att['width']
        entry['height'] = att['height'] if att['height']
        kind = case att['mediaType'].to_s.split('/').first
               when 'video' then 'video'
               when 'audio' then 'audio'
               else 'image'
               end
        block = { 'type' => kind, 'media' => [entry] }
        alt = presence(att['name'])
        block['alt_text'] = alt if alt
        block
      end
    end

    def hashtags(object)
      (object['tag'] || []).filter_map do |tag|
        next unless tag['type'] == 'Hashtag'

        tag['name'].to_s.sub(/\A#/, '')
      end.reject(&:empty?).uniq { |t| t.downcase }
    end

    def build_slug(object, blocks)
      text = blocks.find { |b| b['type'] == 'text' }&.fetch('text', '').to_s
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "toot-#{object['id'].to_s.split('/').last}" : slug
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
