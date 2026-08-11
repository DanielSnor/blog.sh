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
  def key_choice(prompt)
    print prompt
    unless interactive?
      return $stdin.gets&.strip.to_s.downcase
    end

    key = read_key
    case key
    when :enter, :escape
      puts
      ''
    when String
      puts key
      key.downcase
    else
      puts
      ''
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
    unless interactive?
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
  def menu(items, hint: nil, allow_text: false, text_prompt: nil, initial: 0, numeric_pick: true)
    selected = initial.to_i.clamp(0, [items.size - 1, 0].max)
    offset = clamp_offset(selected, 0, [items.size, [term_height - 2 - (hint ? 2 : 0), 5].max].min, items.size)
    # Leave a couple of rows above the menu for whatever's already on
    # screen (the prompt that preceded it) plus the hint block, so the
    # menu doesn't try to claim the entire terminal height for itself.
    budget = term_height - 2 - (hint ? 2 : 0)
    window = [items.size, [budget, 5].max].min
    scrollable = items.size > window
    # +2 for the hint, not +1: a blank separator line precedes it, and
    # the cursor-up repaint math must count every physical line printed.
    lines = window + (hint ? 2 : 0)
    painted_once = false

    print "\e[?25l"
    loop do
      avail = term_width - 2 # "› " / "  " prefix
      print "\e[#{lines}A" if painted_once
      items[offset, window].each_with_index do |item, i|
        line =
          if (offset + i) == selected
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
        print "\e[2K#{line}\n"
      end
      if hint
        print "\e[2K\n"
        # Numeric rather than worded ("16-31 of 50") on purpose: this file
        # deliberately depends on nothing but io/console -- no config, no
        # locales -- and a bare range reads the same in every language.
        text = scrollable ? "#{hint} · #{offset + 1}-#{offset + window}/#{items.size}" : hint
        print "\e[2K#{paint(truncate_to_width(text, term_width), :dim)}\n"
      end
      painted_once = true

      case (key = read_key)
      when :up
        selected = (selected - 1) % items.size
        offset = clamp_offset(selected, offset, window, items.size)
      when :down
        selected = (selected + 1) % items.size
        offset = clamp_offset(selected, offset, window, items.size)
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
          print "\e[?25h#{text_prompt}#{key}"
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
  # for a post and coming back lands on the same row instead of at the
  # top -- and carries the height of the last frame, so a re-entry
  # repaints over it. A caller that PRINTS anything in between (a submenu,
  # an editor, a preview) must drop state[:lines] first, or the repaint
  # would land in the middle of whatever it printed.
  def browse(state, keys:, empty:, hot_keys: [], context: nil, search_hint: nil, cursor: true)
    query = state[:query].to_s
    searching = !state.delete(:searching).nil?
    state[:selected] = state[:selected].to_i
    state[:offset] = state[:offset].to_i
    rows, status = yield(query, searching)

    # Two of the lines are the status and the keys; one more is left for
    # whatever was on screen before, the same courtesy `menu` pays.
    window = [term_height - 4, 4].max
    lines = window + 2
    print "\e[#{state[:lines]}A" if state[:lines]
    state[:lines] = lines
    painted = false

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

      print "\e[#{lines}A" if painted
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
      # "\r\n", not "\n": this whole loop runs inside raw_screen, and raw
      # mode clears OPOST, so the kernel no longer turns a newline into
      # carriage-return + newline. With a bare LF every row starts where
      # the previous one ended and the screen reads as a diagonal
      # staircase. The carriage return has to be written by hand here.
      # Control characters are stripped at the last moment, not at every
      # call site that builds a row: a post title (or an imported feed
      # title, which keeps newlines inside a wrapped <title>) carrying a
      # newline or a tab painted its own line break inside the frame, so
      # the screen ended up taller than the cursor-up count and drifted
      # further with every keystroke. TAB is in the class too -- it is the
      # character the note above names, and a tab expands to whatever
      # stop width the terminal keeps, which no column arithmetic here
      # can predict. ESC is the one exception: the rows carry the colour
      # sequences this file wrote itself.
      out.each { |line| print "\e[2K#{sanitize_row(line)}\r\n" }
      painted = true

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
