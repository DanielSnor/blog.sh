# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

# lib/bluesky_fetcher.rb -- data for the "Recent Bluesky posts" sidebar
# widget. Optional: only active when config/site.yml has a
# `widgets.bluesky` section. Same server-side pattern as the other
# widgets (fetched by cron into public/bluesky.json, read same-origin by
# the visitor's browser), using the public AppView -- no auth involved.
#
# The handle falls back to bluesky.handle, mirroring how the toots
# widget falls back to mastodon.instance: the typical site shows its own
# posts and shouldn't configure the same handle twice. An explicit
# widgets.bluesky.handle still wins.
module BlueskyFetcher
  HANDLE = SiteConfig.get('widgets', 'bluesky', 'handle') ||
           SiteConfig.get('bluesky', 'handle')
  LIMIT = SiteConfig.get('widgets', 'bluesky', 'limit', default: 3)
  APPVIEW = 'https://public.api.bsky.app'

  # The section itself must exist -- without this check, merely having
  # Bluesky as the comments network would silently switch the widget on.
  def self.configured?
    !SiteConfig.get('widgets', 'bluesky').nil? && !HANDLE.nil?
  end

  def self.fetch_items
    return [] unless configured?

    url = "#{APPVIEW}/xrpc/app.bsky.feed.getAuthorFeed" \
          "?actor=#{URI.encode_www_form_component(HANDLE)}&limit=#{LIMIT}&filter=posts_no_replies"

    JSON.parse(FeedHttp.get(url)).fetch('feed', []).first(LIMIT).map do |item|
      post = item['post']
      # For a repost the widget shows the reposted content but dates it
      # by the repost -- same as the Mastodon widget treats boosts.
      date = item.dig('reason', 'indexedAt') || post.dig('record', 'createdAt')
      rkey = post['uri'].to_s.split('/').last
      {
        # getlocal for the same reason as in mastodon_fetcher: the remote
        # timestamp is UTC, the reader thinks in site.timezone.
        'date' => Time.parse(date).getlocal.strftime(I18n.t('date_format')),
        # Plain text, not sanitized HTML like Mastodon's -- stored as
        # 'text' so sidebar.js knows to escape it wholesale.
        'text' => post.dig('record', 'text').to_s,
        'url' => "https://bsky.app/profile/#{post.dig('author', 'handle')}/post/#{rkey}"
      }
    end
  rescue StandardError => e
    warn "Bluesky feed fetch failed: #{e.message}"
    []
  end
end
