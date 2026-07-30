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
  # would get mangled.
  ESCAPABLE = '*`~[]!\\'

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
        when 'quote' then rendered.split("\n").map { |l| l.empty? ? '>' : "> #{l}" }.join("\n")
        else rendered
        end
      when 'table'
        table_to_markdown(b)
      when 'list'
        list_to_markdown(b)
      when 'hr'
        '---'
      when 'code'
        "```#{b['lang']}\n#{b['text']}\n```"
      when 'image'
        media = (b['media'] || []).first || {}
        path = File.join(media_dir, media['url'].to_s)
        cap = b['caption'] ? %( "#{b['caption']}") : ''
        "![#{b['alt_text']}](#{path}#{cap})"
      when 'audio'
        # Mirrors the video branch: a local file writes back as !![](file);
        # an imported embed-only audio (a Spotify iframe, say) has no
        # markdown form and is dropped here -- the CLI's content-loss
        # safeguard counts it before anything is saved.
        media = (b['media'] || []).first
        caption = b['caption'].to_s.strip
        "!![#{caption.empty? ? 'Audio' : caption}](#{File.join(media_dir, media['url'].to_s)})" if media
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

  def wrap_markdown(chunk, f)
    case f['type']
    when 'bold' then "**#{chunk}**"
    when 'italic' then "*#{chunk}*"
    when 'strikethrough' then "~~#{chunk}~~"
    when 'code' then "`#{chunk}`"
    when 'link' then f['title'] ? %([#{chunk}](#{f['url']} "#{f['title']}")) : "[#{chunk}](#{f['url']})"
    else chunk
    end
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
      result << wrap_markdown(render_markdown_range(text, inner, e['start'], e['end']), e)
      pos = e['end']
    end
    result << escape_markdown(text[pos...finish]) if pos < finish
    result
  end

  def render_text_markdown(text, formatting)
    return escape_markdown(text) if formatting.nil? || formatting.empty?

    render_markdown_range(text, formatting, 0, text.length)
  end

  # Renders a (possibly nested) list block back to markdown -- each level of
  # `children` adds two more spaces of indentation, mirroring what
  # parse_list_level expects on the way back in.
  def list_to_markdown(list, indent = 0)
    marker_for = ->(idx) { list['style'] == 'ol' ? "#{idx + 1}." : '-' }
    pad = '  ' * indent
    (list['items'] || []).each_with_index.map do |it, idx|
      line = "#{pad}#{marker_for.call(idx)} #{render_text_markdown(it['text'], it['formatting'])}"
      it['children'] ? "#{line}\n#{list_to_markdown(it['children'], indent + 1)}" : line
    end.join("\n")
  end

  def table_to_markdown(block)
    cells = lambda { |row| "| #{row.map { |c| render_text_markdown(c['text'], c['formatting']) }.join(' | ')} |" }
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
