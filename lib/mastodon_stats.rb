# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'feed_http'

# lib/mastodon_stats.rb -- favourite/boost/comment counts for tooted posts,
# precomputed server-side into public/stats.json.
#
# Originally fetched by the visitor's browser: a request to the Mastodon
# instance for every post in a listing. Harmless while only three posts were
# tooted, but it grows with every new article -- and it's exactly the
# pattern already removed from the sidebar widgets (rate limits, leaking
# visitors' IPs to a third party, waiting on a foreign server's response).
#
# Fetched exclusively by cron via scripts/refresh_sidebar.rb, not the normal
# build: that's two requests per tooted post, which would gradually choke
# the build.
#
# Engagement (likes, boosts, comments) barely changes on old posts -- so
# `fetch_all(recent_only: true)` only live-refreshes posts younger than
# RECENT_WINDOW_DAYS, leaving older ones to an infrequent full refresh
# (scripts/refresh_sidebar.rb runs it roughly once a week). Without this,
# every cron run would make 2 requests per *every* published post ever --
# harmless today, hundreds of requests per run a few years from now.
module MastodonStats
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  RECENT_WINDOW_DAYS = 90

  module_function

  def parse_toot_url(url)
    m = url.to_s.match(%r{\Ahttps?://([^/]+)/@[^/]+/(\d+)}) ||
        url.to_s.match(%r{\Ahttps?://([^/]+)/users/[^/]+/statuses/(\d+)})
    m && { instance: m[1], id: m[2] }
  end

  def toot_entries
    Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
      post = JSON.parse(File.read(file, encoding: 'utf-8'))
      next nil unless post['mastodon_url']

      { url: post['mastodon_url'], date: post['date'] }
    rescue JSON::ParserError
      nil
    end
  end

  # A status's replies_count only counts direct replies, while the whole
  # thread is shown under the article -- so comments are taken from
  # /context, to keep the listing and post-page numbers consistent.
  def fetch_one(parsed)
    base = "https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}"
    status = JSON.parse(FeedHttp.get(base))
    context = JSON.parse(FeedHttp.get("#{base}/context"))
    {
      'favourites' => status['favourites_count'].to_i,
      'reblogs' => status['reblogs_count'].to_i,
      'comments' => (context['descendants'] || []).count { |s| !s['sensitive'] }
    }
  rescue StandardError => e
    warn "Mastodon stats failed (#{parsed[:id]}): #{e.message}"
    nil
  end

  # recent_only: true skips posts older than RECENT_WINDOW_DAYS -- the
  # caller (refresh_sidebar.rb) merges the result into stats.json's previous
  # content, so a skipped old post simply keeps its last known numbers
  # instead of disappearing. Failed posts are likewise just skipped; one
  # failed request doesn't wipe out the existing numbers.
  def fetch_all(recent_only: false)
    entries = toot_entries
    if recent_only
      cutoff = Time.now - (RECENT_WINDOW_DAYS * 24 * 60 * 60)
      entries = entries.select { |e| Time.parse(e[:date]) >= cutoff rescue true }
    end

    entries.each_with_object({}) do |entry, acc|
      parsed = parse_toot_url(entry[:url])
      next unless parsed

      stats = fetch_one(parsed)
      acc[entry[:url]] = stats if stats
    end
  end
end
