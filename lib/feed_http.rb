# frozen_string_literal: true

require 'net/http'
require 'timeout'
require 'uri'
require_relative 'site_config'
require_relative 'version'

# lib/feed_http.rb -- one GET implementation shared by every sidebar fetcher.
#
# Adds three things that matter on top of plain Net::HTTP.get: timeouts
# (without them a stuck feed could hang the build indefinitely), a
# User-Agent (api.github.com returns 403 without one), and redirect
# following.
module FeedHttp
  USER_AGENT = "#{BlogSh.user_agent} (+#{SiteConfig.get('site', 'base_url', default: 'https://github.com/')})"
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 15
  # The per-read timeout only bounds the gap BETWEEN chunks: a host that
  # dribbles one byte every few seconds never trips it, and there is no
  # limit on how long a body may take in total -- so a single slow feed
  # could hold the build, and the every-30-minutes sidebar cron, forever.
  # 30 s is generous for a JSON or Atom document (the widgets fetch a page
  # of statuses, not a download) and short enough that a stuck host costs
  # one skipped refresh instead of a stuck process. The deadline covers the
  # whole call including redirects, which is why it is threaded through.
  TOTAL_TIMEOUT = 30
  MAX_REDIRECTS = 3

  module_function

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Returns the response body as a String; raises RuntimeError on a non-2xx
  # response so the calling fetcher can catch it and return an empty list.
  def get(url, redirects_left = MAX_REDIRECTS, deadline = now + TOTAL_TIMEOUT)
    remaining = deadline - now
    raise "timed out after #{TOTAL_TIMEOUT}s (#{url})" if remaining <= 0

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept'] = 'application/json, application/atom+xml, */*'

    res = Timeout.timeout(remaining, nil, "timed out after #{TOTAL_TIMEOUT}s (#{url})") do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: [OPEN_TIMEOUT, remaining].min,
                                          read_timeout: [READ_TIMEOUT, remaining].min) { |http| http.request(req) }
    end

    case res
    when Net::HTTPSuccess then res.body
    when Net::HTTPRedirection
      raise "too many redirects (#{url})" if redirects_left.zero?

      get(URI.join(url, res['location']).to_s, redirects_left - 1, deadline)
    else
      raise "HTTP #{res.code} (#{url})"
    end
  end
end
