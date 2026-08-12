# frozen_string_literal: true

module Import
  # HTML → the engine's content blocks, for the sources that hand over a
  # post body as markup (a feed's content:encoded, a WordPress export).
  #
  # Written rather than delegated to a parser gem, for the same reason the
  # QR encoder and the ICO container are: the alternative is Nokogiri, and
  # "no gems" is the one promise this engine makes about installing it.
  # REXML can't stand in -- it's an XML parser, and real-world post HTML is
  # full of unclosed <p>, bare <br>, stray & and attributes without quotes.
  #
  # Deliberately a conservative subset: exactly what the block schema can
  # represent. Anything else is flattened to its text rather than guessed
  # at, and every drop is recorded in `warnings` so an import can tell you
  # what it couldn't keep instead of silently losing it.
  module HtmlBlocks
    # Elements that never have a closing tag.
    VOID = %w[area base br col embed hr img input link meta param source track wbr].freeze

    # Block-level starts that implicitly close an open <p> -- the single
    # most common malformation in hand-written and CMS-generated HTML.
    CLOSES_P = %w[p div h1 h2 h3 h4 h5 h6 blockquote ul ol li pre table hr figure section article].freeze

    INLINE_SPANS = {
      'b' => 'bold', 'strong' => 'bold',
      'i' => 'italic', 'em' => 'italic',
      's' => 'strikethrough', 'del' => 'strikethrough', 'strike' => 'strikethrough',
      'code' => 'code'
    }.freeze

    # The HTML4 Latin-1 names, which map to U+00A0..U+00FF in exactly this
    # order -- built rather than typed out, since 96 hand-written pairs is
    # 96 chances to transpose one. Old CMS content is full of these.
    LATIN1_NAMES = %w[
      nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr
      deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest
      Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml
      ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig
      agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
      eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
    ].freeze

    ENTITIES = ({
      'amp' => '&', 'lt' => '<', 'gt' => '>', 'quot' => '"', 'apos' => "'",
      'hellip' => '…', 'mdash' => '—', 'ndash' => '–', 'minus' => '−',
      'lsquo' => '‘', 'rsquo' => '’', 'ldquo' => '“', 'rdquo' => '”',
      'bull' => '•', 'dagger' => '†', 'Dagger' => '‡', 'permil' => '‰',
      'lsaquo' => '‹', 'rsaquo' => '›', 'euro' => '€', 'trade' => '™',
      'scaron' => 'š', 'Scaron' => 'Š', 'oelig' => 'œ', 'OElig' => 'Œ'
    }.merge(LATIN1_NAMES.each_with_index.to_h { |name, i| [name, [0xA0 + i].pack('U')] })).freeze

    Result = Struct.new(:blocks, :warnings, keyword_init: true)

    module_function

    def parse(html)
      doc = Tree.build(Tokenizer.tokenize(html.to_s))
      builder = Builder.new
      builder.walk(doc)
      Result.new(blocks: builder.blocks, warnings: builder.warnings)
    end

    # Numeric references always decode; named ones decode from the table
    # and are otherwise left standing verbatim. Leaving "&eacute;" visible
    # is not pretty, but it's honest -- an entity silently swallowed takes
    # a letter out of the middle of a word, and nobody proof-reads 800
    # imported posts.
    #
    # `whole` is bound before the case on purpose: inside it, the `when`
    # regexes become the last match, so Regexp.last_match(0) would no
    # longer be this gsub's match. That exact slip made every unknown
    # entity disappear.
    def decode_entities(text)
      text.gsub(/&(#x?[0-9a-fA-F]+|\w+);/) do
        whole = Regexp.last_match(0)
        token = Regexp.last_match(1)
        case token
        when /\A#x(\h+)\z/i then codepoint(Regexp.last_match(1).hex, whole)
        when /\A#(\d+)\z/ then codepoint(Regexp.last_match(1).to_i, whole)
        # Exact case first: &Eacute; and &eacute; are different letters, so
        # a blanket downcase would quietly swap É for é. The downcased
        # lookup is only a fallback for the case-insensitive basics.
        else ENTITIES[token] || ENTITIES[token.downcase] || whole
        end
      end
    end

    # A numeric reference decodes only when it names a real, printable
    # character; otherwise the entity is left standing verbatim, same as an
    # unknown name. Without the range check, one "&#99999999;" anywhere in
    # a feed produced an invalid UTF-8 string and took the whole import
    # down with an Encoding::CompatibilityError -- the opposite of what a
    # tolerant parser is for. Controls (and NUL in particular) are refused
    # too: they are never content, and NUL inside post text is a gift to
    # every downstream consumer. Tab and newline pass, since &#10; in
    # source markup is legitimate whitespace.
    def codepoint(number, whole)
      printable = number == 0x9 || number == 0xA || number == 0xD ||
                  (number >= 0x20 && number <= 0xD7FF) ||
                  (number >= 0xE000 && number <= 0x10FFFF)
      printable ? [number].pack('U') : whole
    end

    # --- tokenizer ------------------------------------------------------

    # Scans into :text / :open / :close tokens. Anything that isn't a
    # recognisable tag (a stray "<" in prose, a comment, a doctype) is
    # treated as text or dropped rather than raising -- the whole point of
    # not using an XML parser here.
    module Tokenizer
      TAG = %r{<(/)?([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>}.freeze
      ATTR = /([a-zA-Z_:][-\w:.]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/.freeze

      module_function

      def tokenize(html)
        # Script and style contents are code, not prose -- dropped whole so
        # their bodies never leak into a post as text.
        html = html.gsub(%r{<(script|style)\b.*?</\1>}mi, '')
        # A capture truncated INSIDE a script (routine in Wayback
        # snapshots) leaves the pair regex above without a close -- and
        # raw JavaScript then walked into the post as a paragraph. An
        # unterminated script or style eats to the end.
        html = html.gsub(%r{<(script|style)\b.*\z}mi, '')
        html = html.gsub(/<!--.*?-->/m, '')
        html = html.gsub(/<![^>]*>/, '')

        tokens = []
        pos = 0
        while (m = TAG.match(html, pos))
          text = html[pos...m.begin(0)]
          tokens << [:text, text] unless text.empty?
          name = m[2].downcase
          tokens << if m[1]
                      [:close, name]
                    else
                      [:open, name, attributes(m[3].to_s), VOID.include?(name) || m[3].to_s.rstrip.end_with?('/')]
                    end
          pos = m.end(0)
        end
        rest = html[pos..]
        tokens << [:text, rest] unless rest.nil? || rest.empty?
        tokens
      end

      def attributes(raw)
        raw.scan(ATTR).each_with_object({}) do |(name, _, dq, sq, bare), out|
          out[name.downcase] = HtmlBlocks.decode_entities(dq || sq || bare || '')
        end
      end
    end


    # --- blocks ---------------------------------------------------------

    # Walks the tree and emits content blocks. Unknown elements aren't
    # errors: their children are walked anyway, so a post wrapped in
    # <div><section><article> still yields its paragraphs. What gets
    # recorded as a warning is only content that would otherwise be lost --
    # an iframe, a video embed, a form -- so the summary can name it.
    class Builder
      attr_reader :blocks, :warnings

      HEADINGS = { 'h1' => 'heading1', 'h2' => 'heading2', 'h3' => 'heading3',
                   'h4' => 'heading4', 'h5' => 'heading5', 'h6' => 'heading6' }.freeze

      # Carries content the block schema has no shape for. Flattening these
      # to their text would produce nonsense (an iframe has none, a form is
      # a control), so they are dropped and named instead.
      DROPPED = %w[iframe video audio object embed canvas svg form input button select map].freeze

      # What makes an element a wrapper rather than a paragraph -- see
      # inline_only? below.
      BLOCK_LEVEL = %w[p div h1 h2 h3 h4 h5 h6 blockquote ul ol li pre table thead tbody
                       tr td th hr figure figcaption section article aside header footer
                       nav main form dl dt dd].freeze

      # Elements that carry no structure of their own. A run of these
      # between two blocks is one sentence and has to be gathered into one
      # -- see walk. Named rather than derived from BLOCK_LEVEL because an
      # unknown element may hold blocks, and flattening one into a
      # paragraph would swallow them.
      INLINE_RUN = %w[a b strong i em u s del strike code span small sub sup mark abbr
                      acronym cite q big font tt kbd samp var ins time bdi bdo img].freeze

      def initialize
        @blocks = []
        @warnings = Hash.new(0)
      end

      # Not every body has blocks in it. Classic Blogger writes none at
      # all: the post is a flat run of text, <a>, <b>, <span> and <br>,
      # and one visit() per child turned a single sentence into a block
      # per fragment -- with every link lost on the way, since
      # emit_paragraph(<a>) renders the anchor's CHILDREN and never the
      # anchor itself. So consecutive inline siblings are gathered into
      # one synthetic paragraph, which is what the same markup wrapped in
      # <p> has always produced.
      #
      # A <br> ends the run rather than sitting inside it. Inline.render
      # renders one as a space, and a body written without paragraphs uses
      # it as the line separator it looks like -- the footer of a
      # Posterous-era post reads
      #   Shot with: <strong>Camera+</strong> for iPhone<br />
      #   Edited with: <strong>Snapseed</strong>
      # and keeping the break inside the run welded those two facts into
      # one line. Ending the run splits them the way the markup does,
      # while the emphasis and the links between the breaks still travel
      # together instead of being shredded a fragment at a time.
      def walk(node)
        run = []
        node.children.each do |child|
          if child.text? || inline_run?(child)
            run << child
          elsif child.name == 'br'
            flush_run(run)
          else
            flush_run(run)
            visit(child)
          end
        end
        flush_run(run)
      end

      # All the way down, because an <a> may legally wrap whole blocks
      # (the card link of every modern theme) -- gathered into a run, its
      # paragraphs would be flattened into one. <br> is allowed inside:
      # <span>text<br />more</span> is what Blogger writes around every
      # other sentence, and letting it break the run would put the split
      # back that this is here to remove.
      def inline_run?(node)
        return false unless INLINE_RUN.include?(node.name)

        node.children.all? { |c| c.text? || c.name == 'br' || inline_run?(c) }
      end

      def flush_run(run)
        return if run.empty?

        nodes = run.dup
        run.clear
        # A lone run of loose text is still just that -- kept on its own
        # path so nothing changes for the bodies that already had blocks.
        return visit(nodes.first) if nodes.size == 1 && nodes.first.text?

        emit_paragraph(Node.new(name: 'p', attrs: {}, children: nodes))
      end

      def visit(node)
        return emit_text_run(node) if node.text?

        case node.name
        when 'p' then emit_paragraph(node)
        when *HEADINGS.keys then emit_heading(node)
        when 'blockquote' then emit_quote(node)
        when 'ul', 'ol' then emit_list(node)
        when 'pre' then emit_code(node)
        when 'table' then emit_table(node)
        when 'hr' then @blocks << { 'type' => 'hr' }
        when 'img' then emit_image(node)
        when 'figure' then emit_figure(node)
        when 'br' then nil
        when *DROPPED then @warnings[node.name] += 1
        else
          # An unknown element holding nothing but inline content is a
          # paragraph in all but name -- <div>Shoot with: <strong>x</strong>
          # for iPhone</div> is what a decade of CMS output actually looks
          # like. Walking its children one by one would shred that sentence
          # into a block per fragment and drop the emphasis with it, so it
          # is rendered as one paragraph instead. Anything with a
          # block-level child is still just a wrapper, and gets walked.
          inline_only?(node) ? emit_paragraph(node) : walk(node)
        end
      end

      # Only direct children are examined: a wrapper is identified by what
      # it contains at its own level, and anything deeper is that child's
      # problem to classify.
      def inline_only?(node)
        node.children.any? &&
          node.children.none? { |c| !c.text? && BLOCK_LEVEL.include?(c.name) }
      end

      # Loose text between block elements still belongs to the post -- it
      # becomes its own paragraph rather than vanishing.
      def emit_text_run(node)
        text = HtmlBlocks.decode_entities(node.attrs['text'].to_s).strip
        return if text.empty?

        @blocks << { 'type' => 'text', 'text' => normalize(text) }
      end

      def emit_paragraph(node)
        # A paragraph that only wraps an image is the image, not an empty
        # paragraph plus a stray block.
        text, formatting = Inline.render(node)
        images = collect(node, 'img')
        if text.strip.empty?
          images.each { |img| emit_image(img) }
          return
        end

        @blocks << text_block(text, formatting)
        images.each { |img| emit_image(img) }
      end

      def emit_heading(node)
        text, formatting = Inline.render(node)
        return if text.strip.empty?

        block = text_block(text, formatting)
        block['subtype'] = HEADINGS[node.name]
        @blocks << block
      end

      # The schema's quote is a single text block, so a multi-paragraph
      # blockquote becomes several quote blocks rather than one with the
      # paragraph breaks lost.
      def emit_quote(node)
        paragraphs = node.children.select { |c| c.name == 'p' }
        sources = paragraphs.empty? ? [node] : paragraphs
        sources.each do |source|
          text, formatting = Inline.render(source)
          next if text.strip.empty?

          block = text_block(text, formatting)
          block['subtype'] = 'quote'
          @blocks << block
        end
        # Inline.render leaves <img> to the Builder, so a picture inside a
        # quote had nowhere to land: it disappeared, and a quote holding
        # nothing but a picture disappeared whole (the text was empty, so
        # the block was dropped and no image ever took its place).
        # emit_paragraph and emit_figure have always collected images;
        # this branch was simply forgotten.
        collect(node, 'img').each { |img| emit_image(img) }
      end

      def emit_list(node)
        items = node.children.select { |c| c.name == 'li' }.filter_map { |li| list_item(li) }
        return if items.empty?

        @blocks << { 'type' => 'list', 'style' => node.name, 'items' => items }
      end

      def list_item(li)
        nested = li.children.find { |c| %w[ul ol].include?(c.name) }
        text, formatting = Inline.render(li, skip: %w[ul ol])
        return nil if text.strip.empty? && nested.nil?

        text, formatting = normalize_with_spans(text, formatting)
        item = { 'text' => text }
        item['formatting'] = formatting unless formatting.empty?
        if nested
          children = nested.children.select { |c| c.name == 'li' }.filter_map { |c| list_item(c) }
          item['children'] = { 'style' => nested.name, 'items' => children } unless children.empty?
        end
        item
      end

      # <pre> content is verbatim -- no entity-decoded reflow, no
      # whitespace normalization, and the language hint comes from the
      # class both WordPress and highlight.js use.
      def emit_code(node)
        code = node.children.find { |c| c.name == 'code' } || node
        text = raw_text(code)
        return if text.strip.empty?

        block = { 'type' => 'code', 'text' => text.sub(/\A\n/, '').rstrip }
        lang = (code.attrs['class'] || node.attrs['class']).to_s[/(?:language|lang)-([\w+#-]+)/, 1]
        block['lang'] = lang if lang
        @blocks << block
      end

      # Whether the first row is a heading or data is something the HTML
      # says and this used to ignore: every table handed its first row to a
      # <th> regardless, so a table with no <thead> and no <th> anywhere --
      # a keyboard-shortcut list, a layout table, a set of figures --
      # published its first line of data as a column heading, and after the
      # import nothing remembered otherwise. td and th were not even told
      # apart when the cells were read.
      def emit_table(node)
        head_trs = collect(node, 'thead').flat_map { |t| collect(t, 'tr') }
        pairs = collect(node, 'tr').filter_map do |tr|
          cells = tr.children.select { |c| %w[td th].include?(c.name) }
          next if cells.empty?

          [tr, cells]
        end
        return if pairs.empty?

        # "All of them th" missed the commonest headed table there is: a
        # matrix, whose top-left corner is an empty td and whose real column
        # headings beside it are th. Demanding every cell be a th read the
        # source's own headings as data. An EMPTY td among th is that corner;
        # a filled one is the other shape entirely -- a table with labels
        # down its side, where th and td alternate in every row and the first
        # row is not a heading at all.
        # The second row settles it, and looking only at the first did not:
        # a row-label table whose first value cell happens to be empty
        # ("Rok | " over "Pocet | 12") matched the corner rule and lost its
        # first row into a header. If the row below ALSO starts with a th,
        # the th are labels down the side and no row here is a heading.
        first_tr, first_cells = pairs.first
        second_cells = pairs[1] && pairs[1][1]
        labels_down_the_side = second_cells && second_cells.first &&
                               second_cells.first.name == 'th' &&
                               first_cells.first && first_cells.first.name == 'th'
        headed = head_trs.any? { |t| t.equal?(first_tr) } ||
                 (!labels_down_the_side &&
                  first_cells.any? { |c| c.name == 'th' } &&
                  first_cells.all? { |c| c.name == 'th' || Inline.render(c).first.to_s.strip.empty? })

        rows = pairs.map do |(_, cells)|
          cells.map do |cell|
            text, formatting = normalize_with_spans(*Inline.render(cell))
            out = { 'text' => text }
            out['formatting'] = formatting unless formatting.empty?
            out
          end
        end

        block = { 'type' => 'table', 'align' => Array.new(rows.first.size, 'left') }
        block['header'] = rows.shift if headed
        block['rows'] = rows
        @blocks << block
      end

      # An image's dimensions are required by the build (missing or <= 1px
      # is treated as degenerate and dropped), and HTML rarely carries
      # them -- so the URL is passed along for the adapter to size when it
      # downloads the file.
      def emit_image(node)
        src = node.attrs['src'].to_s
        return if src.empty?

        block = { 'type' => 'image', 'media' => [{ 'url' => src }] }
        alt = node.attrs['alt'].to_s
        block['alt_text'] = alt unless alt.empty?
        @blocks << block
      end

      def emit_figure(node)
        images = collect(node, 'img')
        caption_node = collect(node, 'figcaption').first
        caption = caption_node && normalize(Inline.render(caption_node).first)
        images.each do |img|
          emit_image(img)
          @blocks.last['caption'] = caption if caption && !caption.empty? && @blocks.last['type'] == 'image'
        end
        walk(node) if images.empty?
      end

      def text_block(text, formatting)
        text, formatting = normalize_with_spans(text, formatting)
        block = { 'type' => 'text', 'text' => text }
        block['formatting'] = formatting unless formatting.empty?
        block
      end

      # HTML collapses whitespace; the block schema stores plain text, so
      # the collapse has to happen here or every newline in the source
      # markup shows up as a gap.
      def normalize(text)
        text.gsub(/\s+/, ' ').strip
      end

      # The same collapse, but carrying the inline spans with it.
      #
      # Inline.collect counts offsets against the raw text as it accumulates,
      # so collapsing the text afterwards without moving the offsets left every
      # span pointing at the wrong characters. With ordinary pretty-printed
      # source markup (a newline and an indent between <p> and <a>) the shift
      # is large enough to push a span past the end of the stored text, and the
      # build then died on that post with a TypeError that named no post at
      # all -- one imported item could stop the whole site from rebuilding.
      def normalize_with_spans(text, formatting)
        chars = text.chars
        # map[i] = where raw character i ends up in the collapsed text
        # (map[chars.length] = the end, so exclusive span ends map too)
        map = Array.new(chars.length + 1, 0)
        out = +''
        # NUL counts as collapsible here only because the String#strip this
        # replaces removed it too -- and a stray NUL byte from a feed would
        # otherwise survive into the text and make the generated RSS and
        # sitemap invalid XML.
        collapsible = ->(ch) { ch.match?(/\s/) || ch == "\0" }

        i = 0
        while i < chars.length
          unless collapsible.call(chars[i])
            map[i] = out.length
            out << chars[i]
            i += 1
            next
          end

          run_end = i
          run_end += 1 while run_end < chars.length && collapsible.call(chars[run_end])
          (i...run_end).each { |k| map[k] = out.length }
          # A leading or trailing run disappears entirely -- that's the .strip
          # half of the collapse.
          out << ' ' unless out.empty? || run_end >= chars.length
          i = run_end
        end
        map[chars.length] = out.length

        spans = formatting.filter_map do |span|
          s = map[span['start'].to_i.clamp(0, chars.length)]
          e = map[span['end'].to_i.clamp(0, chars.length)]
          next if s >= e

          span.merge('start' => s, 'end' => e)
        end
        [out, spans]
      end

      def raw_text(node)
        return HtmlBlocks.decode_entities(node.attrs['text'].to_s) if node.text?

        node.children.map { |c| raw_text(c) }.join
      end

      def collect(node, name)
        found = []
        node.children.each do |child|
          next if child.text?

          found << child if child.name == name
          found.concat(collect(child, name))
        end
        found
      end
    end

    # Renders an element's inline content into (text, formatting spans).
    # Offsets are Unicode codepoints, matching the schema -- see the field
    # reference in docs/architecture.md.
    module Inline
      module_function

      def render(node, skip: [])
        text = +''
        spans = []
        collect(node, text, spans, skip)
        [text, spans.reject { |s| s['start'] >= s['end'] }]
      end

      def collect(node, text, spans, skip)
        node.children.each do |child|
          if child.text?
            text << HtmlBlocks.decode_entities(child.attrs['text'].to_s)
            next
          end
          next if skip.include?(child.name)

          case child.name
          when 'br' then text << ' '
          when 'img' then nil # handled as its own block by the Builder
          when 'a'
            start = text.length
            collect(child, text, spans, skip)
            href = child.attrs['href'].to_s
            spans << { 'type' => 'link', 'url' => href, 'start' => start, 'end' => text.length } unless href.empty?
          else
            span_type = HtmlBlocks::INLINE_SPANS[child.name]
            start = text.length
            collect(child, text, spans, skip)
            spans << { 'type' => span_type, 'start' => start, 'end' => text.length } if span_type
          end
        end
      end
    end

    # --- tree -----------------------------------------------------------

    Node = Struct.new(:name, :attrs, :children, keyword_init: true) do
      def text?
        name == :text
      end
    end

    module Tree
      module_function

      def build(tokens)
        root = Node.new(name: 'root', attrs: {}, children: [])
        stack = [root]

        tokens.each do |type, name, attrs, self_closing|
          case type
          when :text
            stack.last.children << Node.new(name: :text, attrs: { 'text' => name }, children: [])
          when :open
            implicit_close(stack, name)
            node = Node.new(name: name, attrs: attrs, children: [])
            stack.last.children << node
            stack << node unless self_closing
          when :close
            close(stack, name)
          end
        end
        root
      end

      # <p>one<p>two and <li>a<li>b are everywhere; without this they nest
      # instead of following each other, and the whole document ends up
      # inside the first one.
      def implicit_close(stack, name)
        open = stack.last.name
        return if stack.size <= 1

        close(stack, 'p') if open == 'p' && CLOSES_P.include?(name)
        close(stack, 'li') if stack.last.name == 'li' && name == 'li'
        # Omitting </td> and </tr> is valid HTML5 and the house style of
        # the hand-written archives page mode imports. Without these, each
        # next cell NESTED inside the previous one, and the recursive cell
        # collector then emitted every row twice: once concatenated into
        # the first cell, once as itself.
        if %w[td th].include?(name)
          close(stack, 'td') if stack.any? { |n| n.name == 'td' }
          close(stack, 'th') if stack.any? { |n| n.name == 'th' }
        elsif name == 'tr'
          close(stack, 'td') if stack.any? { |n| n.name == 'td' }
          close(stack, 'th') if stack.any? { |n| n.name == 'th' }
          close(stack, 'tr') if stack.any? { |n| n.name == 'tr' }
        end
      end

      # An unmatched </div> must not pop the world: only unwind if the tag
      # is actually open somewhere.
      def close(stack, name)
        index = stack.rindex { |n| n.name == name }
        return unless index&.positive?

        stack.pop(stack.size - index)
      end
    end
  end
end
