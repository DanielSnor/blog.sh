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

  # What a fetch says it accepts. Most callers read JSON APIs, so JSON
  # first stays the default -- but a caller after a FEED must not say
  # that: servers that content-negotiate on Accept (GoToSocial for one)
  # answer `application/json` with a JSON Feed document, and the XML
  # parsers behind rss_fetcher, pixelfed_fetcher and the feed importer
  # then report the whole feed as malformed. Those callers pass
  # XML_ACCEPT instead, and the same URL yields RSS/Atom again.
  DEFAULT_ACCEPT = 'application/json, application/atom+xml, */*'
  XML_ACCEPT = 'application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.1'

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
  #
  # bearer:/headers: are for the one caller that has to identify itself.
  # Comment moderation asks each network "did *I* favourite this reply?",
  # and both answer only an authenticated request -- Mastodon with a
  # token, Bluesky with a session JWT plus the header that routes an
  # app.bsky.* call through the PDS to the AppView (see lib/post_stats.rb).
  # Both are dropped when a redirect leaves the host they were meant for:
  # a Location is chosen by the remote, and following one with the
  # credentials still attached would hand them to whatever host it names.
  def get(url, redirects_left = MAX_REDIRECTS, deadline = now + TOTAL_TIMEOUT, max_body: MAX_BODY,
          accept: DEFAULT_ACCEPT, bearer: nil, headers: {})
    remaining = deadline - now
    raise "timed out after #{TOTAL_TIMEOUT}s (#{url})" if remaining <= 0

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept'] = accept
    req['Authorization'] = "Bearer #{bearer}" unless bearer.to_s.empty?
    headers.each { |name, value| req[name.to_s] = value.to_s }

    body = nil
    res = Timeout.timeout(remaining, nil, "timed out after #{TOTAL_TIMEOUT}s (#{url})") do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: [OPEN_TIMEOUT, remaining].min,
                                          read_timeout: [READ_TIMEOUT, remaining].min) do |http|
        http.request(req) do |response|
          # The ceiling has to bind while the bytes arrive: letting
          # Net::HTTP buffer the whole response and measuring afterwards
          # meant the remote had already made this process allocate the
          # entire oversized body before the check ever ran. Streaming
          # chunks caps the damage at the ceiling plus one read.
          if response.is_a?(Net::HTTPSuccess)
            body = +''
            response.read_body do |chunk|
              body << chunk
              raise "response too large (#{body.bytesize} bytes, #{url})" if max_body && body.bytesize > max_body
            end
          end
        end
      end
    end

    case res
    when Net::HTTPSuccess
      body
    when Net::HTTPRedirection
      raise "too many redirects (#{url})" if redirects_left.zero?

      # http:// and https:// only. Net::HTTP will not follow a file:// or
      # ftp:// Location itself, but URI.join accepts one, and the address
      # a redirect names is chosen by the remote host, not by this site.
      target = URI.join(url, res['location'])
      raise "refusing a #{target.scheme.inspect} redirect (#{url})" unless %w[http https].include?(target.scheme)

      same_host = target.host == uri.host && target.scheme == uri.scheme && target.port == uri.port
      # accept survives every redirect: it is a media-type preference,
      # not a credential, and a feed moved to a new host still has to be
      # asked for XML or GoToSocial-style negotiation answers with JSON.
      get(target.to_s, redirects_left - 1, deadline, max_body: max_body, accept: accept,
                       bearer: same_host ? bearer : nil, headers: same_host ? headers : {})
    else
      raise "HTTP #{res.code} (#{url})"
    end
  end
end
