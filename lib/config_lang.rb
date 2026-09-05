# frozen_string_literal: true

require_relative 'yaml_compat'

# lib/config_lang.rb -- which language to speak when config/site.yml is
# itself the thing that is broken.
#
# The commands that report on the config cannot ask I18n for the language,
# because I18n asks SiteConfig and SiteConfig aborts on exactly the file
# they are about to explain. They dig it out of the raw file instead: the
# parse is tried first, because it reads a quoted value faithfully, and a
# raw scan of the `lang:` line is the fallback -- that line survives almost
# every way a hand-edited YAML breaks, since a quote left open three
# sections below does not move it.
#
# doctor did this first and had it to itself, and check printed English
# until it did the same: a Czech user whose config would not parse was told
# so in a language they had not chosen, by the one command whose whole
# answer is that sentence. One copy, both callers.
module ConfigLang
  module_function

  # nil when there is nothing to go on -- the caller decides what English
  # is called there, since it is the caller that knows its own default.
  def of(path)
    return nil unless File.exist?(path)

    parsed = begin
      data = YamlCompat.load_file(path)
      data.is_a?(Hash) ? data.dig('site', 'lang') : nil
    rescue StandardError
      nil
    end
    return parsed unless parsed.to_s.empty?

    raw = begin
      File.read(path, encoding: 'utf-8')
    rescue StandardError
      ''
    end
    raw[/^\s*lang:\s*["']?([A-Za-z]{2,8})/, 1]
  end
end
