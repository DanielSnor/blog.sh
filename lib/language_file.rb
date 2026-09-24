# frozen_string_literal: true

# lib/language_file.rb -- what config/site.<lang>.yml may say, and what it
# means.
#
# A language of the site describes itself in a file of its own beside
# config/site.yml. Two kinds of thing go in it:
#
#   settings -- what this language does: `fallback` (which language
#               stands in when it has nothing) and `ui_language` (whose
#               interface it borrows when the engine has none of its own).
#   chrome   -- what the site says about itself, in this language: the
#               same keys config/site.yml has for its title, description,
#               banner, about text, footer, menu and widget headings, only
#               in other words.
#
# Pure data in, data out -- no files, no SiteConfig -- because two
# programs ask: the build, which lays the chrome over site.yml for the run
# of that language and refuses a file it cannot honour, and `check`, which
# says the same thing about an archive without building it. One answer for
# both, so neither can pass what the other refuses.
module LanguageFile
  SETTINGS = %w[fallback ui_language].freeze

  # The chrome a language may translate: each section of site.yml and the
  # keys under it that are WORDS. Everything else in those sections -- the
  # banner's picture and its size, the author, the base URL, the colours --
  # is a fact about the site, the same in every language, and translating
  # it would make two sites.
  TEXTS = {
    'site' => %w[title short_name description],
    'banner' => %w[claim alt],
    'about' => %w[heading html],
    'footer' => %w[links_heading links note_heading note_html copyright social_heading]
  }.freeze
  # A widget's heading is words; its account, instance and limit are not.
  WIDGET_TEXTS = %w[heading].freeze
  # What the reader of this language sees for a tag: `tags:` maps a tag to
  # its word here. The tag itself -- its address, its page, the posts that
  # carry it -- is one ID in every language; only the label is translated.
  TAG_LABELS = 'tags'

  # The lists with places in them. A translation says the same places in
  # the same order with other words: a menu that drifts apart between the
  # languages is a second site, and the reader who switches language would
  # lose the item they were about to click.
  PLACED_LISTS = {
    %w[nav] => ->(entry) { entry['tag'].to_s.strip.empty? ? entry['url'].to_s.strip : "tag:#{entry['tag'].to_s.strip}" },
    %w[footer links] => ->(entry) { entry['url'].to_s.strip }
  }.freeze

  module_function

  # Every key a language file may carry, as the one-line list a refusal
  # names.
  def known
    SETTINGS + TEXTS.flat_map { |section, keys| keys.map { |key| "#{section}.#{key}" } } +
      %w[nav] + WIDGET_TEXTS.map { |key| "widgets.<name>.#{key}" } + [TAG_LABELS]
  end

  # The chrome of one language laid over the site's own config: sections
  # merged key by key, lists replaced whole. Only what the file may say is
  # taken -- a key it may not say is refused by `problems`, and a build
  # that has been told to go on regardless must not quietly honour it.
  def localize(own, lang_data)
    merged = Marshal.load(Marshal.dump(own.is_a?(Hash) ? own : {}))
    return merged unless lang_data.is_a?(Hash)

    TEXTS.each do |section, keys|
      given = lang_data[section]
      next unless given.is_a?(Hash)

      merged[section] = {} unless merged[section].is_a?(Hash)
      keys.each { |key| merged[section][key] = given[key] if given.key?(key) }
    end
    merged['nav'] = lang_data['nav'] if lang_data.key?('nav')
    merged[TAG_LABELS] = lang_data[TAG_LABELS] if lang_data[TAG_LABELS].is_a?(Hash)
    widgets = lang_data['widgets'].is_a?(Hash) ? lang_data['widgets'] : {}
    widgets.each do |name, conf|
      next unless conf.is_a?(Hash) && dig(merged, 'widgets', name).is_a?(Hash)

      WIDGET_TEXTS.each { |key| merged['widgets'][name][key] = conf[key] if conf.key?(key) }
    end
    merged
  end

  # What is wrong with a language file, as data: [kind, key, detail].
  #
  #   :unknown  -- a key the engine does not read (a typo, or a fact about
  #                the site that is the same in every language)
  #   :orphan   -- a translation of something the site's own config does
  #                not have, so there is nothing for it to replace
  #   :mismatch -- a list with places in it that names other places than
  #                the site's own does, or the same ones in another order
  def problems(own, lang_data)
    return [] unless lang_data.is_a?(Hash)

    own = {} unless own.is_a?(Hash)
    found = []
    lang_data.each do |key, value|
      if SETTINGS.include?(key) || key == 'nav'
        next
      elsif TEXTS.key?(key)
        next found << [:unknown, key, nil] unless value.is_a?(Hash)

        value.each_key { |sub| found << [:unknown, "#{key}.#{sub}", nil] unless TEXTS[key].include?(sub) }
      elsif key == TAG_LABELS
        next found << [:unknown, key, nil] unless value.is_a?(Hash)

        value.each { |tag, label| found << [:unknown, "#{key}.#{tag}", nil] unless label.is_a?(String) && !label.strip.empty? }
      elsif key == 'widgets'
        next found << [:unknown, key, nil] unless value.is_a?(Hash)

        value.each do |name, conf|
          next found << [:orphan, "widgets.#{name}", nil] unless dig(own, 'widgets', name).is_a?(Hash)
          next found << [:unknown, "widgets.#{name}", nil] unless conf.is_a?(Hash)

          conf.each_key { |sub| found << [:unknown, "widgets.#{name}.#{sub}", nil] unless WIDGET_TEXTS.include?(sub) }
        end
      else
        found << [:unknown, key, nil]
      end
    end
    PLACED_LISTS.each do |path, place|
      next unless written?(lang_data, path)

      name = path.join('.')
      theirs = dig(lang_data, *path)
      mine = dig(own, *path)
      next found << [:orphan, name, nil] unless mine.is_a?(Array)
      next found << [:mismatch, name, :not_a_list] unless theirs.is_a?(Array)

      detail = list_difference(mine.map { |e| e.is_a?(Hash) ? place.call(e) : '' },
                               theirs.map { |e| e.is_a?(Hash) ? place.call(e) : '' })
      found << [:mismatch, name, detail] if detail
    end
    found
  end

  def written?(data, path)
    parent = path.length == 1 ? data : dig(data, *path[0..-2])
    parent.is_a?(Hash) && parent.key?(path.last)
  end

  # Hash#dig raises on a String in the middle -- `footer: "text"` is a
  # shape somebody writes -- and a config that is wrong must be SAID, not
  # met as a TypeError.
  def dig(data, *path)
    path.reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
  end

  # The labels a language gives its tags, by the tag's slug -- the ID the
  # engine folds every spelling of a tag into, so `Filozofie:` and
  # `filozofie:` name the one page. The slug is the caller's to compute
  # (Slug.slugify), which keeps this file free of it.
  def tag_labels(data)
    given = data.is_a?(Hash) ? data[TAG_LABELS] : nil
    return {} unless given.is_a?(Hash)

    given.each_with_object({}) do |(tag, label), labels|
      next unless label.is_a?(String) && !label.strip.empty?

      labels[yield(tag.to_s)] = label.strip
    end
  end

  # The difference `problems` found, as a sentence -- asked of whoever holds
  # the words (the build and `check` both pass I18n.t in), so this file
  # stays free of the locale machinery and the two programs say it alike.
  def describe(detail, file)
    kind, *rest = Array(detail)
    case kind
    when :count
      yield('language_file.list_count', mine: rest[0], theirs: rest[1], file: file)
    when :item
      mine, theirs = rest[1..2].map { |place| place.to_s.empty? ? '?' : place }
      yield('language_file.list_item', n: rest[0], mine: mine, theirs: theirs, file: file)
    else
      yield('language_file.list_shape', file: file)
    end
  end

  # nil when the two lists name the same places in the same order;
  # otherwise the first thing a reader needs to fix it.
  def list_difference(mine, theirs)
    return [:count, mine.length, theirs.length] unless mine.length == theirs.length

    at = mine.each_index.find { |i| mine[i] != theirs[i] }
    at && [:item, at + 1, mine[at], theirs[at]]
  end
end
