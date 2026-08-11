# frozen_string_literal: true

require 'time'
require 'uri'
require 'zlib'
require_relative '../i18n'
require_relative '../markdown_parser'
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

    # The two CONVERT BREAKS values that mean "the body is markdown"; the
    # smartypants variant differs only in the typography MT applied on
    # its way out to HTML, which is not our business here.
    MARKDOWN_FILTERS = %w[markdown markdown_with_smartypants].freeze

    def initialize(path, url_pattern: nil, keep_permalinks: false)
      @path = path
      @url_pattern = url_pattern
      @keep_permalinks = keep_permalinks
      @comments = 0
      @pings = 0
      @textile = 0
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
      source_text = [body, extended].reject { |part| part.strip.empty? }.join("\n\n")
      return :empty if source_text.strip.empty?

      # CONVERT BREAKS names the LANGUAGE the body is written in, not
      # merely whether line breaks need converting: "0" is HTML as
      # written, "markdown"/"markdown_with_smartypants" is markdown
      # source, and everything else ("1", "__default__", "richtext",
      # "textile_2") is text whose blank lines are paragraphs -- fed raw
      # to an HTML parse it would collapse into one run. Read as a plain
      # two-way switch, a markdown blog arrived with its own syntax
      # published as prose: "## Nadpis" with the hashes on, links
      # spelled out in brackets, both bullets of a list run into one
      # paragraph. (textile_2 is still read as text -- Textile's
      # paragraphs are blank-line separated like these, its inline
      # markup is not understood.)
      flag = item[:fields]['CONVERT BREAKS'].to_s.strip.downcase
      @textile += 1 if flag.start_with?('textile')
      blocks = if MARKDOWN_FILTERS.include?(flag)
                 markdown_blocks(source_text)
               else
                 HtmlBlocks.parse(flag == '0' ? source_text : paragraphize(source_text)).blocks
               end
      blocks = localize_images(blocks, media)
      return :empty if blocks.empty?

      date = item_date(item[:fields]['DATE'])
      # An unreadable DATE used to become Time.now: the post was filed
      # under the year of the import and the run said "written". A named
      # skip is the honest answer -- the operator can fix the export and
      # run again, which is what MT's own importer asks for (it refuses
      # the whole file over one bad date). Its own reason, not the
      # :undated that Substack returns: there the export simply carries
      # no date, here one is written in a way this could not read, and
      # only the second is worth going back to the file for.
      return :bad_date unless date

      @comments += item[:comments]
      @pings += item[:pings]

      basename = item[:fields]['BASENAME'].to_s
      title = item[:fields]['TITLE'].to_s
      slug = Slug.slugify(basename)
      slug = Slug.slugify(title.split(/\s+/).first(10).join(' ')) if slug.empty?
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

    # Textile is read as plain text: its blank lines separate paragraphs
    # like everything else here, but h2., "text":url and *bold* are not
    # understood and arrive as written. Said out loud rather than left
    # for the author to find -- there is no converter to reach for.
    def postscript
      notes = []
      notes << I18n.t('import.note.movabletype_textile', count: @textile) if @textile.positive?
      parts = []
      parts << I18n.t('import.note.movabletype_comments', count: @comments) if @comments.positive?
      parts << I18n.t('import.note.movabletype_pings', count: @pings) if @pings.positive?
      unless parts.empty?
        notes << I18n.t('import.note.movabletype_left_behind',
                        parts: parts.join(I18n.t('import.note.movabletype_and')))
      end
      notes.empty? ? nil : notes.join("\n  ")
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

    # A separator line is the dashes and nothing else. Surrounding SPACES
    # are tolerated, a tab is not -- deliberately: the export escapes a
    # body line that happens to be five or eight dashes by appending a
    # tab (ImportExport.pm's sep_replacer), and strips it back off on
    # import. Compared with .strip on both ends, that tab was eaten and
    # the escaped line read as a real separator: the section ended in the
    # middle of the post and every paragraph after it fell outside any
    # section, which is to say it was dropped without a word.
    # (A stray \r is tolerated on both for a file with mixed line endings;
    # a plain CRLF export loses it to chomp long before this.)
    SEPARATOR = /\A *(-{5}|-{8})[ \r]*\z/
    ESCAPED_SEPARATOR = /\A(-{5}|-{8})\t\r?\z/

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
        if (separator = SEPARATOR.match(stripped))
          finish_section.call
          if separator[1].length == 8
            unless fields.empty? && sections.empty?
              entries << { fields: fields, sections: sections, comments: comments, pings: pings }
            end
            fields = {}
            sections = {}
            comments = 0
            pings = 0
          end
          next
        end

        if current
          # The escape comes back off exactly where MT takes it off, so a
          # line of dashes the author wrote survives as itself.
          buffer << stripped.sub(ESCAPED_SEPARATOR, '\1')
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

    # A markdown body goes through the authoring parser -- the same one
    # `blog.sh new` reads a post with -- but the pictures have to be
    # lifted out of it first, twice over:
    #
    #   * MarkdownParser is written for photos being uploaded, so it
    #     renames an image path to the next free NN.jpg. That drops the
    #     address localize_images has to download from, and the block
    #     would then be thrown away as a picture pointing nowhere.
    #   * An image inside a line of prose makes it abort() -- right when
    #     you are saving something you just wrote, fatal when it is
    #     somebody's archive: abort is SystemExit, which the per-item
    #     rescue in Import::Run does not catch, so one such paragraph
    #     would end the whole run.
    #
    # Both go away if every image leaves the text before it is parsed and
    # comes back as a block afterwards, keyed by position so no URL has
    # to survive the round trip. Raw <img> tags are taken too: Markdown.pl
    # passed HTML through untouched, so a markdown body carries plenty of
    # it, and this path has no HTML parser behind it to catch them.
    IMAGE_MD = /(?<!\\)!\[([^\]]*)\]\(([^)\s]+?)(?:[ \t]+"[^"]*")?\)/
    # A thumbnail linking to the full-size picture, the oldest habit in
    # blog archives. The link goes and the picture stays -- which is what
    # HtmlBlocks does with <a href><img></a> on the other path, and
    # without it the brackets around the image were left standing as two
    # stray paragraphs, "[" and "](http://...)".
    LINKED_IMAGE_MD = /\[(#{IMAGE_MD.source})\]\([^)\s]+[^)]*\)/
    IMG_TAG = /<img\b[^>]*>/i
    IMAGE_SLOT = /\A@@mt-image:(\d+)@@\z/

    def markdown_blocks(text)
      images = []
      slot = lambda do |url, alt|
        images << [url.to_s.strip, alt.to_s.strip]
        # Blank lines around it: a picture is a block of its own, and a
        # sentinel left mid-paragraph would come back as prose.
        "\n\n@@mt-image:#{images.size - 1}@@\n\n"
      end

      text = text.gsub(LINKED_IMAGE_MD, '\1')
      text = text.gsub(IMAGE_MD) { slot.call(Regexp.last_match(2), Regexp.last_match(1)) }
      text = text.gsub(IMG_TAG) do
        tag = Regexp.last_match(0)
        slot.call(attr_of(tag, 'src'), attr_of(tag, 'alt'))
      end

      blocks, = MarkdownParser.parse_body(text, nil)
      blocks.map do |block|
        next block unless block['type'] == 'text' && (m = IMAGE_SLOT.match(block['text'].to_s.strip))

        # A slot number this parse never handed out is the author's own
        # text that happens to look like one -- left as it is.
        url, alt = images[m[1].to_i]
        next block unless url

        { 'type' => 'image', 'media' => [{ 'url' => url }], 'alt_text' => (alt.empty? ? nil : alt) }.compact
      end
    end

    def attr_of(tag, name)
      m = tag.match(/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i)
      m && (m[1] || m[2] || m[3]).to_s
    end

    # "07/24/2004 10:31:22 PM", no zone -- read in the site's timezone,
    # the same treatment wp:post_date gets. AM/PM is OPTIONAL, which the
    # format's own error message spells out ("must be 'MM/DD/YYYY
    # HH:MM:SS AM|PM' (AM|PM is optional)") and half the real exports
    # take it up on: the second entry of MT's own example file is "DATE:
    # 01/31/2002 03:31:05". Read through a %p strptime those fail, and
    # what used to catch them made it worse rather than better --
    # Time.parse reads MM/DD as DD/MM ("08/05/2002" became 8 May), and
    # where the day is past 12 it gave up and handed back Time.now, so
    # the post was filed under the year of the IMPORT. Nothing said a
    # word: the summary counted it as written.
    #
    # So the format's own grammar (ImportExport.pm, _convert_date) is
    # parsed here instead, and a value that does not match is refused
    # rather than guessed at -- a skip the summary can show beats a
    # silently wrong date in the archive.
    MT_DATE = %r{\A\s*(\d{1,2})/(\d{1,2})/(\d{2,4})\s+(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\s+([AaPp])\.?[Mm]\.?)?\s*\z}

    def item_date(value)
      m = MT_DATE.match(value.to_s)
      return nil unless m

      month, day, year, hour, minute, second = m.values_at(1, 2, 3, 4, 5, 6).map(&:to_i)
      meridiem = m[7].to_s.upcase
      hour += 12 if meridiem == 'P' && hour < 12
      hour = 0 if meridiem == 'A' && hour == 12
      # MT adds 1900 to a two-digit year, which is right for the Perl
      # tm_year it was written for (114 -> 2014) and absurd for a year
      # that really is two digits -- "11/13/14" is not 1914. The %y
      # window is used instead, so an MT-era export lands in its own
      # decade either way.
      year += year < 69 ? 2000 : 1900 if m[3].length == 2
      Time.local(year, month, day, hour, minute, second)
    rescue ArgumentError
      nil
    end

    # MT::Tag->split: commas separate, double quotes hold a tag that
    # contains one ("open source" -- the export quotes every multi-word
    # tag, glue=",", quote="1").
    def split_tags(value)
      value.to_s.scan(/"([^"]*)"|([^,]+)/).map { |quoted, plain| (quoted || plain).strip }
    end

    # TAGS is the format's own field and MT's real taxonomy from 3.3 on
    # (KEYWORDS is the leftover from before it). Reading only KEYWORDS
    # and the categories handed back an archive with no tags at all from
    # any blog that tagged rather than filed.
    def tags_of(item)
      tags = split_tags(item[:fields]['TAGS'])
      keywords = item[:sections][:keywords].to_s.split(',').map(&:strip)
      categories = Array(item[:fields]['CATEGORIES']).map(&:strip)
      (tags + keywords + categories).reject(&:empty?).uniq { |t| t.downcase }
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
