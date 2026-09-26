# frozen_string_literal: true

require 'yaml'

# lib/yaml_compat.rb -- YAML.load_file across the Rubys this engine
# actually promises to run on.
#
# Psych 4 (Ruby 3.1+) gave load_file safe_load semantics, where a config
# that merely uses a YAML anchor (`<<: *defaults`) raises -- so the
# engine passes `aliases: true`. But Psych 3 (Ruby 2.7 and 3.0 -- Debian
# 11's system Ruby among them) does not KNOW that keyword and raises
# ArgumentError instead, and every call site that passed it unguarded
# was broken on the oldest Rubys the README promises: on 2.7 the setup
# and style wizards could not write a config at all, failing verify!
# with a rollback message that blamed the file.
#
# One retry in one place. site_config.rb and lib/doctor.rb carried this
# pattern locally before this file existed and keep their own copies for
# their richer error reporting; everything else comes here.
module YamlCompat
  module_function

  def load_file(path)
    YAML.load_file(path, aliases: true)
  rescue ArgumentError
    YAML.load_file(path)
  end

  # The line whose quoted value never closes, for a file that has already
  # failed to parse. Psych names where it gave up -- for a quote left open
  # that is the START of the mapping around it, or the line where a later
  # quote closed it by accident -- and the hint sent people up the file
  # when the quote was below (second trial, 25. 9. 2026). Block scalars
  # (| and >) are prose, and skipped.
  #
  # A line is only NAMED when closing its quote is what makes the file
  # parse. Read alone, a legal line looked guilty -- "C:\\" (an escaped
  # backslash before the closing quote), a quoted value folded over two
  # lines -- and took the blame for a tab three lines down (fleet, 26. 9.
  # 2026). With two faults in the file nothing is named, and the caller
  # falls back to Psych's own line.
  def open_quote_line(text)
    text = text.to_s.dup.force_encoding('UTF-8').scrub
    lines = text.lines
    open_quote_candidates(lines).find do |number|
      fixed = lines.dup
      fixed[number - 1] = "#{fixed[number - 1].chomp}#{fixed[number - 1].strip.sub(/\A-\s+/, '').sub(KEY, '')[0]}\n"
      parses?(fixed.join)
    end
  end

  KEY = /\A(?:"[^"]*"|'[^']*'|[^"'\s#][^:]*):(\s+|\z)/.freeze

  def open_quote_candidates(lines)
    block_indent = nil
    lines.each_with_index.filter_map do |line, index|
      indent = line[/\A */].size
      if block_indent
        next if line.strip.empty? || indent > block_indent

        block_indent = nil
      end
      value = line.strip.sub(/\A-\s+/, '')
      next if value.empty? || value.start_with?('#')

      value = value.sub(KEY, '')
      if value.match?(/\A[|>][-+0-9]*\s*(#.*)?\z/)
        block_indent = indent
        next
      end
      quote = value[0]
      next unless ['"', "'"].include?(quote)

      rest = value[1..].to_s
      closed = quote == '"' ? rest.match?(/(?<!\\)(?:\\\\)*"/) : rest.include?("'")
      index + 1 unless closed
    end
  end

  def parses?(text)
    Psych.parse(text)
    true
  rescue Psych::SyntaxError
    false
  end
end
