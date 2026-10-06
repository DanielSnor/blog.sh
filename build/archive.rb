# frozen_string_literal: true

# build/archive.rb -- the map of the whole archive and a page per year.
# One function, called where this part always ran in build_blog.rb; it
# needs nothing from the build but the posts of this run.
module Archive
  module_function

  # Longer than any blog, shorter than a typo. 200 years of empty rows is
  # already nonsense to look at; 18,000 is a page nobody can open.
  SPAN_MAX = 200

  # --- The archive index -------------------------------------------------
  #
  # A map of the whole archive in two levels and no more. /archive/ is a row
  # per year with a strip of twelve months; /archive/<year>/ is one line per
  # post. No excerpts and no pictures: this is an index, not another listing,
  # and the point of it is that a reader can see the shape of twenty-three
  # years at once -- which nothing on the site could show before. Pagination
  # cannot: it is anchored from the oldest post, so /page/128/ says nothing
  # about whether it is 2009 or 2014.
  #
  # Grouped by the year of the post's ADDRESS, not of its displayed date.
  # Those two can differ by one for a post published either side of midnight
  # on 31 December, and the address is what this is a map OF -- the checker
  # compares paths, and a row pointing at a year the post does not live in
  # would be a dead link the moment it happened.
  #
  # Cheap by construction, which is why the year pages are safe to have: a
  # new post rewrites the map and the current year and nothing else. 2014 has
  # not changed since new year's eve 2014 and never will, so a deploy that
  # compares content has nothing to upload for it.
  def write(posts)
    archive_path = loc('/archive/')
    archive_by_year = posts.group_by { |post| post_time(post).year }

    unless archive_by_year.empty?
      # Every year between the first and the last, including the ones with
      # nothing in them -- sean.cz has a silent 2025 between 2024 and 2026, and
      # a map that skipped it would draw an axis that lies about the gap.
      #
      # ...up to a point. The span was unbounded, and one mistyped year is all
      # it takes: 20226 for 2026 parses, gives the post a real address, and
      # draws 18,201 rows -- a 12.8 MB page that hangs a browser and that
      # deploy then uploads, while the build's summary says "posts: 2" and both
      # check and doctor call the archive sound. Past the bound the map falls
      # back to the years that actually hold something, so a typo costs the
      # empty-year axis rather than the whole page, and it is said out loud.
      span_from = archive_by_year.keys.min
      span_to = archive_by_year.keys.max
      archive_span = if span_to - span_from >= SPAN_MAX
                       warn t('build.archive_span_absurd', from: span_from, to: span_to)
                       archive_by_year.keys.sort.reverse
                     else
                       span_to.downto(span_from).to_a
                     end

      month_cells = lambda do |year, by_month|
        (1..12).map do |m|
          count = (by_month[m] || []).length
          label = CGI.escapeHTML(m.to_s)
          if count.zero?
            %(<span class="archive-month is-empty">#{label}</span>)
          else
            # Four steps of shading, because "has posts / has none" is not the
            # thing worth seeing: on this archive a month holds anywhere from
            # one post to eighty-seven, and a map that draws those the same
            # answers a question nobody asked. The thresholds are read off a
            # real archive rather than picked round: most months sit under
            # fifteen, and the handful above forty are the bursts.
            level = if count < 5 then 1
                    elsif count < 15 then 2
                    elsif count < 40 then 3
                    else 4
                    end
            %(<a class="archive-month is-l#{level}" href="#{loc("/archive/#{year}/#m#{format('%02d', m)}")}" ) +
              %(title="#{count}">#{label}</a>)
          end
        end.join
      end

      rows = archive_span.map do |year|
        in_year = archive_by_year[year] || []
        by_month = in_year.group_by { |post| post_time(post).month }
        name = in_year.empty? ? %(<span class="archive-year-name">#{year}</span>) : %(<a class="archive-year-name" href="#{loc("/archive/#{year}/")}">#{year}</a>)
        %(<li class="archive-year#{in_year.empty? ? ' is-empty' : ''}">#{name}) +
          %(<span class="archive-year-count">#{in_year.length}</span>) +
          %(<span class="archive-months">#{month_cells.call(year, by_month)}</span></li>)
      end

      # Keyed on the digest of the rows themselves, not on a summary of them.
      # The summary was "year:count" -- and the map draws MONTHS: a cell per
      # month, shaded in four steps by how many posts it holds, linking to an
      # anchor on the year page. So a post whose date moved from March to
      # January changed the cells at both ends, the shading of one of them and
      # the anchor the other pointed at, while the year's count sat exactly
      # where it was and the key never moved. The map then disagreed with the
      # year page it links to, and kept disagreeing.
      #
      # The rows are built above whatever the cache decides, so this costs one
      # hash of a few kilobytes -- and, unlike a summary, it cannot drift from
      # what is drawn: anything added to a cell is in the key the same day it
      # is on the page.
      #
      # The YEAR pages below are what this buys something on anyway: 2014 has
      # not changed since new year's eve 2014 and never will.
      Output.cached_emit(File.join(CONTENT_ROOT, 'archive', 'index.html'),
                  Digest::SHA256.hexdigest(rows.join)) do
        # The whole archive, counted: the sum of the numbers the rows show,
        # so the key above already holds it.
        layout(listing_heading_html(t('archive.title'), variant: 'archive', icon: :calendar,
                                    count: archive_by_year.values.sum(&:length)) +
               %(\n<ul class="archive-map">\n#{rows.join("\n")}\n</ul>),
               title: "#{t('archive.title')} – #{SITE_SHORT_NAME}",
               description: t('archive.description', site_title: SITE_TITLE),
               path: archive_path)
      end

      archive_span.each do |year|
        in_year = archive_by_year[year] || []
        # A year nobody wrote in gets a row on the map but no page of its own:
        # there is nothing to put on it, and an empty page is an invitation to
        # a dead end.
        next if in_year.empty?

        year_dest = File.join(CONTENT_ROOT, 'archive', year.to_s, 'index.html')
        year_key = Output.posts_digest(in_year)
        if BuildCache.page_fresh?(year_dest, year_key)
          Output.keep(year_dest)
          next
        end

        sections = in_year.group_by { |post| post_time(post).month }.sort.map do |month, in_month|
          # The month heading is a number, the way this site writes dates: two
          # of the three shipped languages spell months with digits anyway, and
          # spelling them out would mean thirty-six new translations for the
          # one language that does not.
          # Its own copy of the key above, and it has to say the same thing:
          # the year page's stated contract is date order inside the month.
          lines = in_month.sort_by { |post| [post_time(post), post['slug']] }.map do |post|
            # The attribute and the text are the same date said twice, one for
            # a machine and one for a reader -- that is what <time> means. The
            # attribute used to carry the STORED date while the text showed the
            # local day, so a post filed at a year's turn read
            # `<time datetime="2025-12-31">1.</time>`: a value and a rendering
            # of it that disagree. Which year the post is FILED under is a
            # separate decision and stays as it was -- the address year, so the
            # page and /posts/<year>/ agree.
            %(<li><time datetime="#{h(post_display_time(post).strftime('%Y-%m-%d'))}">) +
              %(#{post_display_time(post).day}.</time> ) +
              %(<a href="#{h(post_href(post))}">#{h(post_title_for(post))}</a></li>)
          end
          %(<section class="archive-section" id="m#{format('%02d', month)}">) +
            %(<h2>#{month}</h2>\n<ul class="archive-list">\n#{lines.join("\n")}\n</ul></section>)
        end

        # The heading says a kind and a value, as a tag's and a series' do:
        # "Archive" and "2026" used to be one run of text inside one link, so
        # a stylesheet that sets the value apart everywhere else could not do
        # it here. Cut from the one translated title, which still names the
        # page in its <title>; a language that puts the year anywhere but
        # last keeps the heading whole, as it was.
        year_kind, year_rest = t('archive.year_title', year: "\u0000").split("\u0000", 2)
        year_heading = if year_rest == '' && !year_kind.strip.empty?
                         listing_heading_html(year.to_s, kind: year_kind.strip, variant: 'archive',
                                              icon: :calendar, icon_first: true,
                                              value_href: archive_path, count: in_year.length)
                       else
                         listing_heading_html(t('archive.year_title', year: year), variant: 'archive',
                                              icon: :calendar, value_href: archive_path,
                                              count: in_year.length)
                       end
        BuildCache.remember_page(year_dest, year_key)
        Output.emit(year_dest,
             layout(year_heading + "\n" +
                    sections.join("\n") +
                    # Below the list and on the left, which is where a post's own
                    # "back" link has always sat. A way out belongs at the end of
                    # the thing you are reading, not above it.
                    %(\n<nav class="pagination back" aria-label="#{h(t('pagination.nav_label'))}">) +
                    %(<a href="#{archive_path}">#{h(t('archive.back'))}</a></nav>),
                    title: "#{t('archive.year_title', year: year)} – #{SITE_SHORT_NAME}",
                    description: t('archive.year_description', year: year, site_title: SITE_TITLE),
                    path: loc("/archive/#{year}/")))
      end
    end
  end
end
