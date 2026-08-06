# frozen_string_literal: true

require 'csv'
require 'json'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'permalinks'

module Import
  # Imports a Wix blog export -- one CSV from the Wix admin, with each
  # post's body as "Ricos" JSON (a node tree, not HTML) in the Rich
  # Content column. The tree maps onto blog.sh blocks more directly than
  # any HTML would: paragraphs with decoration spans, headings, lists,
  # tables, images by CDN id. What the tree cannot express here (video,
  # galleries, polls) is counted and named rather than silently lost.
  #
  # No media in the export -- everything downloads from
  # static.wixstatic.com, so import while Wix still serves it.
  class Wix
    attr_accessor :keep_permalinks

    def initialize(csv_path, keep_permalinks: false)
      @path = csv_path
      @keep_permalinks = keep_permalinks
      @unknown = Hash.new(0)
    end

    def label
      "Wix export (#{File.basename(@path)})"
    end

    def preamble
      "Reading #{@path} (#{(File.size(@path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def platform_tag
      'wix'
    end

    def each_item(&block)
      rows = CSV.read(@path, headers: true)
      items = rows.sort_by { |r| r['Published Date'].to_s }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      blocks = RichContent.blocks(item['Rich Content'], @unknown)
      blocks = plain_blocks(item['Plain Content']) if blocks.empty?
      blocks = cover_block(item['Cover Image']) + blocks
      blocks = localize_images(blocks, media)
      return :empty if blocks.empty?

      published = !item['Published Date'].to_s.strip.empty?
      slug = Slug.slugify(item['Slug'].to_s)
      slug = Slug.slugify(item['Title'].to_s) if slug.empty?

      post = {
        'slug' => slug,
        'title' => item['Title'].to_s.empty? ? slug : item['Title'],
        'date' => (Time.parse(item['Published Date'].to_s) rescue Time.now).iso8601,
        'state' => published ? 'published' : 'draft',
        'tags' => tags_of(item),
        'content' => blocks,
        'source' => {
          'platform' => 'wix',
          'account' => File.basename(File.expand_path(@path)),
          'original_id' => item['Internal ID'] || item['ID']
        }.compact
      }
      origin = item['Post Page URL'].to_s
      post['redirect_from'] = [origin] if @keep_permalinks && published && origin.start_with?('/')
      post
    end

    def postscript
      return nil if @unknown.empty?

      listed = @unknown.sort_by { |_, n| -n }.map { |type, n| "#{n}× #{type}" }.join(', ')
      I18n.t('import.note.wix_dropped', listed: listed)
    end

    private

    # Tags and Categories are JSON arrays serialized INTO a CSV cell --
    # and older exports put 24-hex Wix ids where category names should
    # be, which are dropped: an id makes no tag anyone would click.
    def tags_of(item)
      raw = [item['Main Category'].to_s] + cell_array(item['Categories']) + cell_array(item['Tags'])
      raw.map(&:strip)
         .reject(&:empty?)
         .reject { |t| t.match?(/\A[a-f0-9]{24}\z/i) }
         .uniq { |t| t.downcase }
    end

    def cell_array(cell)
      value = cell.to_s.strip
      return [] if value.empty?

      parsed = JSON.parse(value)
      parsed.is_a?(Array) ? parsed.map(&:to_s) : [value]
    rescue JSON::ParserError
      [value]
    end

    def plain_blocks(text)
      text.to_s.split(/\n{2,}/).filter_map do |para|
        clean = para.strip
        { 'type' => 'text', 'text' => clean } unless clean.empty?
      end
    end

    # "wix:image://v1/<id>/<name>#originWidth=..&originHeight=.." -- the
    # id is all the CDN needs. A cell already holding https:// is left as
    # it is.
    def cover_block(cell)
      value = cell.to_s.strip
      return [] if value.empty?

      url = if (m = value.match(%r{\Awix:image://v1/([^/]+)/}))
              "https://static.wixstatic.com/media/#{m[1]}"
            elsif value.start_with?('http')
              value
            end
      url ? [{ 'type' => 'image', 'media' => [{ 'url' => url }] }] : []
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

    # The Ricos node tree → blog.sh blocks. A close cousin of HtmlBlocks,
    # just fed structure instead of markup; the node and decoration maps
    # follow mg-wix-csv's rich-content.ts (MIT).
    module RichContent
      module_function

      def blocks(json, unknown)
        nodes = begin
          (JSON.parse(json.to_s)['nodes'] || [])
        rescue JSON::ParserError
          []
        end
        nodes.filter_map { |node| convert(node, unknown) }.flatten
      end

      def convert(node, unknown)
        case node['type']
        when 'PARAGRAPH'
          text, formatting = rich_text(node['nodes'])
          return nil if text.strip.empty?

          block = { 'type' => 'text', 'text' => text }
          block['formatting'] = formatting unless formatting.empty?
          block
        when 'HEADING'
          # Bold inside a heading is dropped -- a heading is already bold
          # all by itself.
          text, = rich_text(node['nodes'])
          return nil if text.strip.empty?

          level = node.dig('headingData', 'level').to_i.clamp(1, 6)
          { 'type' => 'text', 'subtype' => "heading#{level}", 'text' => text }
        when 'BULLETED_LIST', 'ORDERED_LIST'
          { 'type' => 'list',
            'style' => node['type'] == 'ORDERED_LIST' ? 'ol' : 'ul',
            'items' => list_items(node['nodes'], unknown) }
        when 'DIVIDER'
          { 'type' => 'hr' }
        when 'IMAGE'
          id = node.dig('imageData', 'image', 'src', 'id').to_s
          return nil if id.empty?

          block = { 'type' => 'image',
                    'media' => [{ 'url' => "https://static.wixstatic.com/media/#{id}" }] }
          alt = node.dig('imageData', 'altText').to_s
          block['caption'] = alt unless alt.empty?
          block
        when 'TABLE'
          rows = (node['nodes'] || []).map { |row| table_cells(row) }
          return nil if rows.empty?

          { 'type' => 'table', 'header' => rows.first, 'rows' => rows.drop(1) }
        when 'BUTTON'
          text = node.dig('buttonData', 'text').to_s
          url = node.dig('buttonData', 'link', 'url').to_s
          return nil if text.empty? || !safe_href?(url)

          { 'type' => 'text', 'text' => text,
            'formatting' => [{ 'type' => 'link', 'url' => url, 'start' => 0, 'end' => text.length }] }
        else
          unknown[node['type'] || 'UNKNOWN'] += 1
          nil
        end
      end

      def rich_text(nodes)
        text = +''
        spans = []
        (nodes || []).each do |child|
          next unless child['type'] == 'TEXT'

          chunk = child.dig('textData', 'text').to_s
          start = text.length
          text << chunk
          (child.dig('textData', 'decorations') || []).each do |deco|
            span = span_for(deco, start, text.length)
            spans << span if span
          end
        end
        [text, spans]
      end

      def span_for(deco, start, finish)
        case deco['type']
        when 'BOLD' then { 'type' => 'bold', 'start' => start, 'end' => finish }
        when 'ITALIC' then { 'type' => 'italic', 'start' => start, 'end' => finish }
        when 'LINK'
          url = deco.dig('linkData', 'link', 'url').to_s
          { 'type' => 'link', 'url' => url, 'start' => start, 'end' => finish } if safe_href?(url)
        end
      end

      def list_items(nodes, unknown)
        (nodes || []).filter_map do |item|
          next unless item['type'] == 'LIST_ITEM'

          paragraphs = (item['nodes'] || []).select { |n| n['type'] == 'PARAGRAPH' }
          text, formatting = rich_text(paragraphs.flat_map { |p| p['nodes'] || [] })
          nested = (item['nodes'] || []).select { |n| %w[BULLETED_LIST ORDERED_LIST].include?(n['type']) }
          entry = { 'text' => text }
          entry['formatting'] = formatting unless formatting.empty?
          unless nested.empty?
            child = convert(nested.first, unknown)
            entry['children'] = child['items'] if child
          end
          entry
        end
      end

      def table_cells(row)
        (row['nodes'] || []).map do |cell|
          text, formatting = rich_text((cell['nodes'] || []).flat_map { |p| p['nodes'] || [] })
          cell_entry = { 'text' => text }
          cell_entry['formatting'] = formatting unless formatting.empty?
          cell_entry
        end
      end

      def safe_href?(url)
        url.match?(%r{\A(https?:|mailto:|tel:)}i)
      end
    end
  end
end
