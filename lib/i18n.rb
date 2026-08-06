# frozen_string_literal: true

require 'yaml'
require_relative 'site_config'

# lib/i18n.rb -- loads locales/<lang>.yml, selected by config/site.yml's
# site.lang key, and falls back to English for any individual key missing
# from the selected locale. That per-key fallback (rather than an
# all-or-nothing choice) means a partial third-party translation degrades
# gracefully instead of breaking pages.
module I18n
  LOCALES_DIR = File.join(File.expand_path('..', __dir__), 'locales')
  DEFAULT_LANG = 'en'

  module_function

  def lang
    @lang ||= SiteConfig.get('site', 'lang', default: DEFAULT_LANG)
  end

  # Picks the language without asking SiteConfig -- for the one caller
  # that cannot afford to: `./blog.sh doctor` runs ON a broken config, and
  # reading site.yml through SiteConfig would abort on the very syntax
  # error the user ran doctor to have explained. Doctor digs the language
  # out of the raw file itself, tolerating failure, and tells I18n here.
  def force_lang(code)
    @lang = File.exist?(File.join(LOCALES_DIR, "#{code}.yml")) ? code : DEFAULT_LANG
    @data = nil
  end

  def default_data
    @default_data ||= load_locale(DEFAULT_LANG)
  end

  def data
    @data ||= lang == DEFAULT_LANG ? default_data : load_locale(lang)
  end

  def load_locale(code)
    path = File.join(LOCALES_DIR, "#{code}.yml")
    unless File.exist?(path)
      abort("❌ Missing locale file #{path} -- add one, or set site.lang: #{DEFAULT_LANG} in config/site.yml")
    end

    SiteConfig.load_yaml(path)
  end

  # The same lookup as t, but nil instead of aborting when the key isn't
  # there. For the one case where a missing translation is legitimate:
  # names of things a USER added -- a palette in config/palettes.yml that
  # the engine never shipped -- where the data file's own label is the
  # right fallback and demanding a locale entry would mean nobody can add
  # a palette without editing three translations.
  def lookup(key, **vars)
    value = dig_key(data, key) || dig_key(default_data, key)
    return nil if value.nil?

    vars.empty? ? value : value.gsub(/%\{(\w+)\}/) { vars.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0)).to_s }
  end

  # Dotted key path, e.g. t('nav.all'). %{name}-style placeholders in the
  # string are substituted from **vars.
  def t(key, **vars)
    value = dig_key(data, key) || dig_key(default_data, key)
    if value.nil?
      abort("❌ Missing translation key #{key.inspect} in both '#{lang}' and the '#{DEFAULT_LANG}' fallback locale")
    end

    vars.empty? ? value : value.gsub(/%\{(\w+)\}/) { vars.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0)).to_s }
  end

  def dig_key(hash, key)
    key.split('.').reduce(hash) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
  end
end
