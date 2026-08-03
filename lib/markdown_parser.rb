# frozen_string_literal: true

# lib/markdown_parser.rb -- markdown text -> content blocks (the JSON schema
# shared with the Tumblr/Twitter importers and build_blog.rb).
#
# Extracted from scripts/manage_post.rb, where this logic lived as ~270
# lines of top-level functions and couldn't be reused cleanly from anywhere
# else -- build_blog.rb can now render other pages from the same parser too
# (see the markdown cheat sheet page). The opposite direction (blocks ->
# markdown, for `blog.sh edit`) stays in manage_post.rb -- that's purely an
# authoring concern the build never needs.
#
# `resolve_image`/`parse_prose_block`/`parse_body` take `incoming_dir:` as a
# parameter instead of reaching for a global constant -- manage_post.rb
# passes its own INCOMING_DIR (SFTP staging for writing from a phone),
# build_blog.rb leaves it `nil` (pages outside content/posts/ have no local
# images today; if they ever did, the bare-filename shorthand just wouldn't
# be resolvable for them -- only a full path would work).
module MarkdownParser
  module_function

  # --- frontmatter -------------------------------------------------------

  def parse_frontmatter(text)
    return [{}, text] unless text.start_with?("---\n") || text.start_with?("---\r\n")

    _, fm, body = text.split(/^---\s*$/, 3)
    meta = {}
    fm.to_s.each_line do |line|
      line = line.strip
      next if line.empty?

      key, val = line.split(':', 2)
      meta[key.strip] = val.to_s.strip
    end
    [meta, body.to_s.sub(/\A\r?\n+/, '')]
  end

  # --- inline formatting ---------------------------------------------------

  # Alternation order matters: escape must come first, so `\*` never opens
  # italics. A link also accepts an optional quoted title -- without this
  # the title used to get shoved into the address and the link ended up dead.
  INLINE_RE = /\\([*`~\[\]!\\])|\*\*(.+?)\*\*|\*(.+?)\*|~~(.+?)~~|`([^`]+?)`|\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/m

  # Rewrites markdown inline spans (bold/italic/strikethrough/code/link) into
  # (plain_text, formatting[]) with codepoint offsets into plain_text -- same
  # shape as the NPF formatting array the Tumblr/Twitter migrations already
  # produce.
  #
  # Bold/italic/strikethrough content is re-scanned recursively so a link
  # inside them (e.g. "**[example.com](url)**") still becomes a real link,
  # not literal "[example.com](url)" text -- the outer span and the
  # recursively-found inner span(s) end up as separate, possibly identical-
  # range, entries in the flat `formatting` list; build_blog.rb's
  # apply_formatting already renders overlapping/nested entries correctly
  # (innermost-first by span length). Inline code is the one exception --
  # its content is taken literally, same as standard Markdown, so
  # `` `**not bold**` `` stays literal asterisks instead of becoming bold.
  def parse_inline(text)
    result = +''
    formatting = []
    pos = 0
    text.scan(INLINE_RE) do |escaped, bold, italic, strike, code, link_text, link_url, link_title|
      m = Regexp.last_match
      result << text[pos...m.begin(0)]
      start = result.length
      if escaped
        result << escaped
      elsif bold
        inner_text, inner_formatting = parse_inline(bold)
        result << inner_text
        formatting << { 'type' => 'bold', 'start' => start, 'end' => result.length }
        formatting.concat(shift_formatting(inner_formatting, start))
      elsif italic
        inner_text, inner_formatting = parse_inline(italic)
        result << inner_text
        formatting << { 'type' => 'italic', 'start' => start, 'end' => result.length }
        formatting.concat(shift_formatting(inner_formatting, start))
      elsif strike
        inner_text, inner_formatting = parse_inline(strike)
        result << inner_text
        formatting << { 'type' => 'strikethrough', 'start' => start, 'end' => result.length }
        formatting.concat(shift_formatting(inner_formatting, start))
      elsif code
        result << code
        formatting << { 'type' => 'code', 'start' => start, 'end' => result.length }
      elsif link_text
        inner_text, inner_formatting = parse_inline(link_text)
        result << inner_text
        entry = { 'type' => 'link', 'url' => link_url, 'start' => start, 'end' => result.length }
        entry['title'] = link_title if link_title && !link_title.empty?
        formatting << entry
        formatting.concat(shift_formatting(inner_formatting, start))
      end
      pos = m.end(0)
    end
    result << text[pos..]
    [result, formatting]
  end

  def shift_formatting(formatting, offset)
    formatting.map { |f| f.merge('start' => f['start'] + offset, 'end' => f['end'] + offset) }
  end

  # --- block-level regexes -------------------------------------------------

  IMAGE_RE = /\A!\[([^\]]*)\]\(([^)"]+?)(?:\s+"([^"]*)")?\)\z/
  # Two exclamation marks = video, whether a local file or YouTube.
  # Deliberately explicit: a bare address on its own line stays a plain
  # paragraph, so a video can also just be linked to instead of every link
  # turning itself into a player.
  # The caption is .* rather than [^\]]*, since it can itself contain square
  # brackets -- imported videos can have captions like [Video] or [YT Video].
  # The greedy match stops at the last "](" before the address, so the
  # caption doesn't get cut short.
  VIDEO_RE = /\A!!\[(.*)\]\(([^)"]+?)\)\z/
  HEADING_RE = /\A(\#{1,6})\s+(.+)\z/
  HR_RE = /\A(?:-{3,}|_{3,}|\*[ \t]*\*[ \t]*\*[ \t*]*)\z/
  UL_ITEM_RE = /\A[-*]\s+(.+)\z/
  OL_ITEM_RE = /\A\d+[.)]\s+(.+)\z/
  BLOCKQUOTE_LINE_RE = /\A>[ \t]?(.*)\z/
  TABLE_SEPARATOR_RE = /\A\|?[\s:|-]*-[\s:|-]*\|?\z/
  VIDEO_EXTENSIONS = %w[.mp4 .mov .m4v].freeze
  AUDIO_EXTENSIONS = %w[.mp3 .m4a .ogg .opus .aac .flac .wav].freeze

  # Attachments a post can hand over for download. A whitelist rather than
  # "anything with a dot": a link line is overwhelmingly a link, and only
  # an extension the site actually publishes should silently turn into an
  # uploaded file. Office formats can join later; nothing here needs the
  # engine to understand the format, only to carry it.
  # No .gz: File.extname sees only the last suffix, so a .tar.gz would be
  # stored and served as NN.gz and unpack to a name without its .tar. .tgz
  # says the same thing in one extension and survives the round trip.
  FILE_EXTENSIONS = %w[.pdf .zip .tgz .epub .txt .md .ics .gpx .csv].freeze

  # A link line whose target is a bare filename with a known extension is
  # an attachment, exactly like a bare filename in an image line. A URL is
  # always just a link -- the engine can only publish files it is given.
  # Same shape as IMAGE_RE, including the optional quoted title: a target
  # may contain spaces, because `edit` round-trips the block as a full
  # path -- and a repo can live under "Mobile Documents". A link that
  # HAS a title stays a link, though (see the file branch): a title is a
  # link's affordance, an attachment has nowhere to put it, and turning
  # one into an upload would both discard the title and demand a file
  # the author never meant to publish.
  LINK_LINE_RE = /\A\[([^\]]*)\]\(([^)"]+?)(?:\s+"([^"]*)")?\)\z/

  # A private-use character standing in for a hard break while the paragraph
  # goes through parse_inline -- it's one codepoint, so swapping it back for
  # a real newline afterwards leaves every formatting offset intact.
  BREAK_SENTINEL = "\uE000"

  # A backslash at the end of a line is a hard break (rendered <br>); any
  # other newline inside a paragraph is prose wrapping and collapses to a
  # space, exactly as the cheat sheet always promised. Escaped \\ stays a
  # literal backslash. Storage-wise a break is simply a newline kept in the
  # block's text -- the same shape multiline imports already have.
  def collapse_soft_breaks(para)
    # Spaces before the marker are eaten here, before parse_inline computes
    # formatting offsets -- trimming them afterwards would shift every span
    # that crosses the break.
    para.gsub(/ *(?<!\\)\\\n/, BREAK_SENTINEL).tr("\n", ' ')
  end
  YOUTUBE_RE = %r{\Ahttps?://(?:www\.)?(?:youtube\.com/watch\?(?:[^\s]*&)?v=|youtu\.be/|youtube\.com/shorts/)([\w-]{6,})}

  def video_path?(path)
    VIDEO_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  def audio_path?(path)
    AUDIO_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  # An attachment is a bare filename (the incoming/ shorthand) or a path
  # inside the post's own media directory (what `edit` writes back). A
  # relative path to anywhere else stays a link: an existing post whose
  # paragraph happens to be `[Data](stats/2025.csv)` must not turn itself
  # into an upload on re-save. Any URL -- including the protocol-relative
  # //host/x.pdf -- is a link too; the engine can only publish files it
  # was handed.
  def file_line?(path, media_dir = nil)
    name = path.to_s
    return false if name.match?(%r{\A(?:[a-z][a-z0-9+.-]*:)?//}i)
    return false unless FILE_EXTENSIONS.include?(File.extname(name).downcase)
    return true if File.dirname(name) == '.'

    media_dir && File.expand_path(name).start_with?("#{File.expand_path(media_dir)}/")
  end

  # --- tables ---------------------------------------------------------------

  # A GFM-style table: first line is the header, second is a dash separator,
  # the rest is data. Alignment comes from colons in the separator (:---
  # left, ---: right, :---: center).
  def split_table_row(line)
    line.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|').map(&:strip)
  end

  def parse_table(para)
    lines = para.split("\n").map(&:strip).reject(&:empty?)
    return nil if lines.size < 2
    return nil unless lines[0].include?('|')
    return nil unless lines[1].include?('-') && TABLE_SEPARATOR_RE.match?(lines[1])

    header = split_table_row(lines[0])
    align = split_table_row(lines[1]).map do |spec|
      left = spec.start_with?(':')
      right = spec.end_with?(':')
      if left && right then 'center'
      elsif right then 'right'
      else 'left'
      end
    end
    return nil if header.empty? || align.size != header.size

    cell = lambda do |raw|
      text, formatting = parse_inline(raw)
      formatting.empty? ? { 'text' => text } : { 'text' => text, 'formatting' => formatting }
    end

    rows = lines.drop(2).map do |line|
      values = split_table_row(line)
      # Missing cells are padded with empty ones, extra ones are discarded --
      # so a short or stray row doesn't break the whole table.
      Array.new(header.size) { |i| cell.call(values[i].to_s) }
    end

    { 'type' => 'table', 'align' => align, 'header' => header.map { |h| cell.call(h) }, 'rows' => rows }
  end

  # --- blockquote -------------------------------------------------------

  # A paragraph is a blockquote block when every one of its (non-blank) lines
  # starts with ">" -- the marker is stripped from each line and the rest is
  # rejoined with newlines before being parsed as regular inline text.
  def parse_blockquote(para)
    lines = para.split("\n")
    return nil unless lines.all? { |l| l.strip.empty? || BLOCKQUOTE_LINE_RE.match?(l.strip) }
    return nil unless lines.any? { |l| BLOCKQUOTE_LINE_RE.match?(l.strip) }

    quoted_lines = lines.map { |l| l.strip.empty? ? '' : BLOCKQUOTE_LINE_RE.match(l.strip)[1] }

    # A last line opening with an em dash (or "--") is the attribution --
    # "> Quote\n> — Author", the Tumblr quote-post shape. Only when
    # something precedes it: a one-line quote that merely starts with a
    # dash is still a quote, not an empty quote with an author.
    cite = nil
    if quoted_lines.size > 1 && (m = /\A(?:—|--)\s+(.+)\z/.match(quoted_lines.last.strip))
      cite = m[1].strip
      quoted_lines.pop
      quoted_lines.pop while quoted_lines.last.to_s.empty?
    end

    text, formatting = parse_inline(quoted_lines.join("\n"))
    block = { 'type' => 'text', 'subtype' => 'quote', 'text' => text }
    block['formatting'] = formatting unless formatting.empty?
    block['cite'] = cite if cite
    block
  end

  # --- lists ---------------------------------------------------------------

  # Parses one nesting level of a list starting at `lines[idx]`, where every
  # line belonging to this level has exactly `indent` leading spaces (deeper
  # indentation opens a nested list attached to the preceding item; shallower
  # indentation, a different marker style at the same indent, or a non-list
  # line ends this level). Returns [list_block, next_idx], or nil if the line
  # at idx isn't a list item at all.
  def parse_list_level(lines, idx, indent)
    return nil if idx >= lines.length

    line = lines[idx]
    return nil if line[/\A */].size != indent

    style = if UL_ITEM_RE.match?(line.strip)
              'ul'
            elsif OL_ITEM_RE.match?(line.strip)
              'ol'
            end
    return nil unless style

    item_re = style == 'ul' ? UL_ITEM_RE : OL_ITEM_RE
    items = []

    while idx < lines.length
      line = lines[idx]
      cur_indent = line[/\A */].size
      break if cur_indent < indent

      if cur_indent > indent
        nested, idx = parse_list_level(lines, idx, cur_indent)
        break unless nested && items.any?

        items.last['children'] = nested
        next
      end

      m = item_re.match(line.strip)
      break unless m

      body = m[1]
      # "- [ ] task" / "- [x] done" -- the marker is consumed here, so the
      # stored text is just the task, and `checked` carries the state.
      checked = nil
      if (task = /\A\[([ xX])\]\s+(.*)\z/.match(body))
        checked = task[1] != ' '
        body = task[2]
      end
      text, formatting = parse_inline(body)
      item = { 'text' => text }
      item['formatting'] = formatting unless formatting.empty?
      item['checked'] = checked unless checked.nil?
      items << item
      idx += 1
    end

    [{ 'type' => 'list', 'style' => style, 'items' => items }, idx]
  end

  # A paragraph is a list block when its first line is a list item; nested
  # (deeper-indented) lines become sub-lists attached to the preceding item.
  # If any line is left over once the top level's items are exhausted, the
  # whole paragraph is rejected and falls through to a plain text block --
  # same "must be a clean, fully-consistent list" rule as before.
  def parse_list(para)
    lines = para.split("\n").reject { |l| l.strip.empty? }
    return nil if lines.empty?

    result, idx = parse_list_level(lines, 0, 0)
    return nil unless result && idx == lines.length

    result
  end

  # --- images/video ----------------------------------------------------

  # Resolves an image markdown path to a (filename, source_path_to_copy) pair.
  # If the path already points inside media_dir (i.e. it's an existing post's
  # own image, unchanged during edit), no copy is needed.
  #
  # Doesn't require the source file to exist yet -- publishing away from the
  # Mac (SSH from iPad/iPhone) means the photo may still be in transit via SFTP
  # into incoming/ when the post is written; parse_body/wait_for_missing_images
  # (manage_post.rb) handle waiting for it to actually show up before anything
  # gets copied.
  def resolve_image(path, media_dir, counter, media_files = {}, incoming_dir: nil)
    expanded = File.expand_path(path)
    if media_dir && expanded.start_with?("#{File.expand_path(media_dir)}/")
      return [File.basename(expanded), nil]
    end

    # A bare filename (no directory component) is looked up in two places, in
    # this order:
    #
    # 1. the post's own media directory -- on a second edit of a post whose
    #    photos were staged this way, the file is already there from the
    #    previous save (and its incoming/ copy was cleaned up), so it resolves
    #    with no copy at all instead of waiting for an upload that will never
    #    come;
    # 2. incoming_dir -- the write-before-upload shorthand, which lets a
    #    phone-typed markdown line stay short instead of spelling out a full
    #    path like <repo>/incoming/foto.jpg every time.
    #
    # A name in neither place still resolves to incoming_dir, so it's that
    # path the author is told to upload to. Without an incoming_dir (e.g.
    # build-time pages outside content/posts/), a bare filename just resolves
    # relative to the current directory instead.
    if File.dirname(path) == '.'
      in_media = media_dir && File.expand_path(File.join(media_dir, path))
      return [File.basename(in_media), nil] if in_media && File.exist?(in_media)

      expanded = File.expand_path(File.join(incoming_dir, path)) if incoming_dir
    end

    # If the post has already referenced this source once, reuse the same
    # filename. media_files is keyed by source path, so a second reference
    # to the same file would otherwise overwrite the first and one of the
    # copies would never happen -- leaving a block pointing at a
    # nonexistent file.
    existing = media_files[expanded]
    return [existing, nil] if existing

    ext = File.extname(expanded)
    ext = '.jpg' if ext.empty?
    [free_media_name(counter, ext, media_dir, media_files.values), expanded]
  end

  # Picks the first NN<ext> name nothing else is using: not one this parse has
  # already handed out, and not a number the post's media directory already
  # holds under any extension.
  #
  # The numbering only ever counted files being *copied*, so an image the post
  # keeps from a previous save didn't consume its number -- an edit that kept
  # 01.png and added another PNG named the new file 01.png as well, the copy
  # overwrote the kept one, and both blocks ended up showing the new image.
  # Skipping numbers that are already on disk fixes that in both directions
  # (the kept image can appear in any block, before or after the new one).
  # A brand-new post has no media directory yet, so nothing is skipped there
  # and its images stay numbered 01, 02, 03...
  def free_media_name(counter, ext, media_dir, taken)
    used = taken.dup
    used.concat(Dir.children(media_dir)) if media_dir && Dir.exist?(media_dir)
    stems = used.map { |name| File.basename(name.to_s, '.*') }

    number = counter
    number += 1 while stems.include?(format('%02d', number))
    format('%02d%s', number, ext)
  end

  CODE_FENCE_LINE_RE = /\A```(\S*)\z/

  # Splits raw body text into alternating :prose / :code segments on lines of
  # exactly ``` (optionally followed by a language hint, e.g. ```ruby). A code
  # segment's own text is never touched by the blank-line paragraph splitter
  # below -- code needs its internal blank lines preserved verbatim, and none
  # of its content should ever go through parse_inline (no bold/italic/link
  # interpretation inside source code). An unterminated fence (no closing ```
  # before the body ends) is still treated as code through to the end, rather
  # than silently reverting to prose.
  # "Name: what they said" per line, Tumblr chat-post style. A line
  # without a colon is a continuation of the previous line (kept with a
  # newline -- rendered as a break); a leading continuation with nobody to
  # attach to becomes a nameless line. Returns nil for an empty fence.
  def parse_chat(text)
    lines = []
    text.split("\n").each do |raw|
      line = raw.rstrip
      next if line.strip.empty?

      if (m = /\A([^:]{1,60}):\s+(.*)\z/.match(line))
        lines << { 'name' => m[1].strip, 'text' => m[2] }
      elsif lines.any?
        lines.last['text'] = "#{lines.last['text']}\n#{line.strip}"
      else
        lines << { 'name' => nil, 'text' => line.strip }
      end
    end
    return nil if lines.empty?

    { 'type' => 'chat', 'lines' => lines }
  end

  def split_code_fences(body)
    segments = []
    lines = body.split("\n")
    buffer = []
    i = 0

    while i < lines.length
      m = CODE_FENCE_LINE_RE.match(lines[i].strip)
      unless m
        buffer << lines[i]
        i += 1
        next
      end

      segments << { type: :prose, text: buffer.join("\n") } unless buffer.empty?
      buffer = []
      lang = m[1]
      i += 1
      code_lines = []
      while i < lines.length && lines[i].strip != '```'
        code_lines << lines[i]
        i += 1
      end
      segments << { type: :code, lang: lang, text: code_lines.join("\n") }
      i += 1 # skip the closing ``` (or, if unterminated, i == lines.length already)
    end

    segments << { type: :prose, text: buffer.join("\n") } unless buffer.empty?
    segments
  end

  def parse_prose_block(para, media_dir, media_files, counter, incoming_dir: nil)
    if (m = VIDEO_RE.match(para))
      caption, target = m[1].strip, m[2].strip
      abort "Video needs a caption: !![caption](#{target})" if caption.empty?

      # Same !! marker, told apart by extension -- a third sigil would be one
      # more thing to remember for what is the same gesture: "embed this
      # media file with a caption".
      if audio_path?(target)
        counter += 1
        filename, src = resolve_image(target, media_dir, counter, media_files, incoming_dir: incoming_dir)
        media_files[src] = filename if src
        counter -= 1 unless src
        return [{ 'type' => 'audio', 'media' => [{ 'url' => filename }], 'caption' => caption }, counter]
      end

      if (yt = YOUTUBE_RE.match(target))
        # Stores url + youtube_id, the renderer builds the iframe -- so no
        # foreign HTML ends up in the data (an imported embed_html can carry
        # its own tracking along with it).
        return [{ 'type' => 'video', 'provider' => 'youtube', 'url' => target,
                  'youtube_id' => yt[1], 'caption' => caption }, counter]
      end

      counter += 1
      filename, src = resolve_image(target, media_dir, counter, media_files, incoming_dir: incoming_dir)
      media_files[src] = filename if src
      counter -= 1 unless src # filename was recycled, the number wasn't consumed
      return [{ 'type' => 'video', 'media' => [{ 'url' => filename }], 'caption' => caption }, counter]
    elsif (m = IMAGE_RE.match(para))
      counter += 1
      alt, path, caption = m[1], m[2], m[3]
      # A single exclamation mark is for images only. A video with just one
      # would render as a broken <img>, so this warns about it rather than
      # letting it pass silently.
      warn "Note: #{File.basename(path)} looks like a video but is written as an image. For a video, use !![caption](#{path})." if video_path?(path)
      filename, src = resolve_image(path, media_dir, counter, media_files, incoming_dir: incoming_dir)
      media_files[src] = filename if src
      counter -= 1 unless src
      return [{ 'type' => 'image', 'media' => [{ 'url' => filename }], 'alt_text' => (alt.empty? ? nil : alt), 'caption' => caption }.compact, counter]
    elsif (m = LINK_LINE_RE.match(para)) && m[3].nil? && file_line?(m[2], media_dir)
      # A whole line that is just [label](file.pdf) with a bare filename:
      # the file travels with the post like a photo does, and the block
      # carries its size so the page can say what a click costs. The label
      # falls back to the filename -- an attachment with no words is still
      # better than a link reading "download".
      counter += 1
      label, target = m[1].strip, m[2].strip
      filename, src = resolve_image(target, media_dir, counter, media_files, incoming_dir: incoming_dir)
      media_files[src] = filename if src
      counter -= 1 unless src
      file = { 'url' => filename }
      # Three places the bytes can be, in order: the file being copied in
      # now, a source an earlier block in this same post already
      # registered (a post referencing one attachment twice priced only
      # the first card without this), and finally the post's own media
      # directory -- which is where a round-tripped edit finds it, and
      # without which every edit silently dropped the size from the card
      # for good, since nothing else ever writes it back.
      source = src || media_files.key(filename) ||
               (media_dir && File.join(media_dir, filename))
      size = (File.size(source) if source && File.exist?(source)) rescue nil
      file['size'] = size if size&.positive?
      return [{ 'type' => 'file', 'media' => [file],
                'label' => (label.empty? ? File.basename(target) : label) }, counter]
    elsif para.match?(/(?<!\\)!\[[^\]]*\]\([^)]+\)/)
      # An image in the middle of a paragraph can't be rendered -- the
      # schema only knows image blocks. This used to silently turn into a
      # link to the file plus a stray exclamation mark.
      abort "Both images and videos must be on their own line, separated by blank lines. The problem is here:\n#{para}"
    elsif !para.include?("\n") && HR_RE.match?(para)
      return [{ 'type' => 'hr' }, counter]
    elsif !para.include?("\n") && (m = HEADING_RE.match(para))
      text, formatting = parse_inline(m[2])
      block = { 'type' => 'text', 'subtype' => "heading#{m[1].length}", 'text' => text }
      block['formatting'] = formatting unless formatting.empty?
      return [block, counter]
    elsif (table = parse_table(para))
      return [table, counter]
    elsif (quote = parse_blockquote(para))
      return [quote, counter]
    elsif (list = parse_list(para))
      return [list, counter]
    else
      text, formatting = parse_inline(collapse_soft_breaks(para))
      block = { 'type' => 'text', 'text' => text.gsub(BREAK_SENTINEL, "\n") }
      block['formatting'] = formatting unless formatting.empty?
      return [block, counter]
    end
  end

  def parse_body(body, media_dir, incoming_dir: nil)
    blocks = []
    media_files = {}
    counter = 0

    split_code_fences(body).each do |segment|
      if segment[:type] == :code
        # The chat fence rides the code-fence rails on purpose: a fence is
        # verbatim, so speaker lines can hold colons, asterisks or anything
        # else without inline parsing, and the round-trip is the fence
        # itself. "Name: line" per line; a line without a colon continues
        # the previous speaker's line.
        if segment[:lang] == 'chat'
          chat = parse_chat(segment[:text])
          blocks << chat if chat
          next
        end
        block = { 'type' => 'code', 'text' => segment[:text] }
        block['lang'] = segment[:lang] unless segment[:lang].to_s.empty?
        blocks << block
        next
      end

      segment[:text].split(/\n\s*\n/).map(&:strip).reject(&:empty?).each do |para|
        block, counter = parse_prose_block(para, media_dir, media_files, counter, incoming_dir: incoming_dir)
        blocks << block
      end
    end

    missing = media_files.keys.reject { |src| File.exist?(src) }
    [blocks, media_files, missing]
  end
end
