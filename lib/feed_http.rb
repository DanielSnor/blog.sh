# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative 'site_config'

# lib/feed_http.rb -- one GET implementation shared by every sidebar fetcher.
#
# Adds three things that matter on top of plain Net::HTTP.get: timeouts
# (without them a stuck feed could hang the build indefinitely), a
# User-Agent (api.github.com returns 403 without one), and redirect
# following.
module FeedHttp
  USER_AGENT = "blog-sh/1.0 (+#{SiteConfig.get('site', 'base_url', default: 'https://github.com/')})"
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 15
  MAX_REDIRECTS = 3

  module_function

  # Returns the response body as a String; raises RuntimeError on a non-2xx
  # response so the calling fetcher can catch it and return an empty list.
  def get(url, redirects_left = MAX_REDIRECTS)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept'] = 'application/json, application/atom+xml, */*'

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                              open_timeout: OPEN_TIMEOUT,
                                              read_timeout: READ_TIMEOUT) { |http| http.request(req) }

    case res
    when Net::HTTPSuccess then res.body
    when Net::HTTPRedirection
      raise "too many redirects (#{url})" if redirects_left.zero?

      get(URI.join(url, res['location']).to_s, redirects_left - 1)
    else
      raise "HTTP #{res.code} (#{url})"
    end
  end
end
