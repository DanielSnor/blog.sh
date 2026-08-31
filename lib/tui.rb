# frozen_string_literal: true

require 'io/console'

# lib/tui.rb -- the small terminal-UI layer under the CLI: colors,
# single-keypress choices, an inline arrow-key menu and a spinner. Pure
# stdlib (io/console), plain VT100 sequences on purpose -- no terminfo,
# no gems, no external binaries.
#
# Everything here degrades: in a real terminal (`interactive?`) the CLI
# gets highlights and single-key input, while piped/cron/scripted runs
# keep the exact line-based behavior the code always had -- callers
# branch on `interactive?` and keep their old path for the latter.
# Colors additionally honor NO_COLOR and TERM=dumb.
#
# Raw mode is entered per keystroke (STDIN.getch does that itself), never
# persistently -- so even a crash mid-menu can't leave the shell in raw
# mode, the classic TUI failure. The menu repaints a few lines in place
# with cursor-up; deliberately no alternate screen (the dialog should
# stay in the scrollback) and no SIGWINCH handling (the next keypress
# repaints with the current width, which is enough for a few lines).
module Tui
  module_function

  def interactive?
    $stdin.tty? && $stdout.tty?
  end

  def color?
    interactive? && ENV['NO_COLOR'].to_s.empty? && ENV['TERM'] != 'dumb'
  end

  CODES = { bold: 1, dim: 2, invert: 7, red: 31, green: 32, yellow: 33, cyan: 36 }.freeze

  def paint(text, *styles)
    return text.to_s unless color?

    "\e[#{styles.map { |s| CODES.fetch(s) }.join(';')}m#{text}\e[0m"
  end

  ANSI_RE = /\e\[[0-9;]*m/

  def strip_ansi(text)
    text.gsub(ANSI_RE, '')
  end

  # $stdout.winsize is [0, 0] when the terminal never reported a size
  # (some PTY setups, or a size query still in flight) -- 80 is the safe
  # assumption in that case, same as most terminals' own default.
  def term_width
    width = interactive? ? $stdout.winsize[1] : 0
    width.positive? ? width : 80
  rescue IOError, Errno::ENOTTY
    80
  end

  # Same idea as term_width, for the menu's scroll window below.
  def term_height
    height = interactive? ? $stdout.winsize[0] : 0
    height.positive? ? height : 24
  rescue IOError, Errno::ENOTTY
    24
  end

  # A codepoint is not a column: emoji and CJK render two columns wide,
  # and a row measured in characters wraps on a terminal that measured
  # it in columns -- which breaks the cursor-up repaint math one line at
  # a time (the Mastodon-roster posts are 🐘-separated lists, so this is
  # not exotic). Zero-width: combining marks, the variation selector,
  # ZWJ. An approximation of wcwidth, deliberately small.
  def char_width(ch)
    o = ch.ord
    return 0 if o == 0x200D || o == 0xFE0F || (o >= 0x0300 && o <= 0x036F) || (o >= 0x20D0 && o <= 0x20FF)
    if (o >= 0x1100 && o <= 0x115F) || (o >= 0x2E80 && o <= 0xA4CF) ||
       (o >= 0xAC00 && o <= 0xD7A3) || (o >= 0xF900 && o <= 0xFAFF) ||
       (o >= 0xFE30 && o <= 0xFE4F) || (o >= 0xFF00 && o <= 0xFF60) ||
       (o >= 0xFFE0 && o <= 0xFFE6) || (o >= 0x2600 && o <= 0x27BF) ||
       (o >= 0x1F000 && o <= 0x1FAFF)
      2
    else
      1
    end
  end

  def display_width(text)
    text.each_char.sum { |ch| char_width(ch) }
  end

  # Control characters never reach the screen: a tab expands to whatever
  # stop width the terminal keeps and a newline paints its own row, either
  # of which breaks the cursor-up arithmetic that every repaint depends on
  # -- and post titles come from feeds and exports, which carry both. ESC
  # is the exception: the rows carry the colour sequences this file wrote
  # itself. Applied in the two measuring helpers rather than at each call
  # site, so a row cannot reach the frame uncleaned.
  CONTROL_RE = /[\u0000-\u001A\u001C-\u001F\u007F]/.freeze

  def sanitize_row(text)
    text.to_s.gsub(CONTROL_RE, ' ')
  end

  # Truncates rather than wraps -- `menu` below repaints by moving the
  # cursor up exactly one line per item, so every item MUST render as
  # exactly one physical terminal row. On a narrow terminal (an SSH
  # client on a phone is the whole reason this matters) a wrapped line
  # would silently break that math and corrupt the repaint. Measured in
  # display COLUMNS (see char_width), not codepoints.
  def truncate_to_width(text, width)
    text = sanitize_row(text)
    return text if width <= 1 || display_width(text) <= width

    out = +''
    used = 0
    text.each_char do |ch|
      w = char_width(ch)
      break if used + w > width - 1

      out << ch
      used += w
    end
    "#{out}…"
  end

  # Wraps where the comment above truncates, for the one kind of row that
  # is not load-bearing for any repaint: a wizard's hint, which sits in a
  # frame with empty rows under it. Truncating those was silently costing
  # 7,391 characters across 42 of 54 hints -- and the part that went was
  # the end, which is where a hint says what it will cost you. One hint
  # explaining that the page size can never be changed again showed the
  # words "asked now and only now" and hid every reason why.
  #
  # German is the reason this cannot be solved by writing shorter: it runs
  # 15-20% longer than the same sentence in English, so a hint edited to
  # fit in one language goes on being cut in another.
  def wrap_to_width(text, width)
    text = sanitize_row(text)
    return [text] if width <= 1 || display_width(text) <= width

    lines = []
    current = +''
    split_long_words(text.split(' '), width).each do |word|
      if current.empty?
        current = +word
      elsif display_width("#{current} #{word}") <= width
        current << ' ' << word
      else
        lines << current
        current = +word
      end
    end
    lines << current unless current.empty?
    lines
  end

  # A word with no line it can fit on -- the lookup URL one hint tells you
  # to open, a deploy path -- is cut into pieces that do, rather than left
  # to overrun the row and be truncated away by the frame. Cutting a URL
  # across two lines is ugly; losing its tail is worse, because what is
  # left still looks like a whole address.
  def split_long_words(words, width)
    words.flat_map do |word|
      next word if display_width(word) <= width

      pieces = []
      piece = +''
      word.each_char do |ch|
        if display_width(piece + ch) > width
          pieces << piece
          piece = +ch
        else
          piece << ch
        end
      end
      pieces << piece unless piece.empty?
      pieces
    end
  end

  # The same, for text that carries colour: an ANSI string's length is not
  # its visible width, so only the printable characters are counted and the
  # escape sequences pass through untouched. A cut inside a colour gets a
  # reset appended, or the colour would bleed into the rest of the screen.
  #
  # Exists because menu rows are coloured for a reason -- the [DRAFT] /
  # [SCHEDULED] / [PINNED] markers -- and measuring them used to mean
  # stripping them.
  def truncate_ansi(text, width)
    text = sanitize_row(text)
    return text if width <= 1 || display_width(strip_ansi(text)) <= width

    out = +''
    visible = 0
    coloured = false
    text.scan(/\e\[[0-9;]*m|./m) do |token|
      if token.start_with?("\e")
        out << token
        coloured = true
      else
        w = char_width(token)
        break if visible + w > width - 1

        out << token
        visible += w
      end
    end
    "#{out}…#{coloured ? "\e[0m" : ''}"
  end

  # One keypress, normalized: :up/:down/:enter/:escape, or the character
  # itself. A lone Esc is distinguished from an escape sequence by
  # waiting a beat for the rest of the sequence -- the classic ambiguity
  # every TUI has to resolve. Ctrl-C arrives as a plain byte in raw mode
  # (no SIGINT), so it's turned back into an Interrupt here.
  def read_key
    ch = $stdin.getch
    case ch
    when "\r", "\n" then :enter
    when "\u0003" then raise Interrupt
    when "\e"
      return :escape unless IO.select([$stdin], nil, nil, 0.05)

      seq = $stdin.getch
      return :escape unless seq == '['

      read_csi
    else
      ch
    end
  end

  # Page Up is "\e[5~" and Home is "\e[1~": a sequence with a numeric
  # parameter and a terminator. Reading a single character after the "["
  # named the arrows correctly and left the rest of every other sequence
  # in the buffer, where the trailing "~" arrived a moment later as a
  # phantom keypress. So the parameters are drained up to the terminator
  # whether or not the key turns out to be one worth naming -- including
  # modified keys like "\e[1;5A" (Ctrl-Up), which read as their unmodified
  # selves rather than as junk.
  CSI_KEYS = { '5' => :page_up, '6' => :page_down,
               '1' => :home, '7' => :home, '4' => :end, '8' => :end }.freeze

  def read_csi
    params = +''
    loop do
      # A sequence that stops mid-way (a serial line dropping bytes) must
      # not block the terminal waiting for a terminator that isn't coming.
      return :other unless IO.select([$stdin], nil, nil, 0.05)

      ch = $stdin.getch
      case ch
      when 'A' then return :up
      when 'B' then return :down
      when 'H' then return :home
      when 'F' then return :end
      when '~' then return CSI_KEYS.fetch(params, :other)
      when /[0-9;]/
        params << ch
        return :other if params.length > 8
      else
        return :other
      end
    end
  end

  # A choice answered by a single keypress (no Enter) in a terminal, or
  # by a line of input when piped -- the returned string matches what the
  # line-based dialogs always produced ('' for Enter/Esc, the downcased
  # answer otherwise), so callers' case statements stay unchanged.
  # The keys line of a single-key prompt, folded to the terminal rather than
  # left to wrap wherever the width happens to run out -- which lands inside
  # an item, so "[r] rename slug" breaks after "rename" and the bracket
  # naming the key sits on the line above its own words. Items stay whole
  # and the trailing ": " stays with the last one, because that is where the
  # cursor waits for the keypress.
  #
  # FOLDED, not trimmed the way `browse`'s keys line is. There the dropped
  # items are ways to move around and a reader can guess them; here they are
  # the actions themselves, and dropping "[x] delete" would mean the action
  # does not exist on the one screen where the terminal is narrowest -- a
  # phone over SSH. Nothing is hidden, it is only stacked.
  #
  # Two spaces is the separator every one of these strings uses, in all
  # three locales. A prompt with no separator (or one that fits) comes back
  # byte for byte, so piped output and the tests over it are untouched.
  def fold_prompt(text, width)
    return text if width < 20 || display_width(strip_ansi(text)) <= width

    parts = text.split(/ {2,}/).reject(&:empty?)
    return text if parts.size < 2

    lines = []
    current = +''
    parts.each do |part|
      candidate = current.empty? ? part : "#{current}  #{part}"
      if !current.empty? && display_width(strip_ansi(candidate)) > width
        lines << current
        current = +'' << part
      else
        current = candidate
      end
    end
    lines << current
    lines.join("\n")
  end

  # Whether an answer from key_choice means yes.
  #
  # On a terminal key_choice returns one keypress, so testing the first
  # letter and testing the whole answer are the same thing. Down a pipe it
  # returns the entire LINE -- and there the callers that asked
  # `.start_with?(yes_char)` were accepting any word that happened to begin
  # with it. On a Czech site that made "ahoj" and "abort" both mean yes:
  # "abort" in particular reads as the exact opposite of what it did, and
  # the three places it reached were restoring an old version over the text
  # being worked on, compacting the publishing queue, and announcing a
  # backdated post -- the last of which cannot be taken back at all.
  #
  # Exact matches only, and the same set Wizard.confirm accepts: the
  # locale's own character, plus the three shipped ones so that habits
  # carried between languages keep working. A word is not a keypress.
  def yes?(answer)
    answer = answer.to_s.strip.downcase
    return false if answer.empty?

    answer == I18n.lookup('cli.confirm_yes_char').to_s.downcase || %w[y j a].include?(answer)
  end

  # escape: what the Esc key answers with. '' by default, which is what
  # Enter answers with too, and that is the wizard's own promise -- its
  # hint bar reads "Esc keep current", and for a question about a setting
  # keeping what is there IS the answer. It is wrong for a question that
  # DOES something: Esc is the key people press to back out, and at
  # style.rb's palette preview it built a page and uploaded it to the
  # live site instead. That one caller asks for a different answer here;
  # nobody else's case statement sees anything new.
  def key_choice(prompt, escape: '')
    unless interactive?
      print prompt
      answer = $stdin.gets
      # The terminal branch below closes the row in all three of its cases,
      # by echoing the key that was pressed. Down a pipe there is nothing to
      # echo -- the newline the answer arrived with is consumed by gets and
      # never reaches the output -- so the row stayed open and whatever was
      # said next landed on the question: "Zapsat tyhle změny? [a/N] Nic se
      # nezapsalo." on one line. Three callers had grown their own
      # `puts unless interactive?` to patch it from outside; the row belongs
      # to whoever printed the prompt, which is here.
      puts
      return answer&.strip.to_s.downcase
    end

    print fold_prompt(prompt, term_width)

    key = read_key
    case key
    when :enter
      puts
      ''
    when :escape
      puts
      escape
    when String
      puts key
      key.downcase
    else
      puts
      ''
    end
  end

  # A line of input where Tab completes file names. The import wizard asks
  # for the path to an export somebody has just downloaded, and without this
  # the only way in is typing it from memory, correctly, the first time --
  # for a name like `twitter-2026-08-13-a1b2c3.zip` sitting three
  # directories down.
  #
  # readline is a DEFAULT gem: it ships with Ruby and installs nothing, so
  # "no gems, no lockfile" still holds. It can nevertheless be absent (a Ruby
  # built --without-readline), so a failed require degrades to the ordinary
  # prompt rather than taking the wizard down on its first question. Piped
  # input skips it too -- there is no terminal to complete against.
  def path_line(prompt)
    return plain_line(prompt) unless interactive? && readline?

    # Word breaks off on purpose. Readline splits on spaces by default, and
    # plenty of exports sit in a directory whose name has one -- completing
    # only the fragment after the space finds nothing and reads as broken.
    # With no break characters the whole line is the word, which is what a
    # path is.
    Readline.completion_append_character = nil
    Readline.completer_word_break_characters = ''
    Readline.completion_proc = ->(str) { complete_path(str) }
    Readline.readline(prompt, false)
  end

  def plain_line(prompt)
    print prompt
    $stdin.gets
  end

  # Candidates are returned in the shape the line was typed in -- a "~" that
  # was typed stays a "~". Handing back the expanded form instead would
  # rewrite the visible line into an absolute path on the first Tab, which
  # is disorienting when the answer is about to be echoed back in an error
  # message. Directories get their trailing slash so a second Tab descends.
  def complete_path(str)
    typed = str.to_s
    home = Dir.home
    # The typed part is a NAME as far as brackets and braces go. "Takeout
    # [1]" is what a second download of an export is called, and read as a
    # character class it completes to nothing -- which, with no append
    # character, looks exactly like "there is nothing there" and leaves the
    # author guessing whether the path is wrong. A "*" or a "?" is left
    # live: those somebody types on purpose, the way they would at a shell
    # prompt. (PathGlob.literal is the full-strength sibling, for patterns
    # where nothing at all is meant as a wildcard.)
    escaped = typed.sub(/\A~/, home).gsub(/[\[\]{}]/) { |char| "\\#{char}" }
    pattern = typed.empty? ? '*' : "#{escaped}*"
    Dir.glob(pattern).map do |hit|
      shown = typed.start_with?('~') ? hit.sub(/\A#{Regexp.escape(home)}/, '~') : hit
      File.directory?(hit) ? "#{shown}/" : shown
    end
  rescue StandardError
    # A malformed glob (an unbalanced brace in a half-typed path) must not
    # kill the prompt mid-question.
    []
  end

  def readline?
    return @readline unless @readline.nil?

    @readline = begin
      require 'readline'
      true
    rescue LoadError
      false
    end
  end

  # A line of input that never appears on screen -- for the one dialog in
  # this engine that asks for a credential (./setup.sh). Echo is restored
  # by noecho's own ensure, so an interrupt mid-answer can't leave the
  # terminal silent, which is the classic way a password prompt breaks a
  # shell.
  #
  # Piped input skips the ceremony: there is no terminal to echo to, and
  # $stdin.noecho would raise on a pipe.
  def password(prompt)
    print prompt
    # ⚠️ $stdin.tty?, not interactive?. noecho acts on STDIN and nothing
    # else, while interactive? also demands that stdout be a terminal --
    # so `./setup.sh | tee setup.log`, which is what somebody does when
    # they want a record of a first install, took the branch below and the
    # terminal echoed the access token in clear text, into the scrollback
    # and over anybody's shoulder. The question is whether the keyboard is
    # a terminal, and only that.
    unless $stdin.tty?
      value = $stdin.gets.to_s.chomp
      return value
    end

    value = $stdin.noecho(&:gets).to_s.chomp
    puts
    value
  end

  # Clamps a scrolling window of `window` items (out of `total`) so that
  # `selected` stays inside it, moving the window by the minimum amount
  # rather than re-centering it. Wraparound (selected jumping from the
  # last item to the first, or vice versa) resolves correctly for free:
  # e.g. selected=0 is always < any positive offset, so the window snaps
  # back to the top without a special case.
  def clamp_offset(selected, offset, window, total)
    return 0 if total <= window
    return selected if selected < offset
    return selected - window + 1 if selected >= offset + window

    offset
  end

  # Inline arrow-key menu. Returns the selected Integer index, a String
  # when the user typed free text instead (allow_text -- picking a post
  # by slug), or nil on Esc/q. Digits 1-9 select directly, relative to
  # the currently visible rows (not the full list -- see below). Only
  # called in interactive mode -- non-interactive callers keep their
  # numbered lists.
  #
  # Scrolls when there are more items than fit on screen -- a hardcoded
  # RECENT_LIST_COUNT-style cap stops being the only way to keep a list
  # usable once picking from thousands of posts (sean.cz-scale) is on
  # the table. The window size is fixed for the life of one menu call
  # (no SIGWINCH handling, same as term_width already assumes elsewhere
  # in this file) so the cursor-up repaint math stays valid.
  # `initial:` is where the cursor STARTS -- the current value in a
  # settings menu. Without it every menu opened on row 0, and setup.sh's
  # promise that Enter keeps the current value was false: Enter on the
  # language menu switched an English site to Czech, because cs sorts
  # first.
  # `header:` are rows that belong ABOVE the list, inside the frame -- the
  # question a picker is answering, most often. They used to be printed by
  # the caller just before calling this, which worked while the menu
  # repainted in place and stopped working the moment it started painting
  # from the top of the viewport: the frame would land on top of them.
  # `context:` is a lambda given the selected index, returning one line to
  # show under the cursor -- what the row IS, when the row itself can only
  # say what it is called. It is called for the selected row only, so the
  # cost is one lookup per keypress rather than one per item. Same idea and
  # same shape as `browse`'s, which had it first.
  def menu(items, hint: nil, header: [], allow_text: false, text_prompt: nil, initial: 0,
           numeric_pick: true, context: nil)
    selected = initial.to_i.clamp(0, [items.size - 1, 0].max)
    header = Array(header)
    # The rows the list cannot have: the header, the blank line under the
    # list and the hint, plus one so the frame never quite fills the window
    # (a full-height frame leaves the cursor with nowhere to stand, which
    # matters for allow_text, where a line gets typed under it).
    budget = term_height - header.size - (hint ? 2 : 0) - 1
    window = [items.size, [budget, 3].max].min
    offset = clamp_offset(selected, 0, window, items.size)

    loop do
      avail = term_width - 2 # "› " / "  " prefix
      ctx = items.empty? || context.nil? ? nil : context.call(selected)
      # The context line comes out of the WINDOW's budget, not out of the
      # list: window is already the smaller of "what fits" and "how many
      # there are", so taking one off it hid a row whenever the list was
      # shorter than the screen -- two versions showed one.
      row_window = ctx ? [items.size, [budget - 1, 2].max].min : window
      offset = clamp_offset(selected, offset, row_window, items.size)
      rows = header.dup
      items[offset, row_window].to_a.each_with_index do |item, i|
        rows << if (offset + i) == selected
                  # Stripped here, and only here: the whole row is painted
                  # :invert, and a colour's own reset inside it would end the
                  # inversion mid-line. Being the inverted row is the stronger
                  # signal anyway.
                  paint("› #{truncate_to_width(strip_ansi(item), avail)}", :invert)
                else
                  # Colour kept, so the state markers read the same in a picker as
                  # they do in `list` -- the picker used to be the one place that
                  # showed them in plain grey.
                  "  #{truncate_ansi(item, avail)}"
                end
        rows << paint("      #{truncate_to_width(ctx, avail - 4)}", :dim) if ctx && (offset + i) == selected
      end
      if hint
        rows << ''
        # Numeric rather than worded ("16-31 of 50") on purpose: this file
        # deliberately depends on nothing but io/console -- no config, no
        # locales -- and a bare range reads the same in every language.
        # Counted from row_window, not window: with a context line under the
        # cursor one fewer row is shown, and the counter has to say so.
        shown = [row_window, items.size - offset].min
        counted = items.size > row_window ? "#{hint} · #{offset + 1}-#{offset + shown}/#{items.size}" : hint
        # The counter goes first when the row will not fit, and after that
        # fit_keys drops whole keys from the MIDDLE rather than cutting the
        # line wherever the width runs out. A German hint is long enough
        # that a plain cut took "Esc" with it -- the way out of the menu,
        # missing from the one row that lists the ways out. Knowing which
        # page you are on is worth less than knowing how to leave.
        text = display_width(counted) <= term_width ? counted : fit_keys(hint, term_width)
        rows << paint(text, :dim)
      end
      print "\e[?25l"
      frame(rows, keep_last: hint ? 2 : 0)

      case (key = read_key)
      when :up
        selected = (selected - 1) % items.size
        offset = clamp_offset(selected, offset, window, items.size)
      when :down
        selected = (selected + 1) % items.size
        offset = clamp_offset(selected, offset, window, items.size)
      when :page_up, :page_down
        # Paging moves the window, not just the cursor -- the rule `browse`
        # already follows: leaving the offset to clamp_offset scrolls a
        # single line and parks the cursor on the edge, which reads as a
        # broken Page Down. And no wraparound, unlike the arrows: a page is
        # a distance, and one that would land past the end stops at the end.
        # read_key has named these keys since it learned to drain escape
        # sequences; this menu was simply throwing them away, so a picker
        # over a long archive could only be walked one row at a time.
        delta = key == :page_up ? -window : window
        selected = (selected + delta).clamp(0, [items.size - 1, 0].max)
        offset = (offset + delta).clamp(0, [items.size - window, 0].max)
      when :home
        selected = 0
        offset = 0
      when :end
        selected = [items.size - 1, 0].max
        offset = [items.size - window, 0].max
      when :enter then return selected
      when :escape then return nil
      when String
        # Without allow_text, single keys keep their shortcuts: q/0 cancel,
        # 1-9 pick a visible row directly. With allow_text those characters
        # have to be typeable -- slugs beginning with a digit (or q) were
        # impossible to enter, and the first keypress silently retargeted
        # to a visible row instead -- so every alphanumeric key starts a
        # typed line, and Enter resolves it: a plain in-range number picks
        # that row (the quick pick, one keystroke later), an empty line
        # cancels, anything else is the slug. Same contract as the piped,
        # non-interactive picker.
        if !allow_text && %w[q 0].include?(key)
          return nil
        elsif !allow_text && key =~ /\A[1-9]\z/
          relative = key.to_i - 1
          index = offset + relative
          return index if relative < window && index < items.size
        elsif allow_text && key =~ /\A[[:alnum:]]\z/
          # On its own line under the frame, which the frame leaves room
          # for: typing onto the last painted row would put the answer
          # inside the hint, and the frame would repaint over it.
          print "\r\n\e[?25h#{text_prompt}#{key}"
          rest = $stdin.gets.to_s.strip
          line = "#{key}#{rest}"
          # numeric_pick: false for menus whose rows carry no numbers and
          # whose VALUES can be numbers (tag names like "365") -- there a
          # typed number must mean the text, not a row.
          return line.to_i - 1 if numeric_pick && line =~ /\A\d+\z/ && (1..items.size).cover?(line.to_i)

          return line
        end
      end
    end
  ensure
    print "\e[?25h"
    # Close the row the frame deliberately left open. frame ends its last
    # line without a newline so the cursor can stand on it while the menu
    # waits -- but the menu is done waiting now, and everything the caller
    # says next was landing ON the keys line: "Esc zpětZrušeno." Every
    # picker in the wizard did it, because every picker ends here.
    #
    # One newline, not two. It closes the line and no more; a caller that
    # wants the blank line this CLI puts before a result already writes it,
    # and with the row closed that `puts` finally produces the blank it was
    # always meant to be instead of the line break nobody got.
    puts
  end

  # Two strings on one line, the second flush right -- the status line of
  # `browse` below, where the left half says what is being shown and the
  # right half says where in it you are.
  def pad_between(left, right, width)
    gap = width - display_width(strip_ansi(left)) - display_width(strip_ansi(right))
    return truncate_to_width(left, width) if gap < 1

    "#{left}#{' ' * gap}#{right}"
  end

  # A screen for walking a long list: the scrolling window of `menu`, plus
  # a status line, a live search fed by the caller, and single keys the
  # caller handles itself.
  #
  # The block IS the view -- given the current query (and whether it is
  # still being typed) it returns [rows, status], where status is either
  # one string or a [left, right] pair; the position counter joins the
  # right-hand side. Everything that decides
  # what ends up on screen (filters, search, ordering, every word of it)
  # stays with the caller; this method paints and reads keys, nothing
  # else. Which is also why the search here does not know what a match is:
  # `browse` collects the characters, the caller decides what they mean.
  #
  # Returns [:enter, index], [:key, character, index] or nil on Esc.
  # `state` is the caller's to keep between calls -- leaving the screen
  # for a post and coming back lands on the same row instead of at the top.
  #
  # It paints through `frame`, from the top of the viewport, like every
  # other screen here. It used to repaint by counting its own lines and
  # moving the cursor up over them, which was correct on its own and wrong
  # as soon as it was entered FROM a screen: the wizard's frame was above
  # it, the cursor-up landed in the middle of that frame, and walking into
  # the archive and back out scrolled the view by fourteen lines. Painting
  # from the top has no such arithmetic to get wrong, and it also retires
  # the rule that a caller printing anything in between had to clear
  # state[:lines] first.
  def browse(state, keys:, empty:, hot_keys: [], context: nil, search_hint: nil, cursor: true)
    query = state[:query].to_s
    searching = !state.delete(:searching).nil?
    state[:selected] = state[:selected].to_i
    state[:offset] = state[:offset].to_i
    rows, status = yield(query, searching)

    # Two of the lines are the status and the keys; one more is left for
    # whatever was on screen before, the same courtesy `menu` pays.
    window = [term_height - 4, 4].max

    print "\e[?25l"
    # Raw for the WHOLE screen, not per keystroke: between two getch
    # calls the terminal used to fall back to cooked mode with echo on,
    # and on a large archive each search keystroke re-filters thousands
    # of rows -- keys arriving in that window were echoed into the frame
    # by the kernel, and a held-down Backspace was eaten as line editing.
    # The ensure (and getch's own per-key raw) keep a crash from leaving
    # the shell raw.
    raw_screen do
    loop do
      state[:selected] = 0 if state[:selected].to_i >= rows.size
      ctx = rows.empty? || context.nil? ? nil : context.call(state[:selected])
      row_window = ctx ? window - 1 : window
      state[:offset] = clamp_offset(state[:selected].to_i, state[:offset].to_i, row_window, rows.size)

      avail = term_width - 2
      shown = rows[state[:offset], row_window] || []
      out = []
      shown.each_with_index do |row, i|
        index = state[:offset] + i
        if cursor && index == state[:selected]
          out << paint("› #{truncate_to_width(strip_ansi(row), avail)}", :invert)
          out << paint("      #{truncate_to_width(ctx, avail - 4)}", :dim) if ctx
        else
          out << "  #{truncate_ansi(row, avail)}"
        end
      end
      out << paint("  #{truncate_to_width(empty, avail)}", :dim) if rows.empty?
      out << '' while out.size < window
      position = rows.size > row_window ? "#{state[:offset] + 1}-#{state[:offset] + shown.size}/#{rows.size}" : ''
      left, right = Array(status)
      out << paint(pad_between(left.to_s, [right, position].compact.reject(&:empty?).join('  ·  '), term_width), :bold)
      out << paint(fit_keys(searching ? search_hint.to_s : keys, term_width), :dim)
      # frame writes the rows in one go, ends the last one without a
      # newline (a full-height frame that ends in one scrolls the view by
      # exactly the thing this avoids) and sanitizes control characters --
      # a post title carrying a newline or a tab used to paint its own line
      # break inside the frame and the screen drifted further with every
      # keystroke. The keys are the two rows that must survive a window too
      # short to hold everything.
      frame(out, keep_last: 2)

      move = lambda do |delta|
        next if rows.empty?

        state[:selected] = (state[:selected] + delta) % rows.size
      end

      # Paging moves the window, not just the cursor: leaving the offset to
      # clamp_offset would scroll by a single line and land the cursor at
      # the bottom edge, which reads as a broken Page Down rather than as a
      # page.
      page = lambda do |delta|
        next if rows.empty?

        state[:selected] = (state[:selected] + delta).clamp(0, rows.size - 1)
        state[:offset] = (state[:offset] + delta).clamp(0, [rows.size - row_window, 0].max)
      end

      key = read_key
      case key
      when :up then move.call(-1)
      when :down then move.call(1)
      when :page_up then page.call(-row_window)
      when :page_down then page.call(row_window)
      when :home then state[:selected] = 0
      when :end then state[:selected] = [rows.size - 1, 0].max
      when :enter
        # Enter while typing keeps the search and hands the keys back;
        # only then does it open a post. Otherwise the first Enter after a
        # search would open whatever the cursor happened to sit on.
        if searching
          searching = false
          rows, status = yield(query, false)
        elsif !rows.empty?
          return [:enter, state[:selected]]
        end
      when :escape
        return nil unless searching

        searching = false
        query = ''
        state[:query] = ''
        state[:selected] = 0
        state[:offset] = 0
        rows, status = yield('', false)
      when String
        if searching
          query = edit_query(query, key)
          # A character outside ASCII arrives one byte at a time in raw
          # mode, so a query mid-diacritic is not yet text -- folding it
          # would raise. The next byte completes it; until then the screen
          # simply doesn't move.
          next unless query.valid_encoding?

          state[:query] = query
          state[:selected] = 0
          state[:offset] = 0
          rows, status = yield(query, true)
        elsif hot_keys.include?(key)
          return [:key, key, rows.empty? ? nil : state[:selected]]
        elsif key == ' '
          # Space pages when nobody has claimed it -- which is what it does
          # in `less`, and what the preview screen wants.
          page.call(row_window)
        end
      end
    end
    end
  ensure
    print "\e[?25h"
  end

  # A screen that stays put. The frame is painted from the top of the
  # viewport, over whatever the last frame left there, and the terminal
  # never scrolls -- so a dialog that used to reprint its whole list after
  # every keypress now lives on the same rows from beginning to end.
  #
  # NOT the alternate screen (\e[?1049h). That plane is discarded on exit,
  # and this CLI prints things worth keeping: a draft's address, what was
  # uploaded, what refused. Here the last frame stays exactly where it was
  # drawn and the scrollback above it is never touched -- which is the same
  # promise `pause_and_clear` has always made.
  #
  # The rows are joined rather than printed one by one, and the last one
  # carries no line ending: printing term_height lines each with a newline
  # scrolls the view by one, and a screen that scrolls by one per repaint
  # is the very thing this exists to stop. \e[J clears whatever the
  # previous, taller frame left below this one.
  #
  # \r\n, not \n -- callers paint inside raw_screen, where OPOST is off and
  # the kernel no longer turns a newline into carriage-return plus newline.
  # `keep_last` names the rows that must survive a window too short to hold
  # the frame -- the keys, normally. Without it the frame is simply cut at
  # the bottom, which is where the way out is written: a 14-row frame in a
  # 12-row window lost "Esc back" and the screen became a trap. What gets
  # dropped instead is the end of the middle, which is a list the cursor can
  # still scroll through.
  def frame(lines, keep_last: 0)
    width = term_width
    height = term_height
    rows = if lines.size <= height || keep_last.zero?
             lines.first(height)
           else
             tail = lines.last([keep_last, height].min)
             lines.first(height - tail.size) + tail
           end
    body = rows.map { |line| "\e[2K#{truncate_ansi(sanitize_row(line.to_s), width)}" }
    print "\e[H#{body.join("\r\n")}\e[J"
  end

  # Everything below the frame, cleared. For leaving a screen behind before
  # an operation that prints its own long output (a build, a deploy): the
  # frame stays as the last thing on screen and the output starts under it,
  # instead of the two overwriting each other row by row.
  def frame_end(lines)
    frame(lines)
    print "\r\n"
  end

  # One screen's worth of terminal, held for as long as the caller needs it.
  # The queue was the first of these; the rest of the CLI follows, so the
  # loop that was written inside it lives here instead of being copied.
  #
  # The caller drives it: `paint` puts a frame up, `key` waits for a
  # keypress, `leave` hands the terminal over to something that prints more
  # than a frame can hold (a build, a publish) and takes it back afterwards.
  # Nothing here knows what a queue or a post is -- it knows rows, keys and
  # who owns the terminal right now.
  #
  # A window RESIZED WHILE THE SCREEN WAITS is the reason `key` is not just
  # read_key. A trap alone would not do: $stdin.getch blocks in the kernel
  # and the handler runs but the read stays parked, so the frame would only
  # straighten on the next keypress. The handler therefore writes a byte to
  # a pipe this waits on alongside the terminal -- the self-pipe every
  # event loop ends up with -- and `key` answers :resize, which every caller
  # treats as "paint again".
  class Screen
    def initialize
      @lines = []
      @resize_r, @resize_w = IO.pipe
      @previous = Signal.trap('WINCH') do
        begin
          @resize_w.write_nonblock('.')
        rescue StandardError
          nil
        end
      end
    end

    def paint(lines, keep_last: 0)
      @lines = lines
      Tui.frame(lines, keep_last: keep_last)
    end

    def key
      Tui.raw_screen do
        print "\e[?25l"
        ready, = IO.select([$stdin, @resize_r])
        if ready.include?(@resize_r)
          begin
            @resize_r.read_nonblock(256)
          rescue StandardError
            nil
          end
          :resize
        else
          Tui.read_key
        end
      ensure
        print "\e[?25h"
      end
    end

    # The frame stays as the last thing on screen and the output starts
    # under it, rather than the two overwriting each other row by row. The
    # pause is what keeps the output readable: without it the next frame
    # would wipe whatever was just said.
    def leave(pause_message)
      Tui.frame_end(@lines)
      result = yield
      Tui.pause_and_clear(pause_message)
      result
    end

    def close
      Signal.trap('WINCH', @previous || 'DEFAULT')
      @resize_r.close
      @resize_w.close
    rescue StandardError
      nil
    end
  end

  # Runs a screen and always gives the signal handler and the pipe back,
  # including when the block aborts the process or the user interrupts it.
  def screen
    scr = Screen.new
    yield scr
  ensure
    scr&.close
  end

  # $stdin.raw with a floor: a stdin that cannot do raw (not a real
  # terminal) just runs the block -- getch then does its own per-key raw
  # exactly as before.
  def raw_screen(&block)
    entered = false
    $stdin.raw do
      entered = true
      return block.call
    end
  rescue StandardError
    # Only a stdin that could not enter raw mode falls through to the
    # unmodified block. Without the flag, an exception raised INSIDE the
    # block was caught here too and the block ran a SECOND time -- every
    # keystroke and every repaint replayed on the way out of a screen
    # that had already failed once.
    raise if entered

    yield
  end

  # The keys line, trimmed to fit rather than cut off: the first entry
  # (how to move) and the last (the way out) survive to the narrowest
  # terminal, and the ones in between drop from the right, which is why
  # the locale strings put the least essential last. Losing "Esc back" off
  # the edge of an 80-column window is how a screen becomes a trap.
  def fit_keys(text, width)
    parts = text.to_s.split(' · ')
    parts.delete_at(parts.size - 2) while parts.size > 2 && display_width(parts.join(' · ')) > width
    truncate_to_width(parts.join(' · '), width)
  end

  BACKSPACE = ["\u007F", "\b"].freeze

  # Backspace deletes a whole character rather than a byte -- deleting
  # half of "č" would leave the query unparseable until another byte
  # arrived, which for the person typing looks like a wedged screen.
  # Other control characters are dropped: a stray Tab or Ctrl-key means
  # nothing in a search box, and letting one into the string would put an
  # unprintable character on the status line.
  def edit_query(query, key)
    if BACKSPACE.include?(key)
      return query.sub(/.\z/m, '') if query.valid_encoding?

      return query.b[0..-2].to_s.force_encoding(Encoding::UTF_8)
    end
    return query if key.b.getbyte(0).to_i < 0x20

    (query.b + key.b).force_encoding(Encoding::UTF_8)
  end

  # Waits for a single keypress, then clears the visible screen -- \e[2J
  # only clears the current viewport, not the terminal's scrollback (the
  # same thing the `clear` shell command does), so this doesn't conflict
  # with the "stay in scrollback" principle above. Used between wizard
  # actions so each one's own result is read on a clean screen instead
  # of piling up underneath every previous run's menu and output.
  #
  # Deliberately no leading blank line of its own: every wizard-reachable
  # command already ends its output with exactly one trailing blank line
  # (a convention that predates this method, from the original piped-only
  # CLI -- see e.g. the comment above "Done:" in publish_draft). Adding
  # another blank here would just double it up.
  def pause_and_clear(message)
    return unless interactive?

    print paint(message, :dim)
    read_key
    print "\e[2J\e[H"
  end

  # A braille spinner around a slow block (network calls). Piped runs
  # just run the block -- no escape codes end up in logs.
  def spinner(message)
    return yield unless interactive?

    stop = false
    thread = Thread.new do
      frames = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]
      i = 0
      until stop
        print "\r\e[2K#{frames[i % frames.size]} #{message}"
        i += 1
        sleep 0.1
      end
    end
    result = yield
    result
  ensure
    if thread
      stop = true
      thread.join
      print "\r\e[2K"
    end
  end
end
