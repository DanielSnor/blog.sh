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

  # One run, one language -- and a run can be told which, so a site that
  # publishes in more than one renders each by building again with
  # BLOG_SH_LANG and its own BLOG_SH_PUBLIC_DIR. The override lives HERE
  # and nowhere else: the build reads the language three times (every
  # string through this, <html lang> and og:locale from it), and a second
  # door is how a German page ends up announcing itself as Czech. A code
  # with no locale file stops the build in load_locale, which is the loud
  # end this deserves -- the quiet one is English rendered into /de/.
  def lang
    @lang ||= begin
      named = ENV['BLOG_SH_LANG'].to_s.strip
      named.empty? ? SiteConfig.get('site', 'lang', default: DEFAULT_LANG) : named
    end
  end

  # Which locale FILE this run reads its own strings from. Normally the
  # language being rendered -- a German run speaks German -- but a site
  # may publish a language the engine has never been translated into, and
  # then it says where to borrow the engine's own words from:
  #
  #   site:
  #     locales: [cs, sk]
  #     ui_language:
  #       sk: cs
  #
  # The CONTENT stays Slovak: the addresses, <html lang> and what a
  # crawler is told are all built from `lang` and are untouched by this.
  # Only the engine's furniture -- Read more, the date, the search box --
  # comes from somewhere else, because the alternative is refusing to
  # publish the language at all.
  # 🪤 Read WITHOUT SiteConfig, tolerating every way the file can fail.
  # SiteConfig aborts on a config that is missing, unreadable or not valid
  # YAML -- correct for a build, fatal here: this is reached from `t()`,
  # which is how `doctor` and `check --json` say what is wrong with that
  # very file. Going through SiteConfig turned their answer into the abort
  # they exist to explain, which is the trap force_lang below was written
  # for and which this walked straight into.
  def ui_lang
    @ui_lang ||= begin
      named = begin
        path = SiteConfig.language_path(lang)
        data = File.exist?(path) ? YAML.load_file(path) : nil
        data.is_a?(Hash) ? data['ui_language'].to_s.strip : ''
      rescue StandardError, Psych::SyntaxError
        ''
      end
      named.empty? || !locale_file?(named) ? lang.to_s : named
    end
  end

  # Picks the language without asking SiteConfig -- for the one caller
  # that cannot afford to: `./blog.sh doctor` runs ON a broken config, and
  # reading site.yml through SiteConfig would abort on the very syntax
  # error the user ran doctor to have explained. Doctor digs the language
  # out of the raw file itself, tolerating failure, and tells I18n here.
  def force_lang(code)
    @lang = File.exist?(File.join(LOCALES_DIR, "#{code}.yml")) ? code : DEFAULT_LANG
    @data = nil
    @ui_lang = nil
    @narration_data = nil
    @forced = true
  end

  def default_data
    @default_data ||= load_locale(DEFAULT_LANG)
  end

  def data
    @data ||= ui_lang == DEFAULT_LANG ? default_data : load_locale(ui_lang)
  end

  # Whether a code has a locale file at all -- asked before loading one,
  # by everybody who has something better to do with a missing file than
  # end the process (`load_locale` aborts, and an abort is a SystemExit
  # that an ordinary rescue does not catch).
  def locale_file?(code)
    File.exist?(File.join(LOCALES_DIR, "#{code}.yml"))
  end

  def load_locale(code)
    path = File.join(LOCALES_DIR, "#{code}.yml")
    unless File.exist?(path)
      # 🪤 In English and hardcoded, because this is the one failure that
      # happens BEFORE any locale is loaded -- there are no translated
      # strings to say it with. All three ways out are named: the engine
      # has no words for this language, so either give it some, stop
      # publishing the language, or say which language's words to borrow.
      abort("❌ Missing locale file #{path} -- add one, take #{code} out of site.locales, " \
            "or say where its interface words come from (site.ui_language: { #{code}: cs }) " \
            'in config/site.yml')
    end

    SiteConfig.load_yaml(path)
  end

  # The same lookup as t, but nil instead of aborting when the key isn't
  # there. For the one case where a missing translation is legitimate:
  # names of things a USER added -- a palette in config/palettes.yml that
  # the engine never shipped -- where the data file's own label is the
  # right fallback and demanding a locale entry would mean nobody can add
  # a palette without editing three translations.
  # What the build SAYS -- its progress, its warnings, its summary -- is
  # said to the author, in the site's own language, whichever language's
  # pages the run is building. The pages speak their branch's language; the
  # lines on the terminal did too, so `./blog.sh rebuild` on an English site
  # publishing Czech said half its summary in Czech (newcomer trial,
  # 25. 9. 2026). Every narration key lives under `build.`.
  NARRATION = 'build.'

  # A language chosen outright (force_lang -- a command, a test) is the
  # language of everything, narration included; the split is only for a
  # build of a language's branch, which is told its language by
  # BLOG_SH_LANG.
  def narration_data
    return data if @forced

    own = SiteConfig.get('site', 'lang', default: DEFAULT_LANG).to_s
    own = DEFAULT_LANG unless locale_file?(own)
    return data if own == ui_lang

    @narration_data ||= own == DEFAULT_LANG ? default_data : load_locale(own)
  end

  def data_for(key)
    key.start_with?(NARRATION) ? narration_data : data
  end

  def lookup(key, **vars)
    value = dig_key(data_for(key), key) || dig_key(default_data, key)
    return nil if value.nil?

    vars.empty? ? value : value.gsub(/%\{(\w+)\}/) { vars.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0)).to_s }
  end

  # Dotted key path, e.g. t('nav.all'). %{name}-style placeholders in the
  # string are substituted from **vars.
  def t(key, **vars)
    value = dig_key(data_for(key), key) || dig_key(default_data, key)
    if value.nil?
      abort("❌ Missing translation key #{key.inspect} in both '#{lang}' and the '#{DEFAULT_LANG}' fallback locale")
    end

    vars.empty? ? value : value.gsub(/%\{(\w+)\}/) { vars.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0)).to_s }
  end

  def dig_key(hash, key)
    key.split('.').reduce(hash) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
  end
end
