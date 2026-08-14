# frozen_string_literal: true

require_relative 'tui'
require_relative 'i18n'
require_relative 'config_writer'

# lib/wizard.rb -- the parts ./setup.sh and ./style.sh both need: asking a
# question that can be skipped, choosing from a list, and the one moment
# at the end where everything collected so far is shown as a diff and
# written or thrown away.
#
# Extracted rather than copied because the two wizards will be edited at
# different times for different reasons, and the half of them that is
# identical is exactly the half where a divergence would be invisible --
# two prompt loops that disagree about what Enter means, or one of them
# quietly losing the "nothing is written until you say so" guarantee.
#
# The contract that guarantee rests on: a wizard collects into
# ConfigWriter objects, which touch no disk at all until save!, and this
# module is the only place that calls it. An interrupt anywhere before
# that leaves the install exactly as it was found.
#
# Strings that belong to a particular wizard stay with that wizard; only
# the ones this module says in its own voice live under `wizard.*`.
module Wizard
  module_function

  def t(key, **vars)
    I18n.t("wizard.#{key}", **vars)
  end

  # A question with its current value as the default. Enter keeps it,
  # which is what makes every question skippable and the whole run
  # re-runnable over a config somebody already has a site on.
  #
  # `suggested:` changes only the default's label: "Now:" claims somebody
  # chose this value, and for a template placeholder or a detected
  # timezone nobody did. Enter takes what is shown either way.
  #
  # EOF means "keep everything from here on", not "answer empty": a piped
  # run that runs out of input must not silently blank the rest of the
  # config, so it raises and the caller's handler reports that nothing
  # was written.
  # The rows a question keeps above it: the section being filled in and the
  # answers already given inside it. A frame repaints over the last one, so
  # without this a setup run would show one question at a time with no
  # record of what has already been decided -- which for a wizard whose
  # whole job is filling in a config is the thing you most need on screen.
  # The caller owns it: it starts a section, appends as answers land, and
  # clears it when the section ends.
  def context
    @context ||= []
  end

  def context=(rows)
    @context = Array(rows)
  end

  def remember(row)
    context << row
  end

  # An answer, in the form it goes back on screen as: the question it
  # answered and what it now says. Recorded by `ask` itself rather than by
  # each of the two wizards, so every question in ./setup.sh and ./style.sh
  # builds the running record without either of them being changed.
  def record(label, value)
    shown = value.to_s.empty? ? t('empty_value') : value.to_s
    remember(format('  %s %s', Tui.paint("#{label}:", :dim), Tui.truncate_to_width(shown, 60)))
  end

  # The frame a question stands on, ending in a blank row for the prompt --
  # frame leaves the cursor at the end of its last line, so the prompt and
  # what gets typed after it land there.
  #
  # The record is trimmed from the TOP to whatever the window has room for:
  # a long section would otherwise push its own question off the bottom,
  # and the answers worth seeing are the ones just given.
  def question_frame(label, hint, problem)
    room = [Tui.term_height - 6, 2].max
    rows = context.size > room ? context.last(room) : context.dup
    rows << '' unless rows.empty?
    rows << Tui.paint(label, :bold)
    # Wrapped, not one row: the frame truncates every row it is given, and
    # a hint is the one thing here written to be read rather than scanned.
    # The three spaces go on each line so the block lines up under the
    # question instead of the continuation starting at the margin.
    indented(hint, :dim) { |row| rows << row }
    indented(problem, :red) { |row| rows << row }
    rows << ''
    Tui.frame(rows)
  end

  def indented(text, colour)
    return if text.nil? || text.to_s.empty?

    Tui.wrap_to_width(text.to_s, Tui.term_width - 3).each do |line|
      yield Tui.paint("   #{line}", colour)
    end
  end

  # `record:` is false when a caller answers for the record itself --
  # ask_valid asks repeatedly and only the accepted answer belongs there.
  def ask(label, current, hint: nil, suggested: false, problem: nil, record: true)
    shown = current.to_s.empty? ? t('empty_value') : current.to_s
    prompt = t(suggested ? 'prompt_with_suggestion' : 'prompt_with_current', current: shown)

    if Tui.interactive?
      question_frame(label, hint, problem)
      print prompt
    else
      puts Tui.paint(label, :bold)
      puts Tui.paint("   #{hint}", :dim) if hint
      puts Tui.paint("   #{problem}", :red) if problem
      print prompt
    end
    answer = $stdin.gets
    raise Interrupt if answer.nil?

    answer = answer.strip
    puts unless Tui.interactive?
    value = answer.empty? ? current : answer
    self.record(label, value) if record && Tui.interactive?
    value
  end

  # The same, with a check that runs before the answer is accepted. The
  # block returns nil when happy or the sentence explaining what is
  # wrong -- said immediately, while the answer is still in mind, rather
  # than saved up for a validation report at the end.
  # The complaint travels INTO the next frame rather than being printed
  # under the answer: printed, the repaint would wipe it before it had been
  # read, and a validation message nobody sees is a question that seems to
  # refuse answers for no reason.
  def ask_valid(label, current, hint: nil, suggested: false)
    problem = nil
    loop do
      answer = ask(label, current, hint: hint, suggested: suggested, problem: problem, record: false)
      if answer == current || answer.to_s.empty?
        record(label, answer) if Tui.interactive?
        return answer
      end

      problem = yield(answer)
      unless problem
        record(label, answer) if Tui.interactive?
        return answer
      end
    end
  end

  # Multi-line text through $EDITOR -- for the values that are prose (a
  # bio, a footer note) and that a single-line prompt would turn into an
  # unreadable ribbon. Returns the current value unchanged if the editor
  # is unavailable or the file comes back empty.
  def ask_text(label, current, hint: nil, comment: nil)
    if Tui.interactive?
      question_frame(label, hint, nil)
    else
      puts Tui.paint(label, :bold)
      puts Tui.paint("   #{hint}", :dim) if hint
    end
    unless Tui.interactive?
      # Piped runs have no editor to open; a single line is still better
      # than refusing the setting outright.
      print t('prompt_with_current', current: current.to_s.empty? ? t('empty_value') : current.to_s)
      answer = $stdin.gets
      raise Interrupt if answer.nil?

      answer = answer.strip
      puts
      return answer.empty? ? current : answer
    end

    return current unless confirm(t('edit_in_editor'))

    # No blank line of its own on the way out. Every caller of this ends its
    # section with one, and the branch just above -- the one where the
    # editor is declined -- has never printed anything, so the two paths out
    # of the same question were producing a different number of blank lines:
    # one after "no", two after "yes". The row is already closed (key_choice
    # closed it, and a full-screen editor restores the cursor where it found
    # it), so there is nothing here left to close either.
    edited = edit_in_editor(current.to_s, comment)
    edited.to_s.strip.empty? ? current : edited.strip
  end

  # The editor handoff, same shape ./blog.sh add uses: a temp file, the
  # user's $EDITOR, and comment lines stripped on the way back so the
  # instructions can never end up in the config.
  def edit_in_editor(body, comment)
    require 'tmpdir'
    require 'shellwords'
    editor = ENV['VISUAL'] || ENV['EDITOR'] || 'nano'
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'value.txt')
      header = comment ? comment.lines.map { |l| "// #{l.chomp}\n" }.join : ''
      File.write(path, "#{header}#{body}")
      system("#{editor} #{Shellwords.escape(path)}")
      File.read(path).lines.reject { |l| l.start_with?('//') }.join
    end
  rescue StandardError => e
    puts Tui.paint("   #{t('editor_failed', message: e.message)}", :red)
    body
  end

  # Returns the chosen option's first element. Esc (or an unusable
  # answer when piped) keeps whatever is current, which is the same
  # promise every other prompt here makes.
  # `note:` is what the reader needs to see WHILE choosing -- the state the
  # options act on. Same rule as the label, and for the same reason the
  # comment below already gives: this menu paints from the top of the
  # viewport, so anything printed just before it is painted over. The menu
  # section was printing which of its three states the site is in ("derived
  # from your content", "switched off", or the list of items) and then
  # calling this, which wiped it -- leaving a derived menu and a menu turned
  # off looking exactly alike at the moment of the choice, which is the one
  # distinction the section exists to make. Rows, not a string: the third
  # state is a list.
  def choose(label, options, current_index: 0, note: nil)
    # Wrapped for the reason question_frame wraps a hint -- Tui.menu paints
    # a frame and the frame truncates. Rows that already carry colour are
    # left alone: a caller that painted a row measured it as it meant it,
    # and an ANSI string's length is not its width.
    rows = Array(note).flat_map do |row|
      row.to_s.include?("\e") ? [row] : Tui.wrap_to_width(row.to_s, Tui.term_width)
    end
    unless Tui.interactive?
      rows.each { |row| puts row }
      puts unless rows.empty?
      puts Tui.paint(label, :bold)
      puts
      options.each_with_index { |(_, desc), i| puts "  #{i + 1}) #{desc}" }
      print t('choice_prompt')
      line = $stdin.gets
      raise Interrupt if line.nil?

      # The range check is not tidiness: "".to_i and "abc".to_i are both
      # 0, so the index would be -1, and options[-1] in Ruby is the LAST
      # option -- a piped run that answered nothing would silently pick
      # the bottom of the menu. scripts/import.rb was bitten by exactly
      # this once.
      answer = line.strip
      index = answer.to_i - 1
      puts
      return options[current_index].first unless answer.match?(/\A\d+\z/) && index.between?(0, options.size - 1)

      return options[index].first
    end

    # The section's label belongs in the frame: the menu paints from the top
    # of the viewport, so a label printed before it would be painted over.
    header = rows.empty? ? [] : rows + ['']
    index = Tui.menu(options.map { |(_, desc)| desc },
                     header: header + [Tui.paint(label, :bold), ''],
                     hint: t('menu_hint', count: [options.size, 9].min),
                     initial: current_index)
    chosen = index || current_index
    record(label, options[chosen].last)
    options[chosen].first
  end

  # A menu that can be left, for wizards built as a set of sections
  # rather than one pass. Returns nil when the user is done.
  def choose_or_exit(label, options)
    rows = options.map { |(_, desc)| desc } + [t('done')]
    unless Tui.interactive?
      puts Tui.paint(label, :bold)
      puts
      rows.each_with_index { |desc, i| puts "  #{i + 1}) #{desc}" }
      print t('choice_prompt')
      line = $stdin.gets
      # A pipe that runs out here means "done", and the row still has the
      # prompt on it -- every other way out of this branch closes it a few
      # lines down, and this one left the review to be printed onto the
      # question that asked for it.
      if line.nil?
        puts
        return nil
      end

      answer = line.strip
      index = answer.to_i - 1
      puts
      return nil unless answer.match?(/\A\d+\z/) && index.between?(0, options.size - 1)

      return options[index].first
    end

    index = Tui.menu(rows, header: [Tui.paint(label, :bold), ''],
                           hint: t('menu_hint_exit', count: [rows.size, 9].min))
    if index.nil? || index >= options.size
      self.context = []
      return nil
    end

    # A section starts its own record. What the previous one answered is
    # written and done with, and carrying it over would push the new
    # section's questions off the bottom of the screen. The name stays at
    # the top so every question in it says which section it belongs to --
    # this menu is the only place that knows.
    self.context = [Tui.paint(options[index].last, :bold), '']
    options[index].first
  end

  # `default:` is what Enter means. Without one, Enter is a no -- right for
  # "Write these changes?", wrong for a question about a setting that is
  # already on: pressing Enter through the wizard is documented as keeping
  # things as they are, and for the banner's two overlays it silently
  # turned them off instead.
  # `note:` is the reason the question is being asked -- the sentence that
  # makes a yes or a no mean anything. It has to travel INTO the frame,
  # because a caller that printed it first was printing it onto a screen
  # this method then wiped: Tui.frame starts at \e[H and ends with \e[J, so
  # a `puts` immediately before a confirm is overwritten from the top and
  # erased below. That left two questions in the menu section asking to
  # write an address without the sentence saying what was wrong with it,
  # which is a confirmation with its reason removed -- the one thing a
  # confirmation is for. Down a pipe there is no frame and nothing to wipe,
  # so it is printed there as before.
  def confirm(prompt, default: nil, note: nil)
    lines = context.dup
    if note
      if Tui.interactive?
        lines << '' unless lines.empty?
        # Wrapped for the reason question_frame wraps a hint: this row goes
        # into a frame, the frame truncates, and the end of the sentence is
        # where a note says what a yes will cost. Down a pipe there is no
        # frame, and a terminal wraps a `puts` by itself.
        indented(note, :yellow) { |row| lines << row }
      else
        puts Tui.paint("   #{note}", :yellow)
      end
    end
    # The frame ends in a blank row and key_choice writes the prompt onto
    # it, so the question stands on whatever the section has decided so far
    # instead of appearing alone under a repaint.
    #
    # Trimmed from the TOP, exactly as question_frame trims and for the same
    # reason. Tui.frame keeps the rows that FIT, counting from the first, so
    # a record taller than the window lost the two blank rows at the end --
    # and key_choice then wrote the question onto the last row of the
    # record: "Otázka číslo 24: odpověď 24Zapsat tyhle změny? [a/N]". A
    # question printed on top of an answer is the thing the blank row at the
    # end of a frame exists to prevent. ./setup.sh reaches this on any
    # ordinary window: it never clears the record, so by the last third of
    # the run there are more answers than rows. The ones worth keeping are
    # the last ones anyway -- the newest answers, and the note, which is
    # appended here.
    if Tui.interactive? && !lines.empty?
      room = [Tui.term_height - 4, 2].max
      Tui.frame((lines.size > room ? lines.last(room) : lines) + ['', ''])
    end
    answer = Tui.key_choice(prompt)
    return default if default != nil && answer.to_s.empty?

    # The key that means yes comes from the locale, the way the prompt
    # does. The three shipped languages were listed here by hand, which
    # worked right up until a fourth one -- localization.md invites
    # exactly that -- would have had the wizard refuse the answer it had
    # just offered on screen, and throw the whole run away. The three are
    # still accepted alongside it, so nobody's habits break.
    #
    # This rule used to live here and, in a laxer form, at three call sites
    # in manage_post.rb; the laxer form accepted any word starting with the
    # letter, which down a pipe made "abort" mean yes. Two definitions of
    # what counts as consent is one too many, so there is now one, and it
    # is this one -- moved to Tui.yes? where the answer is read.
    Tui.yes?(answer)
  end

  # Everything a run collected, shown once and written once.
  #
  # `files` is a list of [label, writer] pairs; a writer whose changed?
  # is false contributes nothing, so a run where the user pressed Enter
  # through every question reports "nothing changed" and leaves no
  # backups suggesting otherwise.
  def review_and_write(files)
    changed = files.select { |(_, writer)| writer.changed? }
    if changed.empty?
      puts t('nothing_changed')
      puts
      return :unchanged
    end

    puts Tui.paint(t('section_review'), :bold)
    puts
    changed.each { |(label, writer)| show_diff(label, writer.diff) }

    # The diff is what this question is about, so nothing may be painted
    # over it -- and confirm builds a frame out of the record whenever there
    # is one. ./setup.sh arrives here with every answer of the entire run
    # still in it, so the diff that had just been printed was wiped by a
    # list of twenty answers and the write was confirmed blind. The record
    # has done its job by now: the section that started it is over, and what
    # follows is the file, not the questions.
    self.context = []
    unless confirm(t('q_write'))
      puts t('cancelled')
      puts
      return :cancelled
    end
    puts

    begin
      changed.each { |(_, writer)| writer.save! }
    rescue ConfigWriter::VerificationFailed => e
      # The writer has already put the file back; all that is left is to
      # say so in a way that does not read as "your config is ruined".
      puts Tui.paint("❌ #{t('write_failed', message: e.message)}", :red)
      # Both wizards stop here, so this is the last thing either of them
      # says -- and a command that stops on a failure owes the same single
      # blank line at the end as one that stops on a success.
      puts
      return :failed
    end

    changed.each { |(label, _)| puts Tui.paint(t('written', path: label), :green) }
    :written
  end

  # Secrets are masked rather than omitted: that the token line changed
  # is the point, what it changed to is not -- and a diff like this ends
  # up pasted into an issue.
  def show_diff(name, diff)
    return if diff.to_s.empty?

    puts Tui.paint("--- #{name}", :bold)
    diff.each_line do |line|
      colour = line.start_with?('+') ? :green : :red
      print Tui.paint(mask(line), colour)
    end
    puts
  end

  # `$` and not `\z`: diff lines arrive from `each_line` WITH their trailing
  # newline, and `.*` never crosses one -- so the anchored form could not
  # match a single real line, and every token in the review diff was printed
  # in the clear, in the one place the comment above promises it is not.
  # The optional "#" matters: EnvFile falls back to a commented line when
  # no active one exists, so the "-" side of a diff replacing a
  # commented-out credential carries the old token too -- and used to
  # print it in the clear, in the one place this promises it will not.
  MASKED = /\A([-+]\s*(?:#\s*)?(?:export\s+)?(?:\w*TOKEN|\w*PASSWORD|\w*SECRET|\w*KEY)\w*=).*$/.freeze

  def mask(line)
    line.sub(MASKED) { "#{Regexp.last_match(1)}••••••••" }
  end

  # Wraps a wizard's main loop so an interrupt says the one thing worth
  # saying: nothing was written.
  def guard
    yield
  rescue Interrupt
    puts
    puts
    puts t('interrupted')
    exit 130
  end
end
