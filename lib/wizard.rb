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
  def ask(label, current, hint: nil, suggested: false)
    puts Tui.paint(label, :bold)
    puts Tui.paint("   #{hint}", :dim) if hint
    shown = current.to_s.empty? ? t('empty_value') : current.to_s
    print t(suggested ? 'prompt_with_suggestion' : 'prompt_with_current', current: shown)
    answer = $stdin.gets
    raise Interrupt if answer.nil?

    answer = answer.strip
    puts
    answer.empty? ? current : answer
  end

  # The same, with a check that runs before the answer is accepted. The
  # block returns nil when happy or the sentence explaining what is
  # wrong -- said immediately, while the answer is still in mind, rather
  # than saved up for a validation report at the end.
  def ask_valid(label, current, hint: nil, suggested: false)
    loop do
      answer = ask(label, current, hint: hint, suggested: suggested)
      return answer if answer == current || answer.to_s.empty?

      problem = yield(answer)
      return answer unless problem

      puts Tui.paint("   #{problem}", :red)
      puts
    end
  end

  # Multi-line text through $EDITOR -- for the values that are prose (a
  # bio, a footer note) and that a single-line prompt would turn into an
  # unreadable ribbon. Returns the current value unchanged if the editor
  # is unavailable or the file comes back empty.
  def ask_text(label, current, hint: nil, comment: nil)
    puts Tui.paint(label, :bold)
    puts Tui.paint("   #{hint}", :dim) if hint
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

    edited = edit_in_editor(current.to_s, comment)
    puts
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
  def choose(label, options, current_index: 0)
    puts Tui.paint(label, :bold)
    puts
    unless Tui.interactive?
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

    index = Tui.menu(options.map { |(_, desc)| desc }, hint: t('menu_hint'),
                     initial: current_index)
    puts
    index.nil? ? options[current_index].first : options[index].first
  end

  # A menu that can be left, for wizards built as a set of sections
  # rather than one pass. Returns nil when the user is done.
  def choose_or_exit(label, options)
    puts Tui.paint(label, :bold)
    puts
    rows = options.map { |(_, desc)| desc } + [t('done')]
    unless Tui.interactive?
      rows.each_with_index { |desc, i| puts "  #{i + 1}) #{desc}" }
      print t('choice_prompt')
      line = $stdin.gets
      return nil if line.nil?

      answer = line.strip
      index = answer.to_i - 1
      puts
      return nil unless answer.match?(/\A\d+\z/) && index.between?(0, options.size - 1)

      return options[index].first
    end

    index = Tui.menu(rows, hint: t('menu_hint_exit'))
    puts
    return nil if index.nil? || index >= options.size

    options[index].first
  end

  # `default:` is what Enter means. Without one, Enter is a no -- right for
  # "Write these changes?", wrong for a question about a setting that is
  # already on: pressing Enter through the wizard is documented as keeping
  # things as they are, and for the banner's two overlays it silently
  # turned them off instead.
  def confirm(prompt, default: nil)
    answer = Tui.key_choice(prompt)
    return default if default != nil && answer.to_s.empty?

    # y English, j German, a Czech ("ano") -- the prompt is translated,
    # so the key that means yes has to be too.
    %w[y j a].include?(answer)
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
  MASKED = /\A([-+]\s*(?:export\s+)?(?:\w*TOKEN|\w*PASSWORD|\w*SECRET|\w*KEY)\w*=).*$/.freeze

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
