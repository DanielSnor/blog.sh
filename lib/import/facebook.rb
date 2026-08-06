# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative '../slug'
require_relative 'meta_text'
require_relative 'permalinks'

module Import
  # Imports a Facebook export -- the JSON variant of Meta's "Download
  # your information", pointed at the unpacked directory. Everything is
  # local: text in your_posts*.json, photos and videos as files in the
  # archive, nothing downloaded. Ask Meta for JSON rather than HTML;
  # the JSON carries epoch timestamps where the HTML prints wall-clock
  # times in an unnamed timezone.
  #
  # What counts as a post: something with your own text, media, or a
  # shared link. Bare check-ins, app stories and other timeline
  # furniture are skipped and counted by name. Facebook's export has no
  # per-post id at all, so the re-import identity is minted from the
  # timestamp plus a digest of the content -- the pair that survives a
  # re-export.
  class Facebook
    # The dominant content of an older personal account is not posts but
    # CROSSPOSTS -- on the export this was built against, 95 % of all
    # entries were Twitter and Posterous echoes. Imported silently they
    # would duplicate the user's own Twitter archive thousands of times,
    # so they are skipped and counted by default; include_crossposts
    # brings them in for the account that really lived on Facebook.
    #
    # Detection leans on the two signals the export offers: the
    # FB-generated title mentions the platform by (language-independent)
    # proper name, and crosspost bodies carry the shorteners of their
    # era. The title is never the user's own text, so a post ABOUT
    # Twitter is safe.
    CROSSPOST_TITLE = /\b(Twitter|Posterous|Instagram|Foursquare|Swarm|Klout|tvtag|GetGlue)\b/
    CROSSPOST_LINK = %r{https?://(t\.co|klou\.tt|4sq\.com|post\.ly)/}

    def initialize(dir, include_crossposts: false)
      @dir = File.expand_path(dir)
      @posts_dir = self.class.posts_dir(@dir)
      @include_crossposts = include_crossposts
      @crossposts = 0
    end

    # The unpacked export nests differently per era -- posts/ at the
    # top, or under your_facebook_activity/. Accept the archive root,
    # either parent, or the posts directory itself.
    def self.posts_dir(dir)
      [File.join(dir, 'posts'),
       File.join(dir, 'your_facebook_activity', 'posts'),
       dir].find { |candidate| !Dir.glob(File.join(candidate, 'your_posts*.json')).empty? }
    end

    def label
      "Facebook export (#{File.basename(@dir)})"
    end

    def total
      @total
    end

    def platform_tag
      'facebook'
    end

    def each_item(&block)
      files = Dir.glob(File.join(@posts_dir, 'your_posts*.json')).sort
      items = files.flat_map { |f| JSON.parse(File.read(f, encoding: 'utf-8')) }
      items.sort_by! { |i| i['timestamp'].to_i }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      text = item['data'].to_a.filter_map { |entry| presence(MetaText.repair(entry['post'])) }.join("\n\n")
      attachments = item['attachments'].to_a.flat_map { |a| a['data'].to_a }
      media_entries = attachments.filter_map { |a| a['media'] }
      links = attachments.filter_map { |a| a['external_context'] }
      places = attachments.filter_map { |a| a['place'] }

      # A check-in with nothing said is a dot on a map, not a post; an
      # entry with none of the three is app-story furniture ("shared an
      # app"). Both are counted under their own names.
      return :checkin if text.empty? && media_entries.empty? && links.empty? && !places.empty?
      return :no_content if text.empty? && media_entries.empty? && links.empty?

      if !@include_crossposts && crosspost?(item, text)
        @crossposts += 1
        return :crosspost
      end

      blocks = text_blocks(text) + media_blocks(media_entries, text, media) + link_blocks(links)
      return :empty if blocks.empty?

      date = Time.at(item['timestamp'].to_i)
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug = "facebook-#{date.strftime('%Y%m%d%H%M%S')}" if slug.empty?

      {
        'slug' => slug,
        'title' => nil,
        'date' => date.iso8601,
        'state' => 'published',
        'tags' => [],
        'content' => blocks,
        'source' => {
          'platform' => 'facebook',
          'account' => File.basename(@dir),
          'original_id' => "#{item['timestamp']}-#{content_digest(text, media_entries)}"
        }
      }
    end

    def postscript
      return nil if @crossposts.zero?

      "#{@crossposts} post(s) were crossposts from other platforms (Twitter, Posterous, ...) -- skipped so they don't duplicate those platforms' own imports. FACEBOOK_CROSSPOSTS=1 includes them."
    end

    private

    def crosspost?(item, text)
      MetaText.repair(item['title']).match?(CROSSPOST_TITLE) || text.match?(CROSSPOST_LINK)
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def content_digest(text, media_entries)
      Digest::MD5.hexdigest(text + media_entries.map { |m| m['uri'].to_s }.join(','))[0, 10]
    end

    def text_blocks(text)
      text.split(/\n{2,}/).filter_map do |para|
        clean = para.strip
        { 'type' => 'text', 'text' => clean } unless clean.empty?
      end
    end

    # The media uri is a path INSIDE the archive, prefixed (or not) with
    # your_facebook_activity/ depending on where the unpacking started.
    # A media description that just repeats the post text is Facebook's
    # habit, not a caption.
    def media_blocks(entries, text, media)
      entries.filter_map do |entry|
        path = resolve(entry['uri'].to_s)
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
        caption = presence(MetaText.repair(entry['description']))
        block['caption'] = caption if caption && caption != text
        block
      end
    end

    def resolve(uri)
      return nil if uri.empty?

      [File.join(@dir, uri),
       File.join(@dir, uri.sub(%r{\Ayour_facebook_activity/}, '')),
       File.join(@posts_dir, '..', uri.sub(%r{\Ayour_facebook_activity/}, ''))]
        .find { |candidate| File.exist?(candidate) }
    end

    def link_blocks(links)
      links.filter_map do |link|
        url = link['url'].to_s
        next nil if url.empty?

        title = presence(MetaText.repair(link['name'])) || url
        { 'type' => 'link', 'url' => url, 'title' => title }
      end
    end
  end
end
