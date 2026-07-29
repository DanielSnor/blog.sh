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
    lines = items.size + (hint ? 1 : 0)
    painted_once = false

    print "\e[?25l"
    loop do
      print "\e[#{lines}A" if painted_once
      items.each_with_index do |item, i|
        line = if i == selected
                 paint("› #{strip_ansi(item)}", :invert)
               else
                 "  #{item}"
               end
        print "\e[2K#{line}\n"
      end
      print "\e[2K#{paint(hint, :dim)}\n" if hint
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
