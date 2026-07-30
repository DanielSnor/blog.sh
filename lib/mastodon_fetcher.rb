# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

# lib/mastodon_fetcher.rb -- data for the "Recent toots" sidebar widget.
# Optional: only active when config/site.yml has a `widgets.toots` section.
#
# Originally fetched directly by the visitor's browser from the configured
# instance. That meant a request to a third-party API on every page view
# (slow, leaks the visitor's IP to that third party, and hits its rate
# limit). Now fetched server-side into public/toots.json -- same pattern as
# Pixelfed.
module MastodonFetcher
  # The widget's instance falls back to mastodon.instance -- the typical
  # site shows its own toots, and configuring the same hostname twice
  # meant the two could silently drift apart. An explicit
  # widgets.toots.instance still wins (a widget showing a different
  # account elsewhere remains possible).
  INSTANCE = SiteConfig.get('widgets', 'toots', 'instance') ||
             SiteConfig.get('mastodon', 'instance')
  ACCOUNT_ID = SiteConfig.get('widgets', 'toots', 'account_id')
  LIMIT = SiteConfig.get('widgets', 'toots', 'limit', default: 3)

  def self.configured?
    !INSTANCE.nil? && !ACCOUNT_ID.nil?
  end

  def self.fetch_items
    return [] unless configured?

    url = "https://#{INSTANCE}/api/v1/accounts/#{ACCOUNT_ID}/statuses" \
          "?limit=#{LIMIT}&exclude_replies=true"

    JSON.parse(FeedHttp.get(url)).map do |status|
      # For a boost, the real permalink and content live under s['reblog'] --
      # the wrapping status's own .url is the ActivityPub object URL
      # (.../statuses/ID/activity), which isn't a human-usable link.
      source = status['reblog'] || status
      {
        # getlocal: the API reports UTC, so without it a toot posted late in
        # the evening local time would be shown with the previous day's date.
        # site.timezone decides what "local" means (see SiteConfig).
        'date' => Time.parse(status['created_at']).getlocal.strftime(I18n.t('date_format')),
        'content' => source['content'].to_s,
        'url' => source['url'].to_s
      }
    end
  rescue StandardError => e
    warn "Mastodon feed fetch failed: #{e.message}"
    []
  end
end
