# frozen_string_literal: true

# build/feeds.rb -- the two documents written for machines.
#
# The RSS feed and the sitemap have almost nothing in common with the
# rest of the build: no template, no layout, no chrome, no cache key of
# their own. They take a list of posts and produce one file each, and
# they are the only place in the engine that has to think about XML
# escaping rather than HTML escaping -- which is exactly why they are
# worth keeping together and away from everything that escapes the other
# way.
#
# A move, not a rewrite: the build`s own constants and helpers still
# resolve from in here, because a module body`s lexical scope ends at
# Object and top-level defs are private methods of Object. The three
# heredocs are all <<~, so the indentation this file adds is stripped
# back out and the bytes on disk are the bytes that were there before.
module Feeds
  module_function

  def rss_item(post)
    url = "#{SITE_BASE_URL}#{post_path(post)}"
    title = CGI.escapeHTML(post_title_for(post))
    pub_date = post_time(post).rfc2822
    description = Blocks.render_content(post['content'], "#{SITE_BASE_URL}#{post_path(post)}")
    # A post's rendered HTML goes into the feed inside CDATA, and CDATA has
    # exactly one way to end. A post carrying "]]>" -- which an imported
    # embed_html can, since it is stored verbatim -- closed the section
    # early and the rest of it was read as feed markup: a reader could be
    # handed a <title> and <link> of the post's choosing, in an item that
    # still validated. The sequence is split across two CDATA sections, the
    # standard way, so it survives as text.
    # The same visibility rule the pills follow (a tag that slugs to nothing
    # is dropped), and the same coercion every other escape in this file
    # uses -- a non-string tag out of a hand-edited JSON used to end the
    # whole build in CGI.escapeHTML.
    categories = (post['tags'] || []).reject { |t| tag_slug(t).empty? }
                                     .map { |t| "<category>#{h(t)}</category>" }.join
    <<~ITEM
      <item>
        <title>#{xml_text(title)}</title>
        <link>#{url}</link>
        <guid isPermaLink="true">#{url}</guid>
        <pubDate>#{pub_date}</pubDate>
        <description><![CDATA[#{cdata_safe(description)}]]></description>
        #{categories}
      </item>
    ITEM
  end

  def render_rss(posts, path: '/rss.xml', title: SITE_TITLE, description: SITE_DESCRIPTION,
                 link: "#{SITE_BASE_URL}/")
    items = posts.first(RSS_ITEM_LIMIT).map { |post| rss_item(post) }.join
    # The newest post's date, not Time.now -- otherwise rss.xml differs on
    # every build and gets re-uploaded even when nothing changed.
    # RSS 2.0 wants an RFC-822 date-time here, and an empty element is not
    # one: a site with nothing in the stream yet published
    # <lastBuildDate></lastBuildDate>, which strict readers refuse along with
    # the whole feed. The build's own clock is the honest answer to "when was
    # this feed last built" when no post can answer it.
    last_build = (posts.first ? post_time(posts.first) : Time.now).rfc2822
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>
          <title>#{h(xml_text(title))}</title>
          <link>#{link}</link>
          <atom:link href="#{SITE_BASE_URL}#{path}" rel="self" type="application/rss+xml" />
          <description>#{h(xml_text(description))}</description>
          <language>#{SITE_LANG}</language>
          <lastBuildDate>#{last_build}</lastBuildDate>
          #{items}
        </channel>
      </rss>
    XML
  end

  def sitemap_url(loc, lastmod = nil)
    lastmod_tag = lastmod ? "<lastmod>#{lastmod}</lastmod>" : ''
    "<url><loc>#{loc}</loc>#{lastmod_tag}</url>"
  end

  # `entries`, not `posts`: the caller hands this posts AND pages, and the name
  # it used to have is what produced the defect below. Everything with an
  # address belongs on a sitemap, so the combined list is right for the URL
  # list -- but the archive is built from the STREAM alone, so it is given the
  # stream rather than left to guess from a list that is not one.
  def render_sitemap(entries, tags_map, content_types, stream)
    urls = [sitemap_url("#{SITE_BASE_URL}/", entries.first && post_time(entries.first).iso8601)]

    entries.each do |entry|
      urls << sitemap_url("#{SITE_BASE_URL}#{post_path(entry)}", post_time(entry).iso8601)
    end

    # max_by post_time, not max_by the stored STRING. The comment on the post
    # sort spells out why a lexical compare is wrong here: a post written
    # "2026-08-22 10:00" sorts above one written "2026-08-22T09:00+02:00"
    # because a space is below a T, and an offset moves an instant without
    # moving its text. Three lastmods were picked that way -- so a crawler
    # could be told a listing was last touched by the wrong post.
    tags_map.each do |slug, data|
      latest = data[:posts].max_by { |p| post_time(p) }
      urls << sitemap_url("#{SITE_BASE_URL}/tag/#{slug}/", latest && post_time(latest).iso8601)
    end

    content_types.each do |type|
      # From the stream, not from the combined list: /type/<t>/ shows posts
      # and never pages, so a page could hand the listing a lastmod for
      # something that listing does not contain. The archive block below was
      # given `stream` for exactly this reason, and says so.
      type_posts = stream.select { |entry| dominant_content_type(entry) == type }
      latest = type_posts.max_by { |p| post_time(p) }
      urls << sitemap_url("#{SITE_BASE_URL}/type/#{type}/", latest && post_time(latest).iso8601)
    end

    # Every series listing, for the same reason as a tag's: the build writes
    # it, every post in the series links to it, and the sitemap was the one
    # place that had never heard of it.
    SERIES_MAP.each do |slug, in_series|
      next unless Slug.pageable?(slug)

      latest = in_series.max_by { |p| post_time(p) }
      urls << sitemap_url("#{SITE_BASE_URL}/series/#{slug}/", latest && post_time(latest).iso8601)
    end

    # The tag index: one entry, and only when there is at least one tag with a
    # page of its own -- a site with no tags builds no index and must not be
    # advertising one.
    urls << sitemap_url("#{SITE_BASE_URL}/tag/", entries.first && post_time(entries.first).iso8601) if tags_map.any?

    # The archive index and one entry per year that has posts in it, from the
    # stream and only the stream -- the same list the map itself is grouped
    # from. Grouping the combined list sent crawlers to /archive/<year>/ for
    # every year that held nothing but a page: an About page older than the
    # oldest post, or a Contact page added to a blog whose last post was two
    # years ago. The root was worse -- written unconditionally, while the build
    # skips the whole map when the stream is empty.
    unless stream.empty?
      urls << sitemap_url("#{SITE_BASE_URL}/archive/", stream.first && post_time(stream.first).iso8601)
      stream.group_by { |post| post_time(post).year }.each do |year, in_year|
        latest = in_year.max_by { |p| post_time(p) }
        urls << sitemap_url("#{SITE_BASE_URL}/archive/#{year}/", latest && post_time(latest).iso8601)
      end
    end

    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        #{urls.join("\n  ")}
      </urlset>
    XML
  end
end
