# frozen_string_literal: true

require_relative '../i18n'

module Import
  # The sentence every source that can bring pages across owes the person
  # afterwards. Pages arrive out of the listings, out of the archive and
  # out of the feed -- which is what they are for, and also means NOTHING
  # ON THE SITE LINKS TO THEM. On the old blog they were in the menu; here
  # the menu is derived from the content types until a site says otherwise.
  #
  # The engine will not write that `nav:` key itself: its absence means
  # "the derived menu", so adding entries would not add two items, it would
  # replace the whole menu with a hand-written one. That is a decision
  # about the site, and the site has to make it. What the engine can do is
  # not let somebody discover the gap by noticing that the About page is
  # missing from a site which otherwise looks complete.
  #
  # Its own file rather than a method in run.rb, because an adapter is
  # loaded (and tested) without the run layer -- feed.rb alone is enough to
  # parse a broken export, and it should not have to drag PostWriter in to
  # be able to say one sentence.
  PAGE_NOTE_SAMPLE = 5

  # Addresses the engine answers at itself. A page that lands on one of
  # them is not announced as "came across and is at /tag/" -- it is not
  # there, the site's own listing is -- and feed.rb names such pages
  # separately, as needing a rename. Kept here rather than inside one
  # adapter because the run now writes that sentence for all of them.
  RESERVED_PAGE_SLUGS = %w[posts tag type draft search markdown assets page rss.xml sitemap.xml
                           robots.txt 404 favicon.ico].freeze

  def self.pages_note(paths)
    return nil if paths.nil? || paths.empty?

    shown = paths.first(PAGE_NOTE_SAMPLE)
    listed = shown.join(', ')
    listed += I18n.t('import.note.pages_and_more', count: paths.size - shown.size) if paths.size > shown.size
    I18n.t('import.note.pages_imported', count: paths.size, paths: listed)
  end
end
