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
  # when the quote was below (second trial, 25. 9. 2026). A value that
  # opens a quote and does not close it on its own line is legal YAML, but
  # never in a hand-edited site.yml, and only asked about once the parse
  # has failed. Block scalars (| and >) are prose, and skipped.
  def open_quote_line(text)
    block_indent = nil
    text.to_s.dup.force_encoding('UTF-8').scrub.each_line.with_index(1) do |line, number|
      indent = line[/\A */].size
      if block_indent
        next if line.strip.empty? || indent > block_indent

        block_indent = nil
      end
      value = line.strip.sub(/\A-\s+/, '')
      next if value.empty? || value.start_with?('#')

      value = value.sub(/\A[^"'\s#][^:]*:(\s+|\z)/, '')
      if value.match?(/\A[|>][-+0-9]*\s*(#.*)?\z/)
        block_indent = indent
        next
      end
      quote = value[0]
      next unless ['"', "'"].include?(quote)

      rest = value[1..].to_s
      closed = quote == '"' ? rest.match?(/(?<!\\)"/) : rest.include?("'")
      return number unless closed
    end
    nil
  end
end
