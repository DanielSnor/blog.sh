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
      items = rows.sort_by { |r| r['Published Date'].to_s }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      return :misaligned_row if misaligned?(item)

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

    # A row whose cells no longer line up with the header. Liberal parsing
    # keeps a half-quoted cell rather than raising, and while that is the
    # right trade for the file as a whole, it is not free: if the damaged
    # cell also contains a comma -- in prose the rule, not the exception --
    # the quote stops mattering and the comma splits the cell in two, so
    # every column after it slides one to the left. The date lands in the
    # Featured column, the body in the date, and CSV hands back one extra
    # field with no header to sit under.
    #
    # That is the shape this looks for. A post published under the wrong
    # date with somebody else's body is worse than a post that did not
    # arrive: this one is silent, survives the summary, and is found
    # months later. So the row is skipped by name and the run says how
    # many -- the author can open the file at that row and fix the quote.
    def misaligned?(row)
      row.respond_to?(:headers) && row.headers.any?(&:nil?)
    end

    # liberal_parsing, because one odd cell must not cost the whole
    # export. Wix itself writes RFC 4180, but the file rarely reaches an
    # import untouched: opened and saved in Excel or Numbers, or patched
    # by hand, and a cell then holds `He said "hi" to me` or `"" ,` (the
    # shape in Ghost's own mg-wix-csv fixture, row 3). Ruby's strict
    # parser raises on the first one, so a thousand sound rows arrived as
    # zero posts -- reported, on top of that, as the source having
    # stopped answering, when the file was sitting on disk all along.
    # A cell that keeps a stray quote is a far smaller loss than the whole
    # blog; a row that slid out of line is not kept at all, see
    # misaligned?. The encoding is deliberately NOT named here (unlike
    # substack.rb): every way in loads site_config, which pins
    # default_external to UTF-8 before this file is required.
    def rows
      CSV.read(@path, headers: true, liberal_parsing: true)
    rescue CSV::MalformedCSVError => e
      # A quote opened and never closed still ends here, and rightly so:
      # it swallows every following row, and no parser can guess where
      # the cell was meant to end. Name the file and keep the line
      # number, so the reader looks at their CSV rather than at Wix.
      raise "#{File.basename(@path)} is not readable as CSV (#{e.message.strip}) -- " \
            'the damage is in the file on disk, not at Wix'
    end

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
        when 'BLOCKQUOTE'
          # Ricos wraps the quoted PARAGRAPHs in a node of their own, and
          # a node type nobody claimed used to be dropped whole -- so a
          # quotation left the import with its text, not just its
          # indentation. blog.sh has had a quote block all along; like
          # HtmlBlocks does with <blockquote>, each paragraph becomes one,
          # since the schema's quote is a single text block.
          quotes = (node['nodes'] || []).filter_map do |child|
            next convert(child, unknown) unless child['type'] == 'PARAGRAPH'

            text, formatting = rich_text(child['nodes'])
            next if text.strip.empty?

            block = { 'type' => 'text', 'subtype' => 'quote', 'text' => text }
            block['formatting'] = formatting unless formatting.empty?
            block
          end
          quotes.empty? ? nil : quotes
        when 'CODE_BLOCK'
          # Children are bare TEXT nodes; decorations inside code would be
          # styling we have nowhere to put anyway.
          text, = rich_text(node['nodes'])
          return nil if text.strip.empty?

          { 'type' => 'code', 'text' => text }
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
          rows = rows.reject(&:empty?)
          return nil if rows.empty?

          # align is not decoration. MarkdownWriter draws the separator
          # row from it, and without one the row comes out "|  |" -- a
          # single empty cell instead of a dash per column, which is no
          # longer a table in markdown. The post looked right until
          # somebody opened it in the editor and saved: MarkdownParser
          # refused the shape, and the whole table came back as one
          # paragraph of pipes. This was the only place in the engine
          # building a table block without it; HtmlBlocks has always
          # written the same left-aligned default, and a table from the
          # HTML path survived the round trip all along.
          # Ricos says outright whether the first row is a heading, and this
          # used to promote it either way -- true, false and absent gave the
          # same table three times. Absent means false, the way it does
          # everywhere else in that format: a table only has a header row
          # when the editor was told to give it one.
          block = { 'type' => 'table', 'align' => Array.new(rows.first.size, 'left') }
          block['header'] = rows.shift if node.dig('tableData', 'rowHeader') == true
          block['rows'] = rows
          block
        when 'BUTTON'
          text = node.dig('buttonData', 'text').to_s
          return nil if text.empty?

          # Wix stores button links without a scheme ("www.wix.com"), and
          # a button of type ACTION carries no link key at all. Neither is
          # a reason to lose the label -- often the one thing the post
          # actually asks the reader to do -- and the loss was invisible
          # on top of that, since a handled type never reaches the count
          # below. The label stays as plain text, which is what Ghost's
          # own Wix importer does with the same two shapes.
          url = node.dig('buttonData', 'link', 'url').to_s
          return { 'type' => 'text', 'text' => text } unless safe_href?(url)

          { 'type' => 'text', 'text' => text,
            'formatting' => [{ 'type' => 'link', 'url' => url, 'start' => 0, 'end' => text.length }] }
        else
          # An unclaimed type with children is a CONTAINER, not a payload:
          # COLLAPSIBLE_LIST holds COLLAPSIBLE_ITEMs holding ordinary
          # PARAGRAPHs, and dropping the node whole threw away readable
          # text that maps onto blocks perfectly well one level down. Only
          # the fold-out structure is lost, which a static page has no use
          # for. Counted -- and named in the summary -- are the leaves:
          # VIDEO, POLL, GALLERY and the like carry their payload outside
          # `nodes`, so for those the node really is what disappears.
          nested = node['nodes'] || []
          children = nested.filter_map { |child| convert(child, unknown) }.flatten
          return children unless children.empty?

          unknown[node['type'] || 'UNKNOWN'] += 1 if nested.empty?
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
