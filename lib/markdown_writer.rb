# frozen_string_literal: true

require_relative 'markdown_parser'

# lib/markdown_writer.rb -- content blocks -> markdown text, the mirror of
# lib/markdown_parser.rb. Used by `blog.sh edit` to reopen a stored post as
# editable markdown; parse_body then turns the edited text back into
# blocks. Extracted from manage_post.rb, same as the parser before it, so
# the two directions of the round-trip sit next to each other in lib/.
#
# The output is always valid markdown for the parser to re-read, but not
# necessarily byte-identical to whatever the author originally typed --
# equivalent formatting (e.g. ties between overlapping spans) may come out
# normalized.
module MarkdownWriter
  # Characters that mean something and can therefore be escaped with a
  # backslash. Deliberately only these: a backslash before anything else is
  # left as-is -- otherwise emoticons like `d8-\` in older imported posts
  # would get mangled. The block sigils (# > - + . _ |) are in the class so
  # the parser unescapes them, but they are only ever ESCAPED at the spots
  # where they would mean something: the start of a line (see
  # escape_block_starts) and inside table cells -- escaping every hashtag
  # in a tweet archive would bury the text in backslashes.
  ESCAPABLE = '*`~[]!\\#>|.+_-'

  # Higher number = renders further out when two spans cover the exact same
  # range (only possible for e.g. "**[text](url)**", where the bold and the
  # link entries end up with identical start/end) -- link is always innermost.
  WRAP_PRIORITY = { 'link' => 0, 'code' => 0, 'italic' => 1, 'strikethrough' => 1, 'bold' => 2 }.freeze

  module_function

  # The one entry point: renders a post's whole `content` array back to
  # markdown, given the directory its media files live in (image/video
  # paths are written as absolute paths into that directory).
  def blocks_to_markdown(blocks, media_dir)
    blocks.filter_map do |b|
      case b['type']
      when 'text'
        rendered = render_text_markdown(b['text'], b['formatting'])
        case b['subtype']
        when /\Aheading([1-6])\z/ then "#{'#' * Regexp.last_match(1).to_i} #{rendered}"
        when 'quote'
          # Quote content gets the same line-start protection as prose: a
          # quoted line beginning ">" would nest a level deeper each edit.
          quoted = escape_block_starts(rendered).split("\n").map { |l| l.empty? ? '>' : "> #{l}" }.join("\n")
          b['cite'] ? "#{quoted}\n> — #{b['cite']}" : quoted
        # A newline stored in a paragraph is a hard break and writes back as
        # the visible backslash marker -- without this, re-saving would
        # collapse it into a space via the parser's prose-wrapping rule.
        else escape_block_starts(rendered).gsub("\n", "\\\n")
        end
      when 'table'
        table_to_markdown(b)
      when 'list'
        list_to_markdown(b)
      when 'hr'
        '---'
      when 'chat'
        body = (b['lines'] || []).map { |l| l['name'] ? "#{l['name']}: #{l['text']}" : l['text'].to_s }.join("\n")
        "```chat\n#{body}\n```"
      when 'code'
        "```#{b['lang']}\n#{b['text']}\n```"
      when 'image'
        media = (b['media'] || []).first || {}
        path = File.join(media_dir, media['url'].to_s)
        cap = b['caption'] ? %( "#{b['caption']}") : ''
        "![#{b['alt_text']}](#{path}#{cap})"
      when 'file'
        file = (b['media'] || []).first
        # Round-trips as the link line it came from: a bare filename, so
        # re-saving an edited post keeps the attachment instead of
        # turning it into a dead link to a name that isn't a URL.
        "[#{b['label']}](#{File.join(media_dir, file['url'].to_s)})" if file
      when 'audio'
        # Mirrors the video branch: a local file writes back as !![](file),
        # and so does a platform the engine can build a player for from the
        # address alone -- that address is exactly what the author typed.
        # An imported embed-only audio with no recognisable address (a raw
        # iframe from an old export) still has no markdown form and is
        # dropped here, which the CLI's content-loss safeguard catches
        # before anything is saved.
        #
        # `Embed.detect` and not just `Embed.src`: a Funkwhale or Bandcamp
        # block whose lookup has not succeeded yet has no player address,
        # but its own address still round-trips into the same block. Asking
        # for the player instead made such a post UNEDITABLE -- the writer
        # dropped the block, the loss safeguard stopped the save, and the
        # only way to edit the post at all was for the service to answer.
        media = (b['media'] || []).first
        caption = b['caption'].to_s.strip
        if media
          "!![#{caption.empty? ? 'Audio' : caption}](#{File.join(media_dir, media['url'].to_s)})"
        elsif Embed.src(b) || Embed.detect(b['url'].to_s)
          "!![#{caption.empty? ? 'Audio' : caption}](#{b['url']})"
        end
      when 'video'
        # Without this, `edit` would silently drop the video -- filter_map
        # below throws out a nil. An empty caption would be rejected on save,
        # so a generic one is filled in here -- so the round-trip never
        # produces something that can't be saved back.
        media = (b['media'] || []).first
        caption = b['caption'].to_s.strip
        if media
          "!![#{caption.empty? ? 'Video' : caption}](#{File.join(media_dir, media['url'].to_s)})"
        elsif youtube_playable?(b)
          "!![#{caption.empty? ? 'YT Video' : caption}](#{b['url']})"
        elsif Embed.src(b) || Embed.detect(b['url'].to_s)
          "!![#{caption.empty? ? 'Video' : caption}](#{b['url']})"
        end
      end
    end.join("\n\n")
  end

  # Plain text has to be escaped on the way back, or a `*` or `[` stored in
  # the content would turn into markup on the next edit. The backslash and
  # exclamation mark are only escaped where they'd actually mean something --
  # so `d8-\` and an ordinary "Hi!" stay readable.
  def escape_markdown(raw)
    raw.gsub(/\\(?=[#{Regexp.escape(ESCAPABLE)}])|!(?=\[)|[*`~\[\]]/) { |c| "\\#{c}" }
  end

  # Line-start escaping for rendered prose: a stored paragraph whose line
  # begins with a block sigil must not change block type on the next
  # edit. ">50 % of users" round-tripped into a QUOTE with the ">" eaten;
  # "# tohle je tweet" became a heading; "1990. To byl rok..." a list.
  # Only the first character of a line is at stake, so only it is
  # escaped -- the ordered-list case escapes its dot ("1\. text"),
  # because "\1" means nothing to the parser.
  BLOCK_START_RES = [
    /\A\#{1,6}[ \t]/,        # heading
    /\A>/,                   # quote (the bare ">" swallows the sign)
    /\A[-+][ \t]/,           # unordered list ("*" is escaped globally)
    /\A(?:-{3,}|_{3,})[ \t]*\z/ # horizontal rule
  ].freeze

  def escape_block_starts(rendered)
    rendered.split("\n", -1).map do |line|
      if BLOCK_START_RES.any? { |re| re.match?(line) }
        "\\#{line}"
      elsif (m = line.match(/\A(\d{1,9})([.)])[ \t]/))
        "#{m[1]}\\#{m[2]}#{line[m.end(2)..]}"
      else
        line
      end
    end.join("\n")
  end

  def wrap_markdown(chunk, f)
    case f['type']
    when 'bold' then "**#{chunk}**"
    when 'italic' then "*#{chunk}*"
    when 'strikethrough' then "~~#{chunk}~~"
    when 'code' then "`#{chunk}`"
    when 'link'
      url = link_url_for_markdown(f['url'].to_s)
      f['title'] ? %([#{chunk}](#{url} "#{f['title']}")) : "[#{chunk}](#{url})"
    else chunk
    end
  end

  # The parser's link target reads one level of balanced parentheses --
  # "/Page(ID-123).aspx" round-trips as it is. Anything beyond that
  # (unbalanced, or nested two deep) is percent-encoded, which every
  # server reads as the same address; before this, such a URL was
  # truncated at its first ")" and the tail spilled into the visible
  # text.
  def link_url_for_markdown(url)
    depth = 0
    balanced = url.each_char.all? do |ch|
      depth += 1 if ch == '('
      depth -= 1 if ch == ')'
      depth.between?(0, 1)
    end
    return url if balanced && depth.zero?

    url.gsub('(', '%28').gsub(')', '%29')
  end

  # Renders `text[start...finish]` back to markdown given a (possibly nested/
  # overlapping) list of formatting entries -- the inverse of parse_inline's
  # recursive scan. Containment is a plain start/end comparison; ties
  # (identical range, e.g. bold-wrapping-a-link) are broken by WRAP_PRIORITY
  # so the result is always valid markdown.
  def render_markdown_range(text, entries, start, finish)
    return escape_markdown(text[start...finish]) if entries.empty?

    top = entries.select do |e|
      entries.none? do |o|
        next false if o.equal?(e)

        if o['start'] == e['start'] && o['end'] == e['end']
          WRAP_PRIORITY.fetch(o['type'], 0) > WRAP_PRIORITY.fetch(e['type'], 0)
        else
          o['start'] <= e['start'] && o['end'] >= e['end']
        end
      end
    end
    top.sort_by! { |e| e['start'] }

    result = +''
    pos = start
    top.each do |e|
      result << escape_markdown(text[pos...e['start']]) if e['start'] > pos
      inner = entries.reject { |o| o.equal?(e) }.select { |o| o['start'] >= e['start'] && o['end'] <= e['end'] }
      # A code span's content is literal in markdown -- escaping inside it
      # would put the backslashes on the published page, and a paragraph
      # demonstrating markdown ("`**tučně**`") grew a new layer of
      # backslashes with every edit. Raw, unless the content itself has a
      # backtick, which the fence could not hold.
      wrapped = if e['type'] == 'code' && !text[e['start']...e['end']].include?('`')
                  "`#{text[e['start']...e['end']]}`"
                else
                  wrap_markdown(render_markdown_range(text, inner, e['start'], e['end']), e)
                end
      # escape_markdown escapes "!" only when IT can see the "[" -- and
      # across a segment boundary it cannot: "come!" + "[crew](url)"
      # reassembled into image syntax, which the mid-paragraph guard
      # then rejected, leaving the post uneditable. The join is the only
      # place that knows both halves.
      result.sub!(/(?<!\\)!\z/, '\\!') if wrapped.start_with?('[')
      result << wrapped
      pos = e['end']
    end
    result << escape_markdown(text[pos...finish]) if pos < finish
    result
  end

  def render_text_markdown(text, formatting)
    return escape_markdown(text) if formatting.nil? || formatting.empty?

    render_markdown_range(text, normalize_spans(formatting), 0, text.length)
  end

  # Markdown can say "nested" and it can say "disjoint"; it cannot say
  # "partially overlapping" -- but imported NPF formatting legitimately
  # can (bold 26-40 with italic 26-44). render_markdown_range treated
  # both spans of such a pair as top-level and re-emitted the shared
  # range twice: duplicated words and stray asterisks in the visible
  # text of ~80 real posts, silently, because the block type never
  # changed. So the entries are normalized first: the span that sticks
  # out past its partner is split at the boundary, which renders as the
  # same formatting in two adjacent pieces -- something markdown CAN say.
  STARRED = %w[bold italic strikethrough].freeze

  def normalize_spans(entries)
    spans = entries.map(&:dup)
    # Zero-length spans render as empty syntax -- "[](url)" -- that no
    # parser reads back as a span; imported archives carry them.
    spans.reject! { |f| f['start'].to_i >= f['end'].to_i }
    # Imported formatting carries literal duplicates (the same bold twice
    # over the same range) -- rendering both made "****", which reads
    # back as garbage. One of each is enough.
    spans.uniq! { |f| [f['type'], f['start'], f['end'], f['url']] }
    # Adjacent spans of the same star-delimited type merge: "**A****B**"
    # puts four stars at the junction, and no parser reads that back as
    # two bold runs. One span over both halves renders identically.
    loop do
      pair = nil
      spans.combination(2).each do |a, b|
        a, b = b, a if a['start'] > b['start']
        next unless STARRED.include?(a['type']) && a['type'] == b['type'] && a['end'] == b['start']

        pair = [a, b]
        break
      end
      break unless pair

      a, b = pair
      spans.delete(b)
      a['end'] = b['end']
    end
    loop do
      splittable = nil
      spans.combination(2).each do |a, b|
        a, b = b, a if a['start'] > b['start']
        next unless a['start'] < b['start'] && b['start'] < a['end'] && a['end'] < b['end']

        splittable = [a, b]
        break
      end
      break unless splittable

      a, b = splittable
      spans.delete(b)
      spans << b.merge('start' => b['start'], 'end' => a['end'])
      spans << b.merge('start' => a['end'], 'end' => b['end'])
    end
    spans
  end

  # Renders a (possibly nested) list block back to markdown -- each level of
  # `children` adds two more spaces of indentation, mirroring what
  # parse_list_level expects on the way back in.
  def list_to_markdown(list, indent = 0)
    marker_for = ->(idx) { list['style'] == 'ol' ? "#{idx + 1}." : '-' }
    pad = '  ' * indent
    (list['items'] || []).each_with_index.map do |it, idx|
      task = it.key?('checked') ? (it['checked'] ? '[x] ' : '[ ] ') : ''
      line = "#{pad}#{marker_for.call(idx)} #{task}#{render_text_markdown(it['text'], it['formatting'])}"
      it['children'] ? "#{line}\n#{list_to_markdown(it['children'], indent + 1)}" : line
    end.join("\n")
  end

  def table_to_markdown(block)
    # An unescaped "|" inside a cell would be read as a column break on
    # the way back -- the cell got truncated and the rest of the row
    # silently vanished (7 real posts in one archive).
    cells = lambda { |row| "| #{row.map { |c| render_text_markdown(c['text'], c['formatting']).gsub('|', '\\|') }.join(' | ')} |" }
    separator = (block['align'] || []).map do |a|
      case a
      when 'center' then ':---:'
      when 'right' then '---:'
      else '---'
      end
    end
    [cells.call(block['header']), "| #{separator.join(' | ')} |", *block['rows'].map { |r| cells.call(r) }].join("\n")
  end

  # Only a video we know can actually play survives the round-trip: either a
  # human wrote it (youtube_id present), or an import brought along a working
  # embed. Some imported blocks carry a url but empty embed_html because those
  # videos have since disappeared from YouTube -- if those were converted to
  # !![](url), they'd gain a youtube_id and start rendering as a broken player
  # instead of today's polite notice. Those can't be written back, and
  # manage_post.rb's content-loss safeguard catches it.
  def youtube_playable?(block)
    return false unless block['url'] && MarkdownParser::YOUTUBE_RE.match?(block['url'].to_s)

    !!block['youtube_id'] || block['embed_html'].to_s.strip != ''
  end
end
