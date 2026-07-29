# frozen_string_literal: true

require 'json'
require_relative 'pixelfed_fetcher'
require_relative 'mastodon_fetcher'
require_relative 'github_fetcher'
require_relative 'bluesky_fetcher'
require_relative 'rss_fetcher'

# lib/sidebar.rb -- writes one JSON file per configured sidebar widget (see
# config/site.yml's `widgets:` section -- any subset, including none, is
# fine; each fetcher's own `configured?` decides whether it's active).
#
# All three are fetched server-side and the client reads them same-origin.
# Originally only Pixelfed worked this way (its feed has no CORS header),
# while toots and commits were fetched directly by the visitor's browser
# from the configured Mastodon instance / api.github.com -- that meant 4+
# requests to third-party APIs on every page view, hit GitHub's rate limit
# (60/hour per IP), and leaked visitors' IPs to those third parties.
#
# Written by both build/build_blog.rb (every build) and
# scripts/refresh_sidebar.rb (cron, without rebuilding the whole site).
module Sidebar
  ALL_FEEDS = {
    'pixelfed.json' => PixelfedFetcher,
    'toots.json' => MastodonFetcher,
    'commits.json' => GithubFetcher,
    'bluesky.json' => BlueskyFetcher,
    'rss.json' => RssFetcher
  }.freeze
  FEEDS = ALL_FEEDS.select { |_, fetcher| fetcher.configured? }.freeze

  module_function

  def read(path)
    File.read(path) if File.exist?(path)
  end

  # Used as a fallback source when a fetch fails right after public/ was
  # wiped and rewritten -- kept for scripts/refresh_sidebar.rb, which only
  # touches these three files without a full rebuild.
  def snapshot(public_dir)
    FEEDS.keys.to_h { |name| [name, read(File.join(public_dir, name))] }
  end

  # Returns a hash of "filename" => item count, or nil when the fetch failed
  # and the last known content was kept instead. An empty result almost
  # always means a network error, not that the account has no posts -- and
  # publishing an empty widget because of a one-minute outage is worse than
  # briefly stale data.
  def write_all(public_dir, previous = {})
    FEEDS.to_h do |name, fetcher|
      path = File.join(public_dir, name)
      items = fetcher.fetch_items
      fallback = items.empty? ? (previous[name] || read(path)) : nil

      if fallback
        warn "#{name}: fetch returned nothing, keeping last known content"
        File.write(path, fallback)
        [name, nil]
      else
        File.write(path, items.to_json)
        [name, items.size]
      end
    end
  end

  def summary(results)
    results.map { |name, count| "#{name}: #{count.nil? ? 'unchanged (fetch failed)' : "#{count} item(s)"}" }.join(', ')
  end
end
