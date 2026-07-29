# frozen_string_literal: true

require 'rexml/document'
require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

# lib/pixelfed_fetcher.rb -- fetches data for the "Recent Pixelfed posts"
# sidebar widget. Optional: only active when config/site.yml has a
# `widgets.pixelfed` section.
#
# Pixelfed's public API requires login on most instances, but the Atom feed
# is open -- it just has no CORS header, so a browser can't fetch it
# directly. That's why this runs server-side; the Mastodon and GitHub
# widgets are fetched server-side too these days, just for different reasons
# (rate limits and not leaking visitors' IPs to third parties). Called via
# lib/sidebar.rb from both build/build_blog.rb and
# scripts/refresh_sidebar.rb (the cron refresh that skips rebuilding the
# whole site); assets/js/sidebar.js then reads the resulting
# public/pixelfed.json same-origin.
module PixelfedFetcher
  FEED_URL = SiteConfig.get('widgets', 'pixelfed', 'feed_url')
  LIMIT = SiteConfig.get('widgets', 'pixelfed', 'limit', default: 3)

  def self.configured?
    !FEED_URL.nil?
  end

  def self.fetch_items
    return [] unless configured?

    doc = REXML::Document.new(FeedHttp.get(FEED_URL))

    doc.elements.to_a('feed/entry').first(LIMIT).map do |entry|
      full_title = entry.elements['title'].text.to_s
      title = full_title.split("\n").first.to_s
      link = entry.elements["link[@rel='alternate']"]&.attribute('href')&.value ||
             entry.elements['id']&.text
      date = Time.parse(entry.elements['updated'].text).strftime(I18n.t('date_format'))
      content_el = entry.elements['content']
      content = content_el ? content_el.texts.map(&:to_s).join : ''
      image = content[/src="([^"]+)"/, 1]

      { 'date' => date, 'title' => title, 'url' => link.to_s, 'image' => image }
    end
  rescue StandardError => e
    warn "Pixelfed feed fetch failed: #{e.message}"
    []
  end
end
