# frozen_string_literal: true

# build/languages.rb -- which language a build run renders, and where a
# reader of it is sent.
#
# A site publishes its own language at the root and every other language
# in `site.locales` under /<code>/, one build run per language
# (BLOG_SH_LANG), all into one tree. Everything that follows from that
# lives here: an address inside this run's language, where a post is
# linked from here (its own text, a fallback's, or the site's), which
# part of the tree this run's sweep owns, the alternates a page names and
# the switcher that moves between them -- and the checks a language
# configuration has to pass before a single page is written.
#
# The constants it answers from -- SITE_LANG, SITE_OWN_LANG, LANG_ROOT,
# CONTENT_ROOT, SHARED_ROOTS, and SITE_LOCALES / FALLBACK_CHAIN once
# site_locales and fallback_chain have set them -- stay at the top of
# build_blog.rb: the whole build reads them. `loc` and `post_href` keep a
# name there too, because the templates call them by it.
module Languages
  module_function

  # An address inside this run's language.
  def loc(path)
    return path if LANG_ROOT.empty?

    text = path.to_s
    return text unless text.start_with?('/')
    return text if SHARED_ROOTS.any? { |root| text.start_with?(root) }

    "#{LANG_ROOT}#{text}"
  end

  # Whether this run has a text of its own for the post. In the site's own
  # language always: that text IS the post.
  def translated_here?(post)
    LANG_ROOT.empty? || Translations.languages(post).include?(SITE_LANG)
  end

  # Where a link to the post goes from a page of this language. A post with
  # no text here keeps the one address it has, and gets no page of its own:
  # the same words standing at two addresses is what would otherwise need a
  # canonical, and what hreflang must never be told about (Daniel, 20. 9.
  # 2026 -- the listing carries it, the link goes where the piece really is).
  def post_href(post)
    lang = stand_in_lang(post)
    "#{lang_root_for(lang)}#{address_of(post, lang)}"
  end

  # Which languages this site publishes, the site's own first. Absent -- and
  # it is absent on every site today -- means one, and then nothing below
  # renders at all: no switcher and no alternates, because there is nothing
  # to offer and nothing to compare.
  def site_locales
    named = Array(SiteConfig.get('site', 'locales', default: nil)).map { |code| code.to_s.strip }
    all = ([SITE_OWN_LANG] + named.reject(&:empty?)).uniq
    # 🪤 A code with no locale file used to be met far from here, in the
    # language switcher, where `I18n.load_locale` aborts -- and it aborts
    # with SystemExit, which the rescue there does not catch. So a typo in
    # `site.locales` stopped the build of EVERY language, including the
    # site's own, with a sentence telling the reader to change `site.lang`.
    # A language the engine has no words for is refused -- unless the site
    # says where to borrow them from, which is what `site.ui_language` is
    # for. Publishing Slovak with Czech furniture is a decision somebody can
    # make; inheriting English by accident is not.
    missing = all.reject do |code|
      I18n.locale_file?(code) || I18n.locale_file?(SiteConfig.language_data(code)['ui_language'].to_s)
    end
    # One that DID say where to borrow from, and named a language the
    # engine cannot lend: the sentence above then told its author to write
    # the very line they had just written. Said about the value.
    borrowing = missing.select { |code| !SiteConfig.language_data(code)['ui_language'].to_s.strip.empty? }
    unless borrowing.empty?
      code = borrowing.first
      abort(I18n.t('build.ui_language_unknown', file: "site.#{code}.yml", value: SiteConfig.language_data(code)['ui_language'].to_s.strip,
                                                known: Languages.lendable.join(', ')))
    end
    abort(I18n.t('build.unknown_locale', langs: missing.join(', '))) unless missing.empty?

    # What a language says about itself lives in config/site.<lang>.yml, and
    # three things about that are worth stopping for rather than ignoring.
    #
    # A table keyed by language inside site.yml is the shape these keys had
    # before 1.9 shipped: two places to say one thing is how a site ends up
    # with two answers, so the old one is refused by name rather than read.
    %w[fallback ui_language].each do |key|
      next unless SiteConfig.key?('site', key)

      abort(I18n.t('build.language_key_moved', key: key, file: File.basename(SiteConfig.language_path('cs'))))
    end
    # A file for a language nothing publishes -- a typo in the name, or a
    # language taken out of site.locales and its file left behind. Nothing
    # would ever read it, and a file that does nothing looks like work done.
    # The site's own language is not one of those: it IS published, and
    # what it says about itself is config/site.yml. Told to "name the
    # language in site.locales", its author found it named there.
    if SiteConfig.language_files.key?(SITE_OWN_LANG)
      abort(I18n.t('build.language_file_own', file: "site.#{SITE_OWN_LANG}.yml"))
    end
    stray = SiteConfig.language_files.keys - (all - [SITE_OWN_LANG])
    unless stray.empty?
      abort(I18n.t('build.language_file_stray', files: stray.map { |code| "site.#{code}.yml" }.join(', ')))
    end
    # ...and what is wrong inside one (lib/language_file.rb): a key the
    # engine does not read, a translation of something site.yml does not
    # have, and a menu or footer list that goes to other places than the
    # site's own. Each of them silently does nothing, or does something the
    # site never said -- so every language is asked, not only this run's.
    #
    # Read against the file as WRITTEN: by now this run's own config has the
    # chrome of its language laid over it, and comparing a Czech menu with
    # itself would find nothing.
    own_config = SiteConfig.load_yaml(SiteConfig::PATH)
    sentences = (all - [SITE_OWN_LANG]).flat_map do |code|
      file = "site.#{code}.yml"
      LanguageFile.problems(own_config, SiteConfig.language_data(code)).group_by(&:first).flat_map do |kind, found|
        case kind
        when :unknown
          [I18n.t('build.language_key_unknown', file: file, keys: found.map { |f| f[1] }.join(', '),
                                                known: LanguageFile.known.join(', '))]
        when :orphan
          [I18n.t('build.language_key_orphan', file: file, keys: found.map { |f| f[1] }.join(', '))]
        when :empty
          # A sentence per table: the one about a tag speaks of a pill and
          # of `tags:`, and a series is neither.
          found.map { |f| f[1] }.group_by { |key| LanguageFile.series_key?(key) }.map do |series, keys|
            I18n.t(series ? 'build.language_series_empty' : 'build.language_label_empty', file: file, keys: keys.join(', '))
          end
        when :not_text
          [I18n.t('build.language_label_not_text', file: file, keys: found.map { |_, key, value| "#{key} (#{value.inspect})" }.join(', '))]
        else
          found.map do |_, key, detail|
            I18n.t('build.language_list_mismatch', file: file, key: key,
                                                   detail: LanguageFile.describe(detail, file) { |k, **v| I18n.t(k, **v) })
          end
        end
      end
    end
    abort(sentences.join("\n")) unless sentences.empty?
    all.freeze
  end

  # The languages the engine has words for, by the names of its locale
  # files: what `ui_language` may name.
  def lendable
    Dir.children(I18n::LOCALES_DIR).filter_map { |name| name[/\A([a-z]{2,3})\.yml\z/, 1] }.sort
  end

  # Which part of the tree this run's sweep owns.
  #
  # The sweep takes down whatever the build did not write, and two languages
  # are two runs -- so without this the second one carries off the first
  # one's site. A run in another language owns its own root and nothing else;
  # the site's own run owns the tree except the roots that belong to the
  # other languages. Everything else about the sweep is unchanged: an orphan
  # inside a language still goes on the next build OF THAT LANGUAGE.
  def prune_root
    LANG_ROOT.empty? ? PUBLIC_DIR : CONTENT_ROOT
  end

  def foreign_language_roots
    @foreign_language_roots ||= (SITE_LOCALES - [SITE_LANG]).reject { |lang| lang == SITE_OWN_LANG }
                                                            .map { |lang| File.join(PUBLIC_DIR, lang) }
  end

  def outside_this_language?(path)
    foreign_language_roots.any? { |root| path == root || path.start_with?("#{root}/") }
  end

  # What stands in for this language when a post has nothing in it, nearest
  # first. Only languages the site actually publishes, and never this one:
  # a chain that named a language nobody builds would point readers at a
  # tree that does not exist.
  #
  # 🪤 The site's own language is where every chain ENDS, so it never starts
  # one: a table written symmetrically (`cs: [de]` next to `de: [cs]`) reads
  # as the obvious thing to write and used to take the site apart, because
  # the run that builds the root then rendered the other language's words at
  # the other language's address -- and the permalink every link in the world
  # points at was gone.
  def fallback_chain
    named = LANG_ROOT.empty? ? [] : Array(SiteConfig.language_data(SITE_LANG)['fallback'])
    ((named.map { |code| code.to_s.strip } & SITE_LOCALES) - [SITE_LANG]).freeze
  end

  # Which language a post is SHOWN in here: its own words when it has them,
  # then the chain, and the site's own language at the end of it. The words
  # and the address come from this one answer together -- Czech words under
  # a link to the English page is worse than either of them alone.
  def stand_in_lang(post)
    return SITE_LANG if LANG_ROOT.empty?

    written = Translations.languages(post)
    return SITE_LANG if written.include?(SITE_LANG)

    FALLBACK_CHAIN.find { |lang| written.include?(lang) } || SITE_OWN_LANG
  end

  # What kind of post this is as ANOTHER language shows it: by that
  # language's own blocks, or the first it falls back on that has any --
  # and by the post's own where it was never written in any of them, which
  # in a run of a second language are the ones kept aside when this run's
  # words were laid over them (`__own_content`, build_blog.rb).
  def type_in(post, lang)
    entry = post['translations'].is_a?(Hash) ? post['translations'] : {}
    chain = lang.to_s == SITE_OWN_LANG ? [] : [lang.to_s] + Array(SiteConfig.language_data(lang.to_s)['fallback']).map { |code| code.to_s.strip }
    if chain.any? { |code| Translations.written?(entry[code]) }
      dominant_content_type(Translations.for_lang(post, chain.first, chain: chain.drop(1)))
    elsif post.key?('__own_content')
      dominant_content_type(post.merge('content' => post['__own_content']))
    else
      dominant_content_type(post)
    end
  end

  # Whether a listing has a page in a language. Tags, the archive, series
  # and the feed are built in every language from the same posts; a
  # listing by TYPE is the one that is not, because a type is read off the
  # blocks a language shows a post with (TYPES_BY_LANGUAGE).
  #
  # ...and a PAGE of that listing only as far as the listing goes there:
  # /type/<t>/page/N/ is there when that language has at least N fixed
  # pages of the type (TYPE_PAGES_BY_LANGUAGE).
  def listing_there?(bare, lang)
    type, number = bare.to_s.match(%r{\A/type/([^/]+)/(?:page/(\d+)/)?})&.captures
    return true if type.nil? || !defined?(TYPES_BY_LANGUAGE)
    return false unless TYPES_BY_LANGUAGE.fetch(lang.to_s, []).include?(type)

    number.nil? || !defined?(TYPE_PAGES_BY_LANGUAGE) || number.to_i <= TYPE_PAGES_BY_LANGUAGE.fetch(lang.to_s, {}).fetch(type, 0)
  end

  # Where a reader is sent when a page of a listing is not there in a
  # language: to the listing's own first page when the language has the
  # listing, which is nearer what they were reading than its front page.
  def listing_start(bare, lang)
    type = bare.to_s[%r{\A/type/([^/]+)/page/\d+/}, 1]
    type && defined?(TYPES_BY_LANGUAGE) && TYPES_BY_LANGUAGE.fetch(lang.to_s, []).include?(type) ? "/type/#{type}/" : '/'
  end

  def lang_root_for(lang)
    lang.to_s == SITE_OWN_LANG ? '' : "/#{lang}"
  end

  # The address without this run's language on it, so another one can be put
  # there instead.
  def bare_path(path)
    return path.to_s if LANG_ROOT.empty?

    text = path.to_s
    text.start_with?("#{LANG_ROOT}/") ? text.delete_prefix(LANG_ROOT) : text
  end

  # Every language this page can be offered in, and where each one goes.
  #
  # 🪤 For a POST the answer comes from the post, never from rewriting the
  # address: a language it has no words in has no page, so the offer leads to
  # that language's front page instead of a 404 -- and `has` is false, which
  # is what keeps it out of the alternates below. Listings, tags, the archive
  # and the feed are built in every language and carry no per-language name,
  # so for those the language on the address is simply swapped.
  def language_links(path, post: nil)
    return [] if SITE_LOCALES.length < 2

    bare = bare_path(path)
    SITE_LOCALES.map do |lang|
      root = lang_root_for(lang)
      has = post.nil? ? listing_there?(bare, lang) : (lang == SITE_OWN_LANG || Translations.languages(post).include?(lang))
      href = if !has
               post ? "#{root}/" : "#{root}#{listing_start(bare, lang)}"
             elsif post
               # 🪤 Asked of the POST, never worked out from the address being
               # read: the other language serves it under a slug of its own
               # (lib/translations.rb), so rewriting this one would offer an
               # address in the right language and the wrong words.
               "#{root}#{address_of(post, lang)}"
             else
               bare == '/' ? "#{root}/" : "#{root}#{bare}"
             end
      { 'lang' => lang, 'href' => href, 'has' => has }
    end
  end

  # A post's address in one language, without the language on it. The post's
  # own language answers with the post's own slug, which is what a post that
  # was never translated has everywhere.
  def address_of(post, lang)
    entry = post['translations'].is_a?(Hash) ? post['translations'][lang.to_s] : nil
    named = entry.is_a?(Hash) ? entry[Translations::ADDRESS_KEY].to_s.strip : ''
    PostAddress.path(post.merge('address_slug' => (named.empty? ? post['slug'] : named)),
                     year: post_time(post).year)
  end

  # What a crawler is told about the other languages of THIS page -- built
  # from the ones that exist, never from the list of languages the site
  # publishes. A site that promises an address it never wrote is a site that
  # sends readers to its own 404.
  def alternates_head(links)
    offered = links.select { |link| link['has'] }
    return '' if offered.length < 2

    rows = offered.map do |link|
      %(\n  <link rel="alternate" hreflang="#{h(link['lang'])}" href="#{h(SITE_BASE_URL + link['href'])}">)
    end
    own = offered.find { |link| link['lang'] == SITE_OWN_LANG }
    rows << %(\n  <link rel="alternate" hreflang="x-default" href="#{h(SITE_BASE_URL + own['href'])}">) if own
    rows.join
  end

  # A language's name in its own language, which is the only name a reader
  # looking for it can recognise: somebody who reads German is looking for
  # "Deutsch", not for "nemecky".
  LANGUAGE_NAMES = Hash.new do |cache, code|
    # Only for a language that has a file: `I18n.load_locale` aborts on one
    # that has none, and an abort is a SystemExit that no `rescue` here
    # would catch. SITE_LOCALES refuses those long before this runs.
    cache[code] = begin
      I18n.locale_file?(code) ? I18n.load_locale(code.to_s)['language_name'].to_s : ''
    rescue StandardError
      ''
    end
  end

  # A language's name, or its code when the engine has no name for it.
  def language_label(code)
    name = LANGUAGE_NAMES[code]
    name.empty? ? code.to_s.upcase : name
  end

  # The chip in the banner's corner, and it works the way the button beside
  # it works: ONE target, and a click anywhere on it moves you on. The
  # button cycles light → dark → system; this cycles to the next language
  # the site publishes and wraps around at the end.
  #
  # 🪤 It was a row of separate links at first, which looked the same and
  # behaved differently -- a reader had to hit two letters rather than the
  # chip (Daniel, 21. 9. 2026: "ne abych se musel trefovat"). Two controls
  # side by side that take a click differently are one control too many.
  #
  # The face still shows every language it publishes, with the one being
  # read marked, because that is what says where you are; what changed is
  # that the whole chip, not the code inside it, is the thing you click.
  def language_switcher_html(links)
    return '' if links.length < 2

    here = links.index { |link| link['lang'] == SITE_LANG } || 0
    nxt = links[(here + 1) % links.length]
    items = links.map do |link|
      classes = ['lang-switch__item']
      classes << 'is-current' if link['lang'] == SITE_LANG
      classes << 'is-elsewhere' unless link['has']
      current = link['lang'] == SITE_LANG ? ' aria-current="true"' : ''
      %(<span class="#{classes.join(' ')}"#{current}>#{h(link['lang'].to_s.upcase)}</span>)
    end
    # The name of the language the click LEADS TO -- a label saying "English"
    # on a control that takes you to Czech is the one thing worse than no
    # label at all. The same division the button keeps: codes on the face,
    # the sentence in the title and to a screen reader.
    name = language_label(nxt['lang'])
    %(<a class="lang-switch" href="#{h(nxt['href'])}" hreflang="#{h(nxt['lang'])}" ) +
      %(title="#{h(name)}" aria-label="#{h(name)}">#{items.join}</a>)
  end
end
