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

  # Truncates rather than wraps -- `menu` below repaints by moving the
  # cursor up exactly one line per item, so every item MUST render as
  # exactly one physical terminal row. On a narrow terminal (an SSH
  # client on a phone is the whole reason this matters) a wrapped line
  # would silently break that math and corrupt the repaint.
  def truncate_to_width(text, width)
    return text if width <= 1 || text.length <= width

    "#{text[0, width - 1]}…"
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

      case $stdin.getch
      when 'A' then :up
      when 'B' then :down
      else :other
      end
    else
      ch
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

  # Inline arrow-key menu. Returns the selected Integer index, a String
  # when the user typed free text instead (allow_text -- picking a post
  # by slug), or nil on Esc/q. Digits 1-9 select directly. Only called
  # in interactive mode -- non-interactive callers keep their numbered
  # lists.
  def menu(items, hint: nil, allow_text: false, text_prompt: nil)
    selected = 0
    # +2 for the hint, not +1: a blank separator line precedes it, and
    # the cursor-up repaint math must count every physical line printed.
    lines = items.size + (hint ? 2 : 0)
    painted_once = false

    print "\e[?25l"
    loop do
      avail = term_width - 2 # "› " / "  " prefix
      print "\e[#{lines}A" if painted_once
      items.each_with_index do |item, i|
        plain = truncate_to_width(strip_ansi(item), avail)
        line = i == selected ? paint("› #{plain}", :invert) : "  #{plain}"
        print "\e[2K#{line}\n"
      end
      if hint
        print "\e[2K\n"
        print "\e[2K#{paint(truncate_to_width(hint, term_width), :dim)}\n"
      end
      painted_once = true

      case (key = read_key)
      when :up then selected = (selected - 1) % items.size
      when :down then selected = (selected + 1) % items.size
      when :enter then return selected
      when :escape, 'q', '0' then return nil
      when String
        if key =~ /\A[1-9]\z/ && key.to_i <= items.size
          return key.to_i - 1
        elsif allow_text && key =~ /\A[[:alnum:]]\z/
          print "\e[?25h#{text_prompt}#{key}"
          rest = $stdin.gets.to_s.strip
          return "#{key}#{rest}"
        end
      end
    end
  ensure
    print "\e[?25h"
  end

  # Waits for a single keypress, then clears the visible screen -- \e[2J
  # only clears the current viewport, not the terminal's scrollback (the
  # same thing the `clear` shell command does), so this doesn't conflict
  # with the "stay in scrollback" principle above. Used between wizard
  # actions so each one's own result is read on a clean screen instead
  # of piling up underneath every previous run's menu and output.
  def pause_and_clear(message)
    return unless interactive?

    puts
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
