# frozen_string_literal: true

# build/tags.rb -- the tag pages: which tags the posts carry, a listing
# (and, for a tag in the menu, a feed) per tag, and the index of them all.
#
# Three functions, called where the three parts always ran in
# build_blog.rb, so the pages are written in the order they always were:
# `collect` early, because the writing app's site.js counts the tags too;
# `write_pages` once the menu (and with it FEED_TAG_SLUGS) is known;
# `write_index` after them. The map `collect` returns is the build's --
# the sitemap and the feeds read it later.
module Tags
  module_function

  def collect(posts)
    tags_map = {}
    overlong_tags = []
    posts.each do |post|
      # Folded by SLUG before anything is appended, because the map groups by
      # slug while the loop walked tag STRINGS: "sci-fi" and "Sci Fi", "Praha"
      # and "praha", "Cesko" and "Česko" -- or the same tag simply typed twice
      # -- are one page, and the post was appended to it once per spelling. The
      # listing then showed the post twice in a row, the tag's feed carried two
      # <item>s with the same guid, and the index said 2 beside a tag that one
      # post carries. First spelling wins, matching how the map already picks a
      # display name across posts.
      (post['tags'] || []).uniq { |tag| tag_slug(tag) }.each do |tag|
        slug = tag_slug(tag)
        next if slug.empty?

        # An address that will not fit a filename: mkdir died on it with a raw
        # ENAMETOOLONG, partway through writing the site. The tag stays on its
        # posts (as a pill that is not a link); only the listing page is
        # refused, and refused with a sentence.
        unless Slug.pageable?(slug)
          overlong_tags << tag.to_s[0, 60] unless overlong_tags.include?(tag.to_s[0, 60])
          next
        end

        # The name the pages and the index show: this language's word for the
        # tag where it has one (tag_label), so the listing, its title, its feed
        # and the index cannot disagree with the pills.
        tags_map[slug] ||= { name: tag_label(tag), posts: [] }
        tags_map[slug][:posts] << post
      end
    end
    overlong_tags.each do |name|
      warn t('build.tag_too_long', name: name)
    end
    tags_map
  end

  def write_pages(tags_map, index_template)
    tags_map.each do |slug, data|
      if FEED_TAG_SLUGS.include?(slug)
        Output.emit(File.join(CONTENT_ROOT, 'tag', slug, 'rss.xml'),
             Feeds.render_rss(data[:posts], path: loc("/tag/#{slug}/rss.xml"),
                        title: t('tag.feed_title', name: data[:name], site_title: SITE_TITLE),
                        description: t('tag.description', name: data[:name], author: SITE_AUTHOR, author_name: SITE_AUTHOR_NAME),
                        # The page this feed belongs to, in the language the
                        # feed is written in -- the site root was every
                        # language's answer, which sent a German subscriber
                        # to the Czech page.
                        link: "#{SITE_BASE_URL}#{loc("/tag/#{slug}/")}"))
      end
      write_listing(data[:posts], index_template, File.join(CONTENT_ROOT, 'tag', slug),
                    base_path: loc("/tag/#{slug}"), heading: data[:name],
                    heading_kind: t('tag.kind'), heading_variant: 'tag', own_tag: slug,
                    # The page's own slug, not its display name: the name is
                    # whichever spelling the archive used first, and looking
                    # the icon up by that made the heading depend on which
                    # post happened to come first.
                    heading_icon: TAG_ICONS[slug] || :tag,
                    # Only when there IS an index to go back to: a site whose
                    # tags all live on drafts builds no /tag/, and a heading
                    # linking there would be the dead menu item doctor refuses.
                    heading_href: (tags_map.empty? ? nil : loc('/tag/')),
                    feed_path: FEED_TAG_SLUGS.include?(slug) ? loc("/tag/#{slug}/rss.xml") : nil,
                    title: t('tag.title', name: data[:name], short_name: SITE_SHORT_NAME),
                    description: t('tag.description', name: data[:name], author: SITE_AUTHOR, author_name: SITE_AUTHOR_NAME))
    end
  end

  # --- The tag index ------------------------------------------------------
  #
  # /tag/ was a dead address: the site built a listing per tag and nothing
  # that showed them all, so the only complete list of a site's own subjects
  # lived in the terminal. Asked for by a site whose tags are subjects rather
  # than provenance, where the list is short enough to read at a glance.
  #
  # Every tag that has a page, and no others: a tag carried only by a draft,
  # a page or an unlisted post is drawn under its post as a flat pill with no
  # link, and listing it here would point at a 404.
  #
  # Sorted by the FOLDED name, not the raw one. Ruby sorts strings by bytes,
  # which puts every accented tag after z -- on one real archive that is
  # fifty-two of them, and the last six in byte order are `skoleni`,
  # `skolitel`, `sumava`, `svihov`, `zelnava`, `zivotvkorporatu` (with their
  # diacritics). A reader looking for one between `sirky` and `sport` would
  # not find it there. `browse` in the CLI already folds for this reason.
  def write_index(tags_map)
    unless tags_map.empty?
      tag_index_rows = tags_map.map { |slug, data| [slug, data[:name].to_s, data[:posts].length] }
                               .sort_by { |_, name, _| [Slug.fold(name), name] }
      # Names and counts are the whole page, so that is the whole key.
      tag_index_dest = File.join(CONTENT_ROOT, 'tag', 'index.html')
      tag_index_key = Digest::SHA256.hexdigest(tag_index_rows.map { |row| row.join(':') }.join(','))
      # A letter above each run of names, so seven hundred tags read as a
      # dictionary rather than as a wall. Taken from the FOLDED name, because
      # that is the order the list is in: `škola` belongs under S, where the
      # reader looking between `sirky` and `sport` will be. Anything that is
      # not a letter -- a tag that starts with a digit -- goes under `#`.
      #
      # Emitted as list items rather than as headings between lists: the list
      # is one <ul> and breaking it into twenty-seven of them would break the
      # wrapping with it -- a band is a full-width item in the same flow, the
      # way the archive's month is. The switch to count order takes them back
      # out (see assets/js/tag-index.js).
      last_letter = nil
      build_tag_index_items = lambda do
        tag_index_rows.flat_map do |slug, name, count|
        letter = index_letter(name)
        head = if letter == last_letter
                 []
               else
                 last_letter = letter
                 [%(<li class="tag-index-letter" id="#{letter_anchor(letter)}" aria-hidden="true">#{h(letter)}</li>)]
               end
        # The count travels in an attribute as well as in the text: the switch
        # reorders these in the DOM, and reading a number back out of rendered
        # markup is how a sort starts depending on how a number is punctuated.
        # Name and count in ONE pill, one link, one target: the count is what
        # makes the index a diagnostic rather than a menu (`pacmam 1` beside
        # `pacman 12` says on sight what a list of names alone never would),
        # and hung outside the pill it detached from its own name -- with the
        # list wrapped into lines, a number between two pills reads as easily
        # for the one that follows it.
        head + [%(<li class="tag-index-item" data-count="#{count}">) +
                %(<a class="tag-pill" href="#{loc("/tag/#{h(slug)}/")}">#{h(name)}) +
                %(<sup class="tag-index-count">#{count}</sup></a></li>)]
        end
      end
      Output.cached_emit(tag_index_dest, tag_index_key) do
        # How many tags there are, as every other listing's heading says how
        # many it holds -- this was the one that did not. The index is
        # rewritten whenever a tag comes or goes, so the number costs nothing.
        # A way to a letter, for a list that runs to several screens: the
        # letters that have a band below, each a link to it, behind a word
        # saying what the row is for. Read off the same rows with the same
        # function as the bands, so a letter here is a band that exists.
        # The switch hides the row in count order, where the bands are gone
        # and the links would lead nowhere (assets/js/tag-index.js).
        letters = tag_index_rows.map { |_, name, _| index_letter(name) }.uniq
        layout(listing_heading_html(t('tags.title'), variant: 'tags', icon: :tag, count: tags_map.size) +
               %(\n<p class="tag-index-jump" id="tag-index-jump">) +
               %(<span class="tag-index-jump__label">#{h(t('tags.jump_label'))}</span>) +
               letters.map { |letter| %(<a href="##{letter_anchor(letter)}">#{h(letter)}</a>) }.join +
               %(</p>) +
               %(\n<ul class="tag-index" id="tag-index">\n#{build_tag_index_items.call.join("\n")}\n</ul>),
               title: "#{t('tags.title')} \u2013 #{SITE_SHORT_NAME}",
               description: t('tags.description', site_title: SITE_TITLE),
               path: loc('/tag/'))
      end
    end
  end

  # The letter a tag stands under in the index: the first of its FOLDED
  # name, so `škola` is under S, and `#` for anything that is not a letter.
  def index_letter(name)
    letter = Slug.fold(name).to_s[0].to_s.upcase
    letter.match?(/[A-Z]/) ? letter : '#'
  end

  # The address of a letter's band on the index. `#` cannot be written into
  # an address after a `#`, so the band for the rest has a word.
  def letter_anchor(letter)
    "tag-letter-#{letter == '#' ? 'other' : letter.downcase}"
  end
end
