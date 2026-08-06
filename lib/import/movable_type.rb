# frozen_string_literal: true

require 'time'
require 'uri'
require 'zlib'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a Movable Type export -- the line-based "MT Import Format"
  # that TypePad still produces today and half the pre-WXR web once
  # spoke. One text file, whole blog: posts, comments, trackbacks,
  # separated by five-dash and eight-dash lines.
  #
  # Two things the format makes us invent. It has NO post id, so the
  # re-import identity is minted from the two stable things a post does
  # have (timestamp + basename). And it carries no URLs (unless TypePad
  # included UNIQUE URL lines), so kept permalinks take a pattern --
  # "/%Y/%m/{basename}.html" -- with UNIQUE URL winning where present.
  class MovableType
    attr_accessor :keep_permalinks

    SECTIONS = { 'BODY' => :body, 'EXTENDED BODY' => :extended, 'EXCERPT' => :excerpt,
                 'KEYWORDS' => :keywords, 'COMMENT' => :comment, 'PING' => :ping }.freeze

    def initialize(path, url_pattern: nil, keep_permalinks: false)
      @path = path
      @url_pattern = url_pattern
      @keep_permalinks = keep_permalinks
      @comments = 0
      @pings = 0
    end

    def label
      "Movable Type export (#{File.basename(@path)})"
    end

    def preamble
      "Reading #{@path} (#{(File.size(@path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def platform_tag
      typepad? ? 'typepad' : 'movabletype'
    end

    def each_item(&block)
      items = parse_entries
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      body = item[:sections][:body].to_s
      extended = item[:sections][:extended].to_s
      html = [body, extended].reject { |part| part.strip.empty? }.join("\n\n")
      return :empty if html.strip.empty?

      # CONVERT BREAKS on means the body is plain text where blank lines
      # are paragraphs -- fed raw to an HTML parse it would collapse into
      # one run. "0" means the HTML is already written out.
      html = paragraphize(html) unless item[:fields]['CONVERT BREAKS'].to_s.strip == '0'

      parsed = HtmlBlocks.parse(html)
      blocks = localize_images(parsed.blocks, media)
      return :empty if blocks.empty?

      @comments += item[:comments]
      @pings += item[:pings]

      basename = item[:fields]['BASENAME'].to_s
      title = item[:fields]['TITLE'].to_s
      slug = Slug.slugify(basename)
      slug = Slug.slugify(title.split(/\s+/).first(10).join(' ')) if slug.empty?
      date = item_date(item[:fields]['DATE'])
      # Publish unless said otherwise, like the plugin ecosystem reads
      # it; MT's Future has no cron here to honour, so it waits as a
      # draft rather than publishing under a date nobody reviewed.
      state = %w[draft future].include?(item[:fields]['STATUS'].to_s.strip.downcase) ? 'draft' : 'published'

      post = {
        'slug' => slug,
        'title' => title.empty? ? slug : title,
        'date' => date.iso8601,
        'state' => state,
        'tags' => tags_of(item),
        'content' => blocks,
        'source' => {
          'platform' => typepad? ? 'typepad' : 'movabletype',
          'account' => account,
          'post_url' => absolute_origin(item, basename.empty? ? slug : basename, date),
          # The format has no id; the timestamp+basename pair is the one
          # thing stable across re-exports.
          'original_id' => "#{date.strftime('%Y%m%d%H%M%S')}-#{slug}"
        }.compact
      }
      if @keep_permalinks && state == 'published'
        origin = origin_path(item, basename.empty? ? slug : basename, date)
        post['redirect_from'] = [origin] if origin
      end
      post
    end

    def postscript
      parts = []
      parts << I18n.t('import.note.movabletype_comments', count: @comments) if @comments.positive?
      parts << I18n.t('import.note.movabletype_pings', count: @pings) if @pings.positive?
      return nil if parts.empty?

      I18n.t('import.note.movabletype_left_behind', parts: parts.join(I18n.t('import.note.movabletype_and')))
    end

    private

    def read_source
      raw = File.binread(@path)
      raw = Zlib.gunzip(raw) if raw.byteslice(0, 2) == "\x1f\x8b".b
      text = raw.force_encoding('UTF-8')
      # Old exports declare nothing; the bytes decide. Whatever is not
      # valid UTF-8 is read again as Latin-1, the era's other habit.
      text = raw.encode('UTF-8', 'ISO-8859-1') unless text.valid_encoding?
      text
    end

    # The grammar, line by line: five dashes end a section, eight end the
    # post; KEY: lines are fields outside sections; everything inside a
    # section is kept VERBATIM -- trimming blank lines is how the WP
    # plugin breaks paragraphs and <pre> blocks, and exactly what not to
    # copy from it.
    def parse_entries
      entries = []
      fields = {}
      sections = {}
      current = nil
      comments = 0
      pings = 0
      buffer = []

      finish_section = lambda do
        case current
        when :comment then comments += 1
        when :ping then pings += 1
        when nil then nil
        else sections[current] = [sections[current], buffer.join("\n")].compact.join("\n")
        end
        current = nil
        buffer = []
      end

      read_source.each_line do |line|
        stripped = line.chomp
        case stripped.strip
        when '-----'
          finish_section.call
          next
        when '--------'
          finish_section.call
          unless fields.empty? && sections.empty?
            entries << { fields: fields, sections: sections, comments: comments, pings: pings }
          end
          fields = {}
          sections = {}
          comments = 0
          pings = 0
          next
        end

        if current
          buffer << stripped
        elsif (m = stripped.match(/\A([A-Z][A-Z ]+):\s*(.*)\z/))
          key, value = m[1], m[2]
          if SECTIONS.key?(key) && value.empty?
            current = SECTIONS[key]
          elsif key == 'CATEGORY' || key == 'PRIMARY CATEGORY'
            (fields['CATEGORIES'] ||= []) << value
          else
            fields[key] = value
          end
        end
      end
      finish_section.call
      entries << { fields: fields, sections: sections, comments: comments, pings: pings } unless fields.empty? && sections.empty?
      entries
    end

    def paragraphize(text)
      text.split(/\n{2,}/).map { |para| "<p>#{para.strip.gsub("\n", '<br>')}</p>" }.join("\n")
    end

    # "07/24/2004 10:31:22 PM", no zone -- read in the site's timezone,
    # the same treatment wp:post_date gets.
    def item_date(value)
      Time.strptime(value.to_s, '%m/%d/%Y %I:%M:%S %p')
    rescue ArgumentError
      begin
        Time.parse(value.to_s)
      rescue StandardError
        Time.now
      end
    end

    def tags_of(item)
      keywords = item[:sections][:keywords].to_s.split(',').map(&:strip)
      categories = Array(item[:fields]['CATEGORIES']).map(&:strip)
      (keywords + categories).reject(&:empty?).uniq { |t| t.downcase }
    end

    # UNIQUE URL (TypePad's own record of the address) beats any pattern;
    # without either there is no redirect -- a guessed address would 404
    # with a straight face.
    def origin_path(item, basename, date)
      unique = item[:fields]['UNIQUE URL'].to_s
      return Permalinks.local_path(unique) unless unique.empty?
      return nil unless @url_pattern

      built = date.strftime(@url_pattern).gsub('{basename}', basename).gsub('{slug}', basename)
      # The pattern may carry the full old URL (useful for post_url); a
      # redirect entry is always the site-root path alone.
      built.start_with?('http') ? Permalinks.local_path(built) : built
    end

    def absolute_origin(item, basename, date)
      unique = item[:fields]['UNIQUE URL'].to_s
      return unique unless unique.empty?
      return nil unless @url_pattern&.start_with?('http')

      date.strftime(@url_pattern).gsub('{basename}', basename).gsub('{slug}', basename)
    end

    def typepad?
      @url_pattern.to_s.include?('typepad.com')
    end

    def account
      host = URI.parse(@url_pattern.to_s).host
      host || File.basename(@path)
    rescue URI::InvalidURIError
      File.basename(@path)
    end

    def localize_images(blocks, media)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = block.dig('media', 0, 'url').to_s
        filename = url.start_with?('http') ? media.from_url(url) : nil
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end
  end
end
