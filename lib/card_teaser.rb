# frozen_string_literal: true

# lib/card_teaser.rb -- how much of a post a listing card shows.
#
# A card used to render the WHOLE post and let CSS clip it at 500px. On the
# archive this was measured against that meant every one of the front
# page's fourteen cards carried between 794 and 2616 pixels of content and
# showed 500 -- 49,312 of 50,659 characters of the page were inside the
# clip, and 33 of its 154 focusable elements were reachable by the keyboard
# while invisible on screen. The card is cut here instead, at a block
# boundary, and the stylesheet no longer hides anything.
#
# 📏 The budget is in ESTIMATED HEIGHT, not in characters, and that took a
# measurement to get right: characters do not measure height. A picture
# contributes nothing to a character budget and several hundred pixels to
# the page, so a rule of "400 characters" made 34% of this archive's cards
# TALLER than the clip they replaced, one of them 4928px. A height budget
# and a single tall photograph is the only case left.
#
# The estimate is approximate on purpose -- it is made against a nominal
# card, and the reader's is narrower or wider. So was the 500px clip it
# replaces; what matters is that the cut lands between blocks rather than
# through one.
module CardTeaser
  # Measured on a real card at a desktop width: the content column is 534px
  # wide, a paragraph line is 24px, and a full line holds about 78
  # characters (checked against twelve real paragraphs -- eleven agreed).
  WIDTH = 534
  LINE = 24
  CHARS_PER_LINE = 78
  # The margin between two blocks.
  GAP = 16
  # What the clip used to show.
  BUDGET = 500
  # One picture in 3216 in the archive this was written against has no
  # stored dimensions, and this is what it is worth. The engine asks for
  # dimensions when a post is written; an old import may not have them.
  UNKNOWN_MEDIA = 320

  module_function

  # The blocks a card shows, and whether anything was left out. The first
  # block is always kept: a card with nothing in it is not a shorter card,
  # it is a broken one -- and a photograph taller than the whole budget is
  # still what the post IS.
  def blocks(content, budget: BUDGET)
    # The same blocks the renderer will draw, which means WITHOUT the
    # tracking pixels it drops. Counted here, a 1x1 gif claims the full
    # width of the card (534 px by the model below) and a 1x100 spacer
    # claims fifty thousand, so it alone fills the budget -- and then the
    # renderer throws it away and the card is empty with a "read more"
    # under it. Four posts on the archive this was measured against are
    # exactly that shape, all four from one Tumblr import, all four with
    # the pixel first.
    all = Array(content).compact.reject { |b| tracking_pixel?(b) }
    kept = []
    used = 0
    all.each do |block|
      h = height(block)
      break if kept.any? && used + h > budget

      kept << (kept.empty? && h > budget ? trimmed(block, budget) : block)
      used += h
    end
    cut = kept.length < all.length
    cut ||= !kept.empty? && !kept.first.equal?(all.first)
    [kept, cut]
  end

  # Blocks made of ROWS -- lines of code, turns of a conversation, items,
  # table rows -- are cut to the rows that fit. Everything else is kept
  # whole.
  #
  # This is the one place a block is not taken or left as it stands, and it
  # exists for the first block alone, which is kept however tall it is. A
  # picture is not cut, because the picture IS the post and cropping it in
  # the listing is a decision about somebody's photograph. A hundred and
  # twenty lines of shell is not that: it is a block whose rows are
  # separable, and dumping all of them onto the front page is the defect
  # the stylesheet's clip used to cover -- measured as 0 posts in the
  # archive this was written against and one line in a tutorial away for
  # anybody writing them.
  ROW_KEYS = { 'code' => nil, 'chat' => 'lines', 'list' => 'items', 'table' => 'rows' }.freeze

  def trimmed(block, budget)
    return trimmed_text(block, budget) if block['type'] == 'text'
    return block unless ROW_KEYS.key?(block['type'])

    if block['type'] == 'code'
      lines = block['text'].to_s.split("\n")
      room = [(budget - GAP) / 20, 1].max
      return block if lines.length <= room

      # `cut` travels with the block so the renderer knows this copy is
      # not the whole thing. A card must not offer to copy half a script.
      return block.merge('text' => lines.first(room).join("\n"), 'cut' => true)
    end

    key = ROW_KEYS[block['type']]
    rows = Array(block[key])
    room = [(budget - GAP) / LINE, 1].max
    return block if rows.length <= room

    block.merge(key => rows.first(room), 'cut' => true)
  end

  # Roughly what this block will take on screen. Every branch is the
  # simplest thing that is right about the shape rather than the pixel.
  def height(block)
    return 0 unless block.is_a?(Hash)

    case block['type']
    when 'text' then lines(block['text']) * LINE + GAP
    when 'image', 'video' then media_height(block) + GAP
    when 'audio', 'file', 'link' then 90 + GAP
    when 'list' then list_lines(block) * LINE + GAP
    when 'code' then (block['text'].to_s.count("\n") + 1) * 20 + GAP
    when 'chat' then chat_lines(block) * LINE + GAP
    when 'table' then table_lines(block) * LINE + GAP
    when 'hr' then 20
    # teaser_end renders as nothing, and an unknown type renders as a
    # short line of its own JSON.
    when 'teaser_end' then 0
    else 40 + GAP
    end
  end

  # A picture keeps its aspect ratio at the card's width. A video with no
  # dimensions is 16:9, which is what its player is.
  def media_height(block)
    media = (block['media'] || []).first || {}
    width = media['width'].to_f
    height = media['height'].to_f
    if block['type'] == 'video' && !(width.positive? && height.positive?)
      width = 16.0
      height = 9.0
    end
    return UNKNOWN_MEDIA unless width.positive? && height.positive?

    (WIDTH * height / width).round
  end

  # A paragraph is one thought, which is why it took an argument to cut it
  # at all -- but the sentences in it are as separable as the lines of a
  # listing, and a post that opens with three thousand characters is one
  # keystroke away even where the archive has none.
  #
  # Cut on a word, marked with an ellipsis, and the formatting cut WITH
  # it: a link is a range of offsets into this string, so a text cut
  # without them leaves a range pointing past its own end -- a link that
  # covers nothing, or covers the ellipsis. Spans entirely inside survive,
  # a span straddling the cut ends at it, and a span beyond it is gone
  # along with the words it decorated.
  def trimmed_text(block, budget)
    room = [((budget - GAP) / LINE) * CHARS_PER_LINE, CHARS_PER_LINE].max
    text = block['text'].to_s
    return block if text.length <= room

    kept = text[0, room].sub(/[[:space:]]+[^[:space:]]*\z/, '')
    kept = text[0, room] if kept.empty?
    out = block.merge('text' => "#{kept}…")
    spans = Array(block['formatting']).filter_map do |span|
      next if span['start'].to_i >= kept.length

      span.merge('end' => [span['end'].to_i, kept.length].min)
    end
    spans.empty? ? out.reject { |k, _| k == 'formatting' } : out.merge('formatting' => spans)
  end

  # The twin of `degenerate_image?` in build/build_blog.rb, and it has to
  # stay its twin: an image this drops and the renderer keeps would take
  # room on a card that shows nothing, and one the renderer drops and this
  # keeps is the empty card above. Unknown or unreadable dimensions render,
  # so they count here too -- only a real 1x1 is the pixel being dropped.
  def tracking_pixel?(block)
    return false unless block.is_a?(Hash) && block['type'] == 'image'

    media = (block['media'] || []).first || {}
    w = Integer(media['width'], exception: false)
    h = Integer(media['height'], exception: false)
    return false if w.nil? || h.nil?

    w <= 1 || h <= 1
  end

  # A line the reader sees, not a line of source: a paragraph wraps at
  # roughly CHARS_PER_LINE, and a hard break inside it starts a new line
  # of its own -- the renderer turns each one into a <br>. Counting only
  # the wrapping put a 60-line poem at 184 px when it draws over 1400.
  def lines(text)
    text.to_s.split("\n", -1).sum { |part| [1, (part.length.to_f / CHARS_PER_LINE).ceil].max }
  end

  def list_lines(block)
    rows = Array(block['items']).sum { |item| lines(item['text']) }
    [1, rows].max
  end

  def chat_lines(block)
    rows = Array(block['lines']).sum { |line| lines(line['text']) }
    [1, rows].max
  end

  def table_lines(block)
    rows = Array(block['rows']).length + (block['header'] ? 1 : 0)
    [1, rows].max
  end
end
