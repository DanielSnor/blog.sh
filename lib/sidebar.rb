# frozen_string_literal: true

require 'json'
require_relative 'site_config'
require_relative 'public_file'
require_relative 'pixelfed_fetcher'
require_relative 'mastodon_fetcher'
require_relative 'commits_fetcher'
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
    'commits.json' => CommitsFetcher,
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
  # Whether the site draws a sidebar at all. Read here rather than only in
  # the build, because this is the half that leaves the machine: a site with
  # `layout: sidebar: false` was still asking Mastodon, Pixelfed, an RSS
  # host and a forge for data on every cron tick, and then writing it into
  # files no page would ever include. Wasteful, but mainly it is four
  # third-party contacts the author had already switched off.
  def enabled?
    SiteConfig.get('layout', 'sidebar', default: true) != false
  end

  def write_all(public_dir, previous = {})
    # Nothing fetched, nothing written -- and nothing REPORTED either, since
    # not asking is not a failure. It used to return false for every feed,
    # and false is already this module's marker for something else entirely:
    # summary turns it into "emptied (config cannot work)". An author who
    # switched the column off while keeping their widget settings therefore
    # got a half-hourly cron mail asserting their config was broken, when it
    # was fine and nothing had been emptied -- the exact opposite of what
    # the switch was added for. An empty result says nothing at all, which
    # is what "not asked" means.
    return {} unless enabled?

    FEEDS.to_h do |name, fetcher|
      path = File.join(public_dir, name)
      begin
        items = fetcher.fetch_items
      rescue CommitsFetcher::BadConfig => e
        # A setting that cannot work is not an outage: keeping the last good
        # answer would hide it for as long as the mistake stands. The card
        # empties instead, and an empty card is not drawn -- which is how
        # somebody finds out, on the site rather than in cron mail.
        warn "#{name}: #{e.message}"
        PublicFile.write(path, '[]')
        next [name, false]
      end
      fallback = items.empty? ? (previous[name] || read(path)) : nil

      if fallback
        warn "#{name}: fetch returned nothing, keeping last known content"
        PublicFile.write(path, fallback)
        [name, nil]
      else
        PublicFile.write(path, items.to_json)
        [name, items.size]
      end
    end
  end

  def summary(results)
    results.map do |name, count|
      case count
      when nil then "#{name}: unchanged (fetch failed)"
      when false then "#{name}: emptied (config cannot work)"
      else "#{name}: #{count} item(s)"
      end
    end.join(', ')
  end
end
