# frozen_string_literal: true

require_relative 'embed'

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
  # The escape class and the writer's ESCAPABLE change together: every
  # character the writer may put a backslash before must lose it here, or
  # the backslash becomes visible text on the next edit. ")" is in the
  # class for exactly that reason and is NOT in ESCAPABLE: the writer only
  # ever escapes it at the start of a line, where "1) first" would
  # otherwise round-trip into an ordered list -- but the backslash it
  # wrote had no way back out, so imported "1) ... 2) ..." enumerations
  # published a visible "1\)" the moment anything else in the post was
  # edited. The block sigils
  # (# > - + . _ |) joined for the writer's line-start escaping -- a
  # paragraph beginning ">50 %" must not round-trip into a quote.
  #
  # The link target allows one level of balanced parentheses
  # ("/Page(ID-123).aspx"), matching what CommonMark does; the writer
  # percent-encodes the pathological rest.
  #
  # The label may be EMPTY -- "[](url)" is a real shape, not a typo.
  # Converters out of WordPress write the anchor they once put in a
  # heading that way, and one 74-post Hugo tree had 161 of them across
  # 14 posts. Required to have a character, the whole thing missed and
  # the reader was shown the brackets and the address in the heading;
  # what parse_inline does with the match instead is written there.
  # Six extra alternatives carry the star collisions the writer
  # legitimately produces when bold and italic meet. A run of stars is
  # not one delimiter: three of them between two letters can close one
  # span and open another, which is what CommonMark's delimiter runs say
  # and what an author means. The shapes are "***both***",
  # "***head*rest**" (italic on the head of a bold span),
  # "***head**rest*" (bold on the head of an italic one),
  # "**pre*tail***" (italic on its tail), "**bold***italic*" --
  # adjacency, the middle run splitting two-plus-one -- and its mirror
  # "*italic***bold**", splitting one-plus-two.
  # The collision shapes use a tempered dot -- (?:(?!\*\*).) -- so their
  # halves can never reach ACROSS an ordinary bold boundary to a "***"
  # further down the paragraph; without it, "**A** ... ***x***" read as
  # one giant span from A to x. The head shapes' REST halves and btail
  # are tighter still: a rest may hold complete nested runs ("**x**"
  # inside an italic's rest, "*x*" inside a bold's) but never a lone
  # star, and btail no stars at all -- a lone star there is always a
  # closer being stolen from a span further right, which surfaced as
  # stray asterisks in the text. Plain italic refuses a closer that
  # touches other stars for the same reason: the star before "**de**"
  # inside "*ab~~c**de**f~~ghij*" is bold's opener, not italic's closer.
  #
  # Alternative order is load-bearing, in both directions. Plain bold --
  # whose closer is exactly two stars, the (?!\*) guard -- comes BEFORE
  # the tail-collision shapes, or "**F** dál ... ***v***" reads as one
  # span from F to v. The adjacency shapes come AFTER them, immediately
  # before plain italic: placed any earlier they take matches that
  # belong to the tail collisions, and partially overlapping spans --
  # what every NPF import produces -- come back with stray asterisks in
  # the text. They may only have what nothing else can read.
  # tests/test_markdown_roundtrip.rb walks all 1085 assignments of up to
  # three spans -- permutations and repeated types included; that matrix
  # is what these positions were settled against, and what will notice
  # if they move.
  INLINE_RE = /\\(?<esc>[*`~\[\]!\\#>|.+_)-])|\*\*\*(?<bi>(?:(?!\*\*)[^*])+?)\*\*\*|\*\*\*(?<ihead>(?:(?!\*\*).)+?)\*(?!\*)(?<irest>(?:[^*]|\*[^*]+?\*)*?)\*\*|\*\*\*(?<bhead>(?:(?!\*\*).)+?)\*\*(?<brest>(?:[^*]|\*\*(?:(?!\*\*).)+?\*\*)*?)\*(?!\*)|\*\*(?<bold>(?:\\.|(?!\*\*).)+?)\*\*(?!\*)|\*\*(?<bpre>(?:(?!\*\*).)*?)\*(?<itail>(?:(?!\*\*).)+?)\*\*\*|\*(?<ipre>[^*]*?)\*\*(?<btail>(?:\\.|[^*])+?)\*\*\*|\*\*(?<badj>(?:(?!\*\*).)+?)\*\*\*(?<iadj>(?:(?!\*\*).)+?)\*(?:(?!\*)|(?=\*\*))|\*(?<ileft>(?:[^*]|\*\*(?:(?!\*\*).)+?\*\*)+?)\*\*\*(?<bright>(?:(?!\*\*).)+?)\*\*(?:(?!\*)|(?=\*[^*]))|\*(?<italic>.+?)(?<!\\)(?<!(?<!\\)\*)\*(?!\*)|~~(?<strike>.+?)(?<!\\)~~|(?<fence>`+)(?<code>.+?)\k<fence>|\[(?<ltext>(?:\\.|[^\]\\])*)\]\((?<lurl>(?:\([^()\s]*\)|[^)\s])+)(?:\s+"(?<ltitle>(?:\\.|[^"\\])*)")?\)/m

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
    while (m = INLINE_RE.match(text, pos))
      result << text[pos...m.begin(0)]
      start = result.length
      if m[:esc]
        result << m[:esc]
      elsif m[:bi]
        append_span(result, formatting, m[:bi], 'italic', start)
        formatting << { 'type' => 'bold', 'start' => start, 'end' => result.length }
      elsif m[:ihead]
        # bold across both parts, italic on the head only.
        append_span(result, formatting, m[:ihead], 'italic', start)
        append_plain(result, formatting, m[:irest])
        formatting << { 'type' => 'bold', 'start' => start, 'end' => result.length }
      elsif m[:bhead]
        # italic across both parts, bold on the head only.
        append_span(result, formatting, m[:bhead], 'bold', start)
        append_plain(result, formatting, m[:brest])
        formatting << { 'type' => 'italic', 'start' => start, 'end' => result.length }
      elsif m[:itail]
        append_plain(result, formatting, m[:bpre])
        append_span(result, formatting, m[:itail], 'italic', result.length)
        formatting << { 'type' => 'bold', 'start' => start, 'end' => result.length }
      elsif m[:btail]
        append_plain(result, formatting, m[:ipre])
        append_span(result, formatting, m[:btail], 'bold', result.length)
        formatting << { 'type' => 'italic', 'start' => start, 'end' => result.length }
      elsif m[:bold]
        append_span(result, formatting, m[:bold], 'bold', start)
      elsif m[:badj]
        # A bold span ending exactly where an italic one begins: the writer
        # renders that as "**abcd***efgh*", and the run of three stars in
        # the middle splits 2 + 1 -- the closer for the bold, the opener
        # for the italic. Plain bold cannot take it (its closer is exactly
        # two stars, the (?!\*) guard), so without this shape the whole
        # paragraph fell through to plain italic and came back with stray
        # asterisks in the visible text. Matches what CommonMark's
        # delimiter runs do with the same bytes.
        append_span(result, formatting, m[:badj], 'bold', start)
        append_span(result, formatting, m[:iadj], 'italic', result.length)
      elsif m[:ileft]
        # The mirror image: "*italic***bold**", the middle run splitting
        # one-plus-one-plus-one... no -- one for the italic's closer, two
        # for the bold's opener. Same delimiter-run arithmetic as badj,
        # read from the other side.
        append_span(result, formatting, m[:ileft], 'italic', start)
        append_span(result, formatting, m[:bright], 'bold', result.length)
      elsif m[:italic]
        append_span(result, formatting, m[:italic], 'italic', start)
      elsif m[:strike]
        append_span(result, formatting, m[:strike], 'strikethrough', start)
      elsif m[:code]
        # A fence of however many backticks it takes, not always one: a
        # code span whose content HAS a backtick can only be written that
        # way -- markdown honours no escapes inside a span, so the writer's
        # backslash used to come back as visible text with the span cut
        # short at the inner backtick. The writer emits the long fence
        # (see MarkdownWriter#code_span); this is the other half.
        #
        # One leading and one trailing space are dropped, which is
        # markdown's own rule and what lets a span start or end with a
        # backtick at all.
        code = m[:code]
        code = code[1..-2] if code.length > 2 && code.start_with?(' ') && code.end_with?(' ')
        result << code
        formatting << { 'type' => 'code', 'start' => start, 'end' => result.length }
      elsif m[:ltext]
        # A label-less link is consumed and NOTHING is put in its place.
        # It has no reading that helps anybody: there is no text to click,
        # a screen reader announces a link and then falls silent, and
        # putting the address in as the label would print a github.com URL
        # in the middle of a heading -- and into the anchor id derived from
        # that heading, so the article's own table of contents would point
        # at "#https-github-com-...". Dropping it costs a link nobody could
        # follow; keeping it costs every heading it sits in.
        unless m[:ltext].empty?
          inner_text, inner_formatting = parse_inline(m[:ltext])
          result << inner_text
          entry = { 'type' => 'link', 'url' => m[:lurl], 'start' => start, 'end' => result.length }
          entry['title'] = unescape_title(m[:ltitle]) if m[:ltitle] && !m[:ltitle].empty?
          formatting << entry
          formatting.concat(shift_formatting(inner_formatting, start))
        end
      end
      pos = m.end(0)
    end
    result << text[pos..]
    [result, formatting]
  end

  # Recursively parses `chunk`, appends its text to result and wraps it
  # in one formatting entry of `type`.
  def append_span(result, formatting, chunk, type, start)
    inner_text, inner_formatting = parse_inline(chunk)
    result << inner_text
    formatting << { 'type' => type, 'start' => start, 'end' => result.length }
    formatting.concat(shift_formatting(inner_formatting, start))
  end

  # The same, without a wrapping entry of its own.
  def append_plain(result, formatting, chunk)
    return if chunk.to_s.empty?

    start = result.length
    inner_text, inner_formatting = parse_inline(chunk)
    result << inner_text
    formatting.concat(shift_formatting(inner_formatting, start))
  end

  def shift_formatting(formatting, offset)
    formatting.map { |f| f.merge('start' => f['start'] + offset, 'end' => f['end'] + offset) }
  end

  # --- block-level regexes -------------------------------------------------

  # The alt text is read up to the FIRST "](", not up to the first "]".
  # Titles carry brackets -- "[es] W-ZERO3" is a real post's picture -- and
  # a line the parser cannot read comes back as a paragraph of literal
  # markdown: the image block is gone, its file is pruned as unreferenced
  # a moment later, and the page then shows the author's absolute disk path
  # as text. VIDEO_RE has always been written this way; this one was not.
  IMAGE_RE = /\A!\[(.*?)\]\(([^)"]+?)(?:\s+"((?:\\.|[^"\\])*)")?\)\z/
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
  # Where the teaser ends: everything above this line is the post's own
  # invitation, everything below is the body. Deliberately NOT a horizontal
  # rule, which would have been the obvious reading of "put a divider there":
  # rules are already in use as rules, and their first one usually sits deep
  # in the post -- eleven posts across the three sites the engine runs, with
  # first rules at block 17, 19, 27 and 36 -- so "the first rule ends the
  # teaser" would have silently handed those a teaser half a page long.
  # Strict on purpose: a looser pattern would let an ordinary note like
  # "// more below //" split somebody's post without saying so.
  TEASER_END_RE = %r{\A//--more--//\z}
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
  LINK_LINE_RE = /\A\[([^\]]*)\]\(([^)"]+?)(?:\s+"((?:\\.|[^"\\])*)")?\)\z/

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
    # Two trailing spaces are markdown's other hard break, and the writer
    # needs it for the one line the backslash marker cannot end: a line
    # whose own last character is a backslash. "\\\\" there is an escaped
    # backslash and there is no marker left over, so the break was lost
    # and the text gained a space instead.
    para.gsub(/ *(?<!\\)\\\n/, BREAK_SENTINEL)
        .gsub(/  +\n/, BREAK_SENTINEL)
        .tr("\n", ' ')
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
  # Splits on unescaped pipes only: a cell whose text contains "|" is
  # written back as "\|" (see table_to_markdown), and splitting on that
  # used to silently truncate the cell and drop everything after it.
  # The backslash itself is removed by parse_inline's escape handling.
  # The backslash the writer puts before a pipe is a column-break escape and
  # belongs to the table, not to the cell -- so it comes off here rather than
  # being left for parse_inline. Left on, it survived inside a code span,
  # whose content is verbatim on the way back: the cell text grew a backslash
  # on every single edit, without bound, and the page showed them.
  def split_table_row(line)
    line.strip.sub(/\A\|/, '').sub(/(?<!\\)\|\z/, '').split(/(?<!\\)\|/)
        .map { |c| c.strip.gsub('\\|', '|') }
  end

  # A table that opens with the separator row has no header: the alignment
  # comes from that first line and everything after it is data. Markdown
  # proper has no way to say this -- GFM's grammar starts at the header --
  # but the shape has to be sayable, because plenty of real tables are
  # headerless and the importers meet them: a Wix table with
  # `tableData.rowHeader` false, an HTML table with no <thead>. Without it
  # they lost their first row of data to a <th>, and once that had happened
  # nothing in the file remembered it.
  #
  # The separator can't be mistaken for a header. A header row of dashes
  # would have to be written `\-\-\-` to mean it, and the writer escapes it
  # that way. The cost is one shape this engine reads and other renderers
  # don't -- deliberate, and the same trade the video and chat blocks make.
  def parse_table(para)
    lines = para.split("\n").map(&:strip).reject(&:empty?)
    return nil if lines.size < 2
    return nil unless lines[0].include?('|')

    # STRICT for the first line, and it has to be: a bullet list is written
    # "- item", so a first bullet whose text is nothing but pipes and dashes
    # ("- -|-") satisfied the loose separator pattern and the whole list was
    # read back as a headerless table -- the first item swallowed into the
    # separator, every other item keeping a literal "- " as cell text. The
    # loose pattern stays where it always was, under a header, so no post
    # that round-tripped before round-trips differently now.
    headerless = strict_separator_row?(lines[0])
    sep = headerless ? 0 : 1
    return nil unless separator_row?(lines[sep])

    header = headerless ? nil : split_table_row(lines[0])
    align = split_table_row(lines[sep]).map do |spec|
      left = spec.start_with?(':')
      right = spec.end_with?(':')
      if left && right then 'center'
      elsif right then 'right'
      else 'left'
      end
    end
    return nil if align.empty?
    return nil if header && (header.empty? || align.size != header.size)

    cell = lambda do |raw|
      text, formatting = parse_inline(raw)
      formatting.empty? ? { 'text' => text } : { 'text' => text, 'formatting' => formatting }
    end

    # The separator decides the width when there is no header to do it.
    width = header ? header.size : align.size
    rows = lines.drop(sep + 1).map do |line|
      values = split_table_row(line)
      # Missing cells are padded with empty ones so a short row doesn't
      # break the table. Extra cells are KEPT: imported archives carry
      # single-column headers over two-column rows, and discarding the
      # overflow silently ate the second cell of every row on each edit.
      # HTML renders a jagged table fine.
      Array.new([width, values.size].max) { |i| cell.call(values[i].to_s) }
    end

    # Built in this order on purpose: a headed table has to come out with
    # its keys in exactly the order it has had since the format existed, or
    # every table in every archive rewrites itself on the next save.
    block = { 'type' => 'table', 'align' => align }
    block['header'] = header.map { |h| cell.call(h) } if header
    block['rows'] = rows
    block
  end

  # A row that is nothing but the dashes-and-colons of a separator. Used
  # twice: to find the separator under a header, and to notice a table that
  # begins with one and so has no header at all.
  def separator_row?(line)
    line.include?('-') && TABLE_SEPARATOR_RE.match?(line)
  end

  # What a separator row written by this engine looks like, cell by cell:
  # each one an unbroken run of dashes with an optional colon at either end.
  # Nothing an author types as prose can be mistaken for it, which is what a
  # line has to be before it may mean "this table has no header".
  def strict_separator_row?(line)
    # The leading pipe is the discriminator a bullet can never have: a list
    # item is written "- text", so "- |-" reads cell-for-cell like a
    # separator once the marker is off. The writer always emits the outer
    # pipes, and the cheat sheets document that form, so requiring them
    # costs nothing and closes the ambiguity outright.
    return false unless line.start_with?('|') && line.include?('-')

    cells = split_table_row(line)
    !cells.empty? && cells.all? { |c| /\A:?-+:?\z/.match?(c.strip) }
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
      # The emptiness test has to come AFTER the emptiness of the array
      # itself: `[].last` is nil and `nil.to_s.empty?` is true, so a quote
      # whose only line above the attribution was blank spun here forever
      # at full CPU -- `./blog.sh add` never returned, and the author lost
      # the text they had just written to a Ctrl-C. The writer emits
      # exactly that shape for a stored whitespace-only quote with a cite,
      # so editing such a post hung on every save.
      quoted_lines.pop while !quoted_lines.empty? && quoted_lines.last.to_s.strip.empty?
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
        # NOT straight into `idx`. A nested call that refuses answers a bare
        # nil, which destructures into two nils -- and the assignment happens
        # before the guard below can break, so this frame's own idx was gone.
        # It then returned [its list, nil] to the frame above, where the list
        # is truthy, the guard passes, and the next loop compares nil with a
        # number. A continuation line under a nested item -- "- a" / "  - b" /
        # "    text", the ordinary way to give an item a second line, and a
        # shape the cheat sheet's own nesting example invites -- crashed
        # `blog.sh add` with a Ruby backtrace and no post written. Put in
        # about.html it killed the build outright and rendered no site at all.
        nested, next_idx = parse_list_level(lines, idx, cur_indent)
        break unless nested && next_idx && items.any?

        idx = next_idx

        # Two differently-indented runs under the same item -- "  - a" then
        # "   - b", which is what hand-typed lists look like -- came back as
        # two calls, and the second assignment threw the first one's items
        # away. The item simply vanished from the post, with nothing said.
        # They belong to the same child list; ragged indentation under one
        # parent is one level, not two.
        if (existing = items.last['children'])
          existing['items'] = (existing['items'] || []) + (nested['items'] || [])
        else
          items.last['children'] = nested
        end
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

  # Which spelling the directory itself uses for a file the volume already
  # resolved. Exact match costs one lookup; anything else asks the volume
  # for identity (dev+ino) rather than comparing strings. A volume that
  # resolves nothing -- Linux, case-sensitive APFS -- lands on the last
  # line and nothing changes.
  def on_disk_name(dir, name)
    children = Dir.children(dir)
    return name if children.include?(name)

    target = File.join(dir, name)
    children.find { |child| File.identical?(File.join(dir, child), target) } || name
  rescue SystemCallError
    name
  end

  def resolve_image(path, media_dir, counter, media_files = {}, incoming_dir: nil)
    expanded = File.expand_path(path)
    # realpath, not just expand_path: /tmp vs /private/tmp (macOS) or any
    # symlinked path names the same file two ways, and classifying the
    # post's OWN media file as a new external attachment made a
    # year-moving edit copy from a source the move had just relocated --
    # ENOENT mid-save, media moved, JSON left behind.
    if media_dir
      real = (File.realpath(expanded) rescue expanded)
      real_dir = (File.realpath(File.expand_path(media_dir)) rescue File.expand_path(media_dir))
      return [File.basename(expanded), nil] if real.start_with?("#{real_dir}/") || expanded.start_with?("#{File.expand_path(media_dir)}/")
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
      # The name the DIRECTORY uses, not the one the author typed. On macOS
      # File.exist? resolves letter case and unicode form, so writing back
      # what was typed is how a post comes to name IMG_2043.JPG for a file
      # the disk calls img_2043.jpg. Both spellings then work here and the
      # page renders -- but the archive now carries a disagreement that the
      # checker has to notice and a Linux server would answer with a hole.
      return [on_disk_name(File.dirname(in_media), File.basename(in_media)), nil] if in_media && File.exist?(in_media)

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

  # Three backticks or more, so a block whose own text contains a ``` line
  # can be fenced by a longer run -- the standard markdown escape hatch, and
  # what the writer now emits. Fixed at exactly three, a code block holding a
  # fenced example closed at the inner fence: the block split into two empty
  # code blocks with the text stranded between them as prose, and the edit
  # guard stayed silent because no block TYPE had disappeared. The closing
  # fence must be at least as long as the opening one (a shorter run inside
  # is content, not a terminator).
  # The writer escapes a backslash and a double quote inside a quoted title
  # (an image caption, a link title) because the quote is the delimiter.
  # Undone here so the stored value is what the author typed. nil stays nil:
  # "no title" and "empty title" are different answers upstream.
  def unescape_title(text)
    return text if text.nil?

    text.gsub(/\\(.)/) { Regexp.last_match(1) }
  end

  CODE_FENCE_LINE_RE = %r{\A(`{3,})[ \t]*([^\n`]*?)[ \t]*\z}

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
      fence = m[1]
      lang = m[2]
      i += 1
      code_lines = []
      # Closed only by a fence at least as long as the opening one, and with
      # nothing after it: a shorter or annotated run is part of the content.
      until i >= lines.length ||
            ((closing = /\A(`{3,})\z/.match(lines[i].strip)) && closing[1].length >= fence.length)
        code_lines << lines[i]
        i += 1
      end
      segments << { type: :code, lang: lang, text: code_lines.join("\n") }
      i += 1 # skip the closing ``` (or, if unterminated, i == lines.length already)
    end

    segments << { type: :prose, text: buffer.join("\n") } unless buffer.empty?
    segments
  end

  # A paragraph without the indentation it shares, rather than one merely
  # stripped at both ends.
  #
  # `strip` takes the leading spaces off the FIRST line only, so a flat
  # list written with one to three spaces in front of every marker -- what
  # a converter emits and what plenty of people type -- arrived at
  # parse_list as one item at column 0 followed by items at column 2, and
  # came back as a one-item list with everything else nested under it.
  # parse_list was reading it correctly; it was handed the wrong thing.
  #
  # The COMMON indent, so a genuinely nested list keeps its shape: the
  # minimum is the outer level, and every relative depth survives it.
  def dedent(para)
    lines = para.to_s.split("\n", -1)
    present = lines.reject { |l| l.strip.empty? }
    return para.to_s.strip if present.empty?

    common = present.map { |l| l[/\A[ ]*/].length }.min
    lines.map { |l| l.strip.empty? ? '' : l[common..] }.join("\n").strip
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

      # The other platforms whose address alone says how to play it (see
      # lib/embed.rb). Same shape as YouTube above -- provider plus the
      # identifying part, never their embed code -- and the same gesture
      # for the author: paste the address you would send a friend.
      if (embed = Embed.detect(target))
        return [{ 'type' => Embed.kind(embed), 'url' => target, 'caption' => caption }.merge(embed), counter]
      end

      counter += 1
      filename, src = resolve_image(target, media_dir, counter, media_files, incoming_dir: incoming_dir)
      media_files[src] = filename if src
      counter -= 1 unless src # filename was recycled, the number wasn't consumed
      return [{ 'type' => 'video', 'media' => [{ 'url' => filename }], 'caption' => caption }, counter]
    elsif (m = IMAGE_RE.match(para))
      # An http(s) address is not a path. The engine publishes files it is
      # given; a picture that lives on somebody else's server cannot be one
      # of them, and treating the address as a filename produced a media
      # entry pointing at a file nobody ever had -- the post then carried a
      # picture that was never anywhere. Kept as a link, which is what the
      # line actually is, and said out loud so the author can download the
      # picture and write it as a file if they meant to keep it.
      if m[2].to_s.match?(%r{\Ahttps?://})
        warn "Note: #{m[2]} is on another server, so it stays a link. Download it into " \
             'incoming/ and write ![alt](filename.jpg) to publish it with the post.'
        return [{ 'type' => 'text', 'text' => "[#{m[1]}](#{m[2]})",
                  'formatting' => [{ 'type' => 'link', 'url' => m[2], 'start' => 1,
                                     'end' => 1 + m[1].to_s.length }] }, counter]
      end

      counter += 1
      # The label is unescaped like the title beside it: the writer escapes
      # "[" and "]" so an alt text holding one cannot end the label early,
      # and reading it back raw left the backslashes where the reader could
      # see them -- and put them into the alt attribute on the page.
      alt, path, caption = unescape_title(m[1]), m[2], unescape_title(m[3])
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
    elsif para.gsub(/`[^`]*`/m, '`x`').match?(/(?<!\\)!\[[^\]]*\]\([^)]+\)/)
      # Code spans are masked first: "`![popisek](foto.jpg)`" is a code
      # EXAMPLE of image syntax, not an image, and aborting on it made the
      # post uneditable.
      # An image in the middle of a paragraph can't be rendered -- the
      # schema only knows image blocks. This used to silently turn into a
      # link to the file plus a stray exclamation mark.
      abort "Both images and videos must be on their own line, separated by blank lines. The problem is here:\n#{para}"
    elsif !para.include?("\n") && HR_RE.match?(para)
      return [{ 'type' => 'hr' }, counter]
    elsif !para.include?("\n") && TEASER_END_RE.match?(para)
      return [{ 'type' => 'teaser_end' }, counter]
    elsif !para.include?("\n") && (m = HEADING_RE.match(para))
      text, formatting = parse_inline(m[2])
      # A heading line whose whole content was a label-less anchor has no
      # words left once parse_inline has swallowed it -- 24 of them in one
      # imported post. Dropped rather than kept: "#### " with nothing after
      # it is not a heading here either (HEADING_RE wants a character), and
      # an <h4> with no accessible name is a heading a reader can neither
      # see nor be told about.
      return [nil, counter] if text.strip.empty?

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
      # A quoted link title rides through parse_inline too, so a hard
      # break inside one arrives here as the sentinel -- but in the
      # formatting entry, which the swap on `text` above cannot reach.
      # Left alone, the private-use character was stored in the title
      # and published.
      formatting.each { |f| f['title'] = f['title'].gsub(BREAK_SENTINEL, "\n") if f['title'] }
      block['formatting'] = formatting unless formatting.empty?
      return [block, counter]
    end
  end

  def parse_body(body, media_dir, incoming_dir: nil)
    blocks = []
    media_files = {}
    counter = 0

    # CRLF at the door. A markdown tree written on Windows -- which is most
    # of what a converter hands over -- carries \r before every newline, and
    # the paragraph collapse turns a soft break into a space and leaves the
    # \r sitting in the stored text. It is invisible in the editor, comes
    # out in the JSON, and travels into the page and the feed. A code fence
    # keeps its own bytes; nothing else has any use for a carriage return.
    body = body.to_s.gsub(/\r\n?/, "\n")

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

      segment[:text].split(/\n\s*\n/).map { |para| dedent(para) }.reject(&:empty?).each do |para|
        block, counter = parse_prose_block(para, media_dir, media_files, counter, incoming_dir: incoming_dir)
        # nil is a paragraph that turned out to hold nothing a reader could
        # see -- see the heading branch. Every other path returns a block.
        blocks << block if block
      end
    end

    missing = media_files.keys.reject { |src| File.exist?(src) }
    [blocks, media_files, missing]
  end
end
