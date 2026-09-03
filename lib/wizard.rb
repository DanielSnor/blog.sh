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
    # The spans go with the rows they described.
    @blocks = []
    @context = Array(rows)
  end

  def remember(row)
    context << row
  end

  # Rows that only mean anything whole.
  #
  # The record is trimmed from the top when it outgrows the window, which
  # is right for a list of answers -- the newest are the ones worth
  # keeping. It is wrong for a picture. A QR code is 15 to 19 rows tall
  # and the style wizard's menu spends twelve, so on a 24-row terminal --
  # the ordinary one -- three rows of the code survived, finder patterns
  # and all trimmed away, under an intact "scan this with your phone".
  # A code missing its top two thirds scans as nothing.
  #
  # So a block is kept whole or not at all. Dropping it costs the picture;
  # slicing it costs the picture AND tells the reader to photograph the
  # remains.
  def remember_block(rows)
    rows = Array(rows)
    return if rows.empty?

    blocks << (context.size...(context.size + rows.size))
    context.concat(rows)
  end

  def blocks
    @blocks ||= []
  end

  # The last `room` rows, except that a block straddling the cut goes
  # entirely rather than in halves.
  #
  # `rows` may be the record with something appended -- confirm adds its
  # note -- and that is safe: a span counts from the start of the record,
  # and appending moves nothing that came before.
  def tail_of_record(room, rows = context)
    return rows.dup if rows.size <= room

    start = rows.size - room
    # span.end, not span.last + 1: these are exclusive ranges, so `end` IS
    # the first row after the block. `last` returns the same number, and
    # adding one to it skipped the row immediately after -- which here is
    # the address the whole reordering exists to save.
    blocks.each { |span| start = span.end if span.cover?(start) }
    rows[start..] || []
  end

  # An answer, in the form it goes back on screen as: the question it
  # answered and what it now says. Recorded by `ask` itself rather than by
  # each of the two wizards, so every question in ./setup.sh and ./style.sh
  # builds the running record without either of them being changed.
  def record(label, value)
    shown = value.to_s.empty? ? t('empty_value') : value.to_s
    remember(format('  %s %s', Tui.paint("#{label}:", :dim), Tui.truncate_to_width(shown, 60)))
  end

  # A row said between questions, in the wizard's own voice: a verdict on
  # a directory, a cron line to copy, a warning about what the next answer
  # will do. Interactively it goes into the frame context rather than onto
  # the screen -- every question repaints from the top of the viewport, so
  # a plain `puts` here is erased at the exact moment the question it was
  # informing arrives. Down a pipe there is no repaint and the plain line
  # stays what it always was. Wrapped like a hint, because frames truncate
  # every row they are given and prose is written to be read to the end.
  def say(text, *styles)
    unless Tui.interactive?
      puts text
      return
    end

    Tui.wrap_to_width(text.to_s, Tui.term_width).each do |line|
      remember(styles.empty? ? line : Tui.paint(line, *styles))
    end
  end

  # The record a menu keeps above itself, trimmed from the TOP exactly as
  # question_frame trims and for the same reason: the rows worth keeping
  # are the newest -- the verdict or the value a section said an instant
  # before this menu would otherwise have painted over it. `taken` is what
  # the menu already spends on its own rows, so the record never squeezes
  # the options off the screen. Trailing blank rows go: the menu writes
  # its own separator, and a section that closed on say('') would
  # otherwise open the next frame on two.
  def context_above(taken)
    room = [Tui.term_height - taken - 6, 0].max
    rows = tail_of_record(room)
    rows.pop while !rows.empty? && Tui.strip_ansi(rows.last.to_s).strip.empty?
    rows.empty? ? [] : rows + ['']
  end

  # The frame a question stands on, ending in a blank row for the prompt --
  # frame leaves the cursor at the end of its last line, so the prompt and
  # what gets typed after it land there.
  #
  # The record is trimmed from the TOP to whatever the window has room for:
  # a long section would otherwise push its own question off the bottom,
  # and the answers worth seeing are the ones just given.
  def question_frame(label, hint, problem)
    # The tail is built first and measured, because the tail is the
    # question: label, hint, complaint, and the blank row the prompt
    # lands on. Reserving a flat six rows for it worked until say()
    # could fill the context to the ceiling -- then a hint or a
    # validation error that wrapped past the allowance was cut from the
    # BOTTOM, which is mid-sentence with the prompt glued on ("...and
    # carry aSugg>"). The record above the question is the part that can
    # shrink; the question never is, and keep_last makes the frame
    # enforce that even if this arithmetic is ever wrong again.
    tail = [Tui.paint(label, :bold)]
    # Wrapped, not one row: the frame truncates every row it is given, and
    # a hint is the one thing here written to be read rather than scanned.
    # The three spaces go on each line so the block lines up under the
    # question instead of the continuation starting at the margin.
    indented(hint, :dim) { |row| tail << row }
    indented(problem, :red) { |row| tail << row }
    tail << ''
    room = [Tui.term_height - tail.size - 1, 2].max
    # Through the same trim as context_above and confirm: three places cut
    # the record, and a rule that holds in two of them is a rule the third
    # can break.
    rows = tail_of_record(room)
    rows << '' unless rows.empty?
    Tui.frame(rows + tail, keep_last: tail.size)
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
      # ⚠️ Into the RECORD, not painted. This called question_frame, which
      # paints the label and the hint -- and then confirm below paints its
      # OWN frame from the record, straight over them. What a person was
      # left looking at was "Open it in your editor? [y/N]" and nothing
      # saying what "it" was: the same bare line for the About text and
      # for the footer note, two different sections of the wizard asking
      # an identical question. Down a pipe the label, the hint and the
      # current value all arrive, so the terminal was the poorer of the
      # two. Remembered, they survive the repaint and stand above the
      # question they belong to.
      remember(Tui.paint(label, :bold))
      indented(hint, :dim) { |row| remember(row) }
      remember(Tui.paint("   #{t('current_is', value: current.to_s.empty? ? t('empty_value') : current)}", :dim))
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
      # A row painted in one colour from end to end can still be wrapped:
      # take the paint off, wrap the words, put the same paint back on each
      # line. Leaving every coloured row alone meant the explanations --
      # which are dim, all of them -- were cut at the frame instead, and
      # half the sentence about the derived menu (or the palette) was
      # simply not there. Rows with colour CHANGING inside them are still
      # left as their author measured them.
      row.to_s.include?("\e") ? wrap_painted(row.to_s) : Tui.wrap_to_width(row.to_s, Tui.term_width)
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
    # The record goes in above it, for the same reason question_frame and
    # confirm carry it: this repaint was the one that still ate everything
    # a section said just before a menu -- the cron line ./setup.sh asks to
    # be copied, the verdict on a deploy directory -- at the exact moment
    # the person needed it in front of them.
    header = rows.empty? ? [] : rows + ['']
    header = context_above(options.size + header.size) + header
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
  # One colour around the whole row, or nothing to do. The pattern is
  # deliberately narrow: an escape anywhere in the middle means the caller
  # is doing something this cannot measure, and guessing there would break
  # a row that is correct today.
  def wrap_painted(row)
    match = row.match(/\A(\e\[[0-9;]*m)([^\e]*)(\e\[0m)\z/)
    return [row] unless match

    Tui.wrap_to_width(match[2], Tui.term_width).map { |line| "#{match[1]}#{line}#{match[3]}" }
  end

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

    # The record here is the section just finished -- its answers and
    # whatever it said on the way out. This menu is the frame that used to
    # wipe them; carried in, they read as the receipt for the section while
    # the next one is being chosen.
    index = Tui.menu(rows, header: context_above(rows.size) + [Tui.paint(label, :bold), ''],
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
  # escape: what the Esc key means here. :default is the wizard's promise
  # -- Esc keeps what is there, same as Enter -- and it is right for every
  # question about a SETTING. Pass false where a yes does something
  # instead: Esc is the key people press to back out, and answering it
  # with the convenient default is how the palette preview came to build
  # a page and upload it to the live site on the cancel key.
  ESCAPED = "\e[escaped]"

  def confirm(prompt, default: nil, note: nil, escape: :default)
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
      # Through the same trim as context_above: both of them cut the
      # record, and a rule that held in only one of them is a rule the
      # other can break.
      Tui.frame(tail_of_record(room, lines) + ['', ''])
    end
    # ESCAPED is a value no keypress and no typed line can produce, so it
    # cannot collide with a real answer.
    answer = Tui.key_choice(prompt, escape: escape == :default ? '' : ESCAPED)
    return false if answer == ESCAPED
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
  #
  # `also` is the changes a run makes that are not lines in a file --
  # every file ./style.sh has queued for copying into the install: the
  # banner picture, a stylesheet, a font face. They are listed here for
  # the reason the diffs are (the answer to `q_write` has to cover
  # everything the run would do) and counted as changes for a reason the
  # banner section found the hard way: replacing an image with one of the
  # same name and the same dimensions moves nothing in site.yml, so the
  # run reported "nothing changed" and left -- and the copy, which waits
  # for :written, was dropped with it. Reading the picture as the only
  # such change is how the identical hole survived one section over, where
  # a skin.css the config already named was promised and then dropped.
  def review_and_write(files, also: [])
    changed = files.select { |(_, writer)| writer.changed? }
    if changed.empty? && also.empty?
      puts t('nothing_changed')
      puts
      return :unchanged
    end

    puts Tui.paint(t('section_review'), :bold)
    puts
    changed.each { |(label, writer)| show_diff(label, writer.diff) }
    unless also.empty?
      also.each { |line| puts line }
      puts
    end

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

    # Every file is checked for writability BEFORE the first is written, so
    # the refusal genuinely happens before anything changes -- which is
    # what "nothing was written" promises. Writing them in turn and letting
    # the second fail left the first already replaced: site.yml new, env.sh
    # old, the two out of step, and a message swearing nothing had changed.
    blocked = changed.filter_map do |(_, writer)|
      path = writer.respond_to?(:path) ? writer.path : nil
      blocker = path && ConfigWriter.write_blocker(path)
      blocker && [path, blocker]
    end.first
    if blocked
      path, blocker = blocked
      # Which of the two it is decides the sentence, because the advice
      # differs and the wrong one sends the reader hunting for a file that
      # is not in the way: told to go and look at a .bak, they find no .bak.
      # write_blocker returns the backup or the directory, nothing else.
      key = blocker == "#{path}.bak" ? 'write_denied_backup' : 'write_denied_dir'
      puts Tui.paint("❌ #{t(key, path: relative(blocker))}", :red)
      puts
      return :failed
    end

    begin
      changed.each { |(_, writer)| writer.save! }
    rescue ConfigWriter::NotWritable => e
      # The pre-flight above catches the ordinary permission refusal before
      # any file is touched; this remains for the race where a mode changes
      # between the check and the write. Rare enough that naming the file
      # (the Errno does) is enough.
      puts Tui.paint("❌ #{t('write_denied', message: e.message)}", :red)
      puts
      return :failed
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
  #
  # And the one fault that lands before a single question is asked: both
  # wizards open by building a writer over config/site.yml with
  # config/site.yml.example behind it, and a tree without the template met
  # them with a Ruby backtrace out of the constructor. It is not the
  # user's config that is wrong -- the template ships with the engine and
  # is simply not there.
  def guard
    yield
  rescue Interrupt
    puts
    puts
    puts t('interrupted')
    exit 130
  rescue ConfigWriter::TemplateMissing => e
    puts
    puts Tui.paint("❌ #{t('template_missing', path: relative(e.path))}", :red)
    puts
    exit 1
  rescue ConfigWriter::Unreadable => e
    puts
    puts Tui.paint("❌ #{t('config_unreadable_file', path: relative(e.path), error: e.message)}", :red)
    puts
    exit 1
  end

  # A path as the reader would type it: the engine's own root cut off, so
  # a message names config/site.yml.example and not the whole checkout.
  def relative(path)
    root = "#{File.expand_path('..', __dir__)}/"
    path.to_s.start_with?(root) ? path.to_s.delete_prefix(root) : path.to_s
  end
end
