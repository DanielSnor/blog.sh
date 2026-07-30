# frozen_string_literal: true

require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

# lib/rss_fetcher.rb -- data for a generic "latest from any feed" sidebar
# widget. Optional: only active when config/site.yml has a `widgets.rss`
# section. Points at any RSS 2.0 or Atom feed: another blog, a YouTube
# channel, a podcast -- or X through a self-hosted Nitter instance, which
# is the one workable route left to an X widget (the official API bills
# per read, official embeds are third-party JS, and this engine serves
# neither).
#
# Same server-side pattern as every other widget: fetched by cron into
# public/rss.json, read same-origin by the visitor's browser.
module RssFetcher
  FEED_URL = SiteConfig.get('widgets', 'rss', 'feed_url')
  LIMIT = SiteConfig.get('widgets', 'rss', 'limit', default: 3)

  module_function

  def configured?
    !FEED_URL.nil?
  end

  def fetch_items
    return [] unless configured?

    # rexml is a default gem, not core stdlib -- present with a normal Ruby
    # install, but some distros split it into a separate package (e.g.
    # Debian/Ubuntu's `ruby-full` vs the bare `ruby`). Required here, not at
    # load time, so a build with no `widgets.rss` configured never needs it.
    begin
      require 'rexml/document'
    rescue LoadError
      warn "RSS feed fetch failed: rexml isn't installed -- `gem install rexml` " \
           '(or install your distro\'s full Ruby package, e.g. ruby-full on Debian/Ubuntu).'
      return []
    end

    parse(FeedHttp.get(FEED_URL))
  rescue StandardError => e
    warn "RSS feed fetch failed: #{e.message}"
    []
  end

  # Both feed dialects, autodetected by the root element: RSS 2.0
  # (rss > channel > item, pubDate) and Atom (feed > entry, link
  # rel=alternate, updated). Time.parse reads both date formats.
  def parse(xml)
    doc = REXML::Document.new(xml)
    if doc.root&.name == 'feed'
      doc.elements.to_a('feed/entry').first(LIMIT).map { |e| atom_item(e) }
    else
      doc.elements.to_a('rss/channel/item').first(LIMIT).map { |i| rss_item(i) }
    end
  end

  def atom_item(entry)
    link = entry.elements["link[@rel='alternate']"]&.attribute('href')&.value ||
           entry.elements['link']&.attribute('href')&.value
    date = entry.elements['published']&.text || entry.elements['updated']&.text
    {
      'date' => format_date(date),
      'title' => item_title(entry.elements['title']&.text, entry.elements['summary']&.text),
      'url' => link.to_s
    }
  end

  def rss_item(item)
    {
      'date' => format_date(item.elements['pubDate']&.text),
      'title' => item_title(item.elements['title']&.text, item.elements['description']&.text),
      'url' => item.elements['link']&.text.to_s
    }
  end

  # RSS titles are optional (this engine's own feed can emit untitled
  # posts) -- fall back to the description with any markup stripped.
  def item_title(title, description)
    return title.strip unless title.to_s.strip.empty?

    text = description.to_s.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip
    text.length > 80 ? "#{text[0, 80].sub(/\s+\S*\z/, '')}…" : text
  end

  def format_date(raw)
    return '' if raw.to_s.empty?

    # getlocal: a feed states its items' dates in whatever offset the
    # publisher uses, so render in site.timezone to match the rest of the
    # page -- see mastodon_fetcher for the same reasoning.
    Time.parse(raw).getlocal.strftime(I18n.t('date_format'))
  rescue ArgumentError
    ''
  end
end
