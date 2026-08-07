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
  # A sidebar widget is a handful of items. Without a ceiling, a remote
  # that answers with an endless (or merely enormous) body turned ~200 KB
  # on the wire into a String of any size the sender liked -- and the
  # failure path then echoed the whole thing through `warn` into the cron
  # mail. Cheap insurance on a path that talks to hosts nobody here
  # controls.
  MAX_BODY = 8 * 1024 * 1024

  module_function

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Returns the response body as a String; raises RuntimeError on a non-2xx
  # response so the calling fetcher can catch it and return an empty list.
  # max_body: nil lifts the ceiling for callers that legitimately fetch a
  # whole archive -- lib/import/feed.rb pulls entire WXR exports through
  # this same method, and a cap sized for a sidebar widget aborted those
  # imports at the door.
  def get(url, redirects_left = MAX_REDIRECTS, deadline = now + TOTAL_TIMEOUT, max_body: MAX_BODY)
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
    when Net::HTTPSuccess
      body = res.body.to_s
      raise "response too large (#{body.bytesize} bytes, #{url})" if max_body && body.bytesize > max_body

      body
    when Net::HTTPRedirection
      raise "too many redirects (#{url})" if redirects_left.zero?

      # http:// and https:// only. Net::HTTP will not follow a file:// or
      # ftp:// Location itself, but URI.join accepts one, and the address
      # a redirect names is chosen by the remote host, not by this site.
      target = URI.join(url, res['location'])
      raise "refusing a #{target.scheme.inspect} redirect (#{url})" unless %w[http https].include?(target.scheme)

      get(target.to_s, redirects_left - 1, deadline, max_body: max_body)
    else
      raise "HTTP #{res.code} (#{url})"
    end
  end
end
