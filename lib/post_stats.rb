# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative 'feed_http'

# lib/post_stats.rb -- favourite/boost/comment counts for announced
# posts, precomputed server-side into public/stats.json. Handles both
# networks: a post carries either mastodon_url or bluesky_uri (never
# both -- see SiteConfig.comment_network), and that stored value is also
# the stats.json key the client looks up.
#
# Originally fetched by the visitor's browser: a request to the network's
# API for every post in a listing. Harmless while only three posts were
# announced, but it grows with every new article -- and it's exactly the
# pattern already removed from the sidebar widgets (rate limits, leaking
# visitors' IPs to a third party, waiting on a foreign server's response).
#
# Fetched exclusively by cron via scripts/refresh_sidebar.rb, not the
# normal build: that's up to two requests per announced post, which would
# gradually choke the build.
#
# Engagement barely changes on old posts -- so `fetch_all(recent_only:
# true)` only live-refreshes posts younger than RECENT_WINDOW_DAYS,
# leaving older ones to an infrequent full refresh (refresh_sidebar.rb
# runs one roughly weekly). Without this, every cron run would make
# requests per *every* published post ever -- harmless today, hundreds
# of requests per run a few years from now.
module PostStats
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  RECENT_WINDOW_DAYS = 90
  BLUESKY_APPVIEW = 'https://public.api.bsky.app'

  module_function

  def parse_toot_url(url)
    m = url.to_s.match(%r{\Ahttps?://([^/]+)/@[^/]+/(\d+)}) ||
        url.to_s.match(%r{\Ahttps?://([^/]+)/users/[^/]+/statuses/(\d+)})
    m && { instance: m[1], id: m[2] }
  end

  def entries
    Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
      post = JSON.parse(File.read(file, encoding: 'utf-8'))
      if post['mastodon_url']
        { kind: :mastodon, key: post['mastodon_url'], date: post['date'] }
      elsif post['bluesky_uri']
        { kind: :bluesky, key: post['bluesky_uri'], date: post['date'] }
      end
    rescue JSON::ParserError
      nil
    end
  end

  # A status's replies_count only counts direct replies, while the whole
  # thread is shown under the article -- so comments are taken from
  # /context, to keep the listing and post-page numbers consistent.
  def fetch_mastodon(url)
    parsed = parse_toot_url(url)
    return nil unless parsed

    base = "https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}"
    status = JSON.parse(FeedHttp.get(base))
    context = JSON.parse(FeedHttp.get("#{base}/context"))
    {
      'favourites' => status['favourites_count'].to_i,
      'reblogs' => status['reblogs_count'].to_i,
      'comments' => (context['descendants'] || []).count { |s| !s['sensitive'] }
    }
  end

  # One request per post: getPostThread carries the counts and the whole
  # reply tree at once. The values keep the Mastodon-era key names
  # (favourites/reblogs) on purpose -- stats.json stays one shape and the
  # client renders it without caring which network it came from.
  def fetch_bluesky(uri)
    data = JSON.parse(FeedHttp.get(
                        "#{BLUESKY_APPVIEW}/xrpc/app.bsky.feed.getPostThread?depth=10&uri=#{URI.encode_www_form_component(uri)}"
                      ))
    thread = data['thread'] || {}
    post = thread['post'] || {}
    {
      'favourites' => post['likeCount'].to_i,
      'reblogs' => post['repostCount'].to_i,
      'comments' => count_bluesky_replies(thread['replies'])
    }
  end

  # Same filtering as the client (assets/js/comments.js): placeholders
  # without a post don't count, labeled (moderated) posts don't either.
  def count_bluesky_replies(replies)
    (replies || []).sum do |item|
      post = item.is_a?(Hash) ? item['post'] : nil
      next 0 unless post
      next 0 if (post['labels'] || []).any?

      1 + count_bluesky_replies(item['replies'])
    end
  end

  def fetch_one(entry)
    entry[:kind] == :mastodon ? fetch_mastodon(entry[:key]) : fetch_bluesky(entry[:key])
  rescue StandardError => e
    warn "Stats fetch failed (#{entry[:key]}): #{e.message}"
    nil
  end

  # recent_only: true skips posts older than RECENT_WINDOW_DAYS -- the
  # caller (refresh_sidebar.rb) merges the result into stats.json's
  # previous content, so a skipped old post simply keeps its last known
  # numbers instead of disappearing. Failed posts are likewise just
  # skipped; one failed request doesn't wipe out the existing numbers.
  def fetch_all(recent_only: false)
    list = entries
    if recent_only
      cutoff = Time.now - (RECENT_WINDOW_DAYS * 24 * 60 * 60)
      list = list.select { |e| Time.parse(e[:date]) >= cutoff rescue true }
    end

    list.each_with_object({}) do |entry, acc|
      stats = fetch_one(entry)
      acc[entry[:key]] = stats if stats
    end
  end
end
