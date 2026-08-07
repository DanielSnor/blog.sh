# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require_relative 'site_config'

# Posts the announcement to Bluesky via the AT Protocol, so each post can
# carry a "reply here to comment" thread -- the Bluesky counterpart of
# lib/mastodon_poster.rb, and like it entirely optional: without a
# `bluesky:` section in config/site.yml (or without BLUESKY_APP_PASSWORD
# in the environment), publish/delete just return nil/false.
#
# Auth is handle + app password (Settings -> App Passwords on Bluesky --
# never the account password), exchanged for a session per call; a blog
# publishes far too rarely for session caching to matter. Links and
# hashtags in the text are made clickable via facets, whose offsets are
# UTF-8 *byte* positions -- that's the AT Protocol's contract, and the
# reason for all the .bytesize arithmetic below.
module BlueskyPoster
  HANDLE = SiteConfig.get('bluesky', 'handle')
  PDS = (SiteConfig.get('bluesky', 'pds') || 'https://bsky.social').chomp('/')

  # Trailing punctuation is not part of the address, the way Bluesky's own
  # detectFacets treats it: a URL that ends a sentence used to carry the
  # full stop (or the closing bracket of a parenthesised aside) into the
  # facet, and the link in the announcement was dead. A closing bracket is
  # kept when the URL opened one, so /Page(ID-1) still works.
  URL_RE = %r{https?://[^\s]*[^\s.,;:!?'")\]]}
  # [[:word:]] is Unicode-aware, so Czech (and any other) diacritics in a
  # tag survive into the facet.
  TAG_RE = /(?:\A|(?<=\s))#([[:word:]]+)/

  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20

  def self.configured?
    !HANDLE.nil?
  end

  # Returns { url:, uri: } -- the human bsky.app link and the at:// URI
  # the thread API needs -- or nil on any failure. Never raises: a failed
  # announcement must not block publishing the post itself.
  def self.publish(text)
    return nil unless configured?

    password = ENV['BLUESKY_APP_PASSWORD']
    if password.to_s.empty?
      warn 'BLUESKY_APP_PASSWORD is not set, the Bluesky announcement was not posted.'
      return nil
    end

    session = xrpc_post('com.atproto.server.createSession',
                        { identifier: HANDLE, password: password })

    record = {
      '$type' => 'app.bsky.feed.post',
      'text' => text,
      'createdAt' => Time.now.utc.iso8601(3),
      'langs' => [SiteConfig.get('site', 'lang', default: 'en')]
    }
    facets = build_facets(text)
    record['facets'] = facets unless facets.empty?

    result = xrpc_post('com.atproto.repo.createRecord',
                       { repo: session['did'], collection: 'app.bsky.feed.post', record: record },
                       jwt: session['accessJwt'])

    rkey = result['uri'].to_s.split('/').last
    { url: "https://bsky.app/profile/#{HANDLE}/post/#{rkey}", uri: result['uri'] }
  rescue StandardError => e
    warn "Posting to Bluesky failed: #{e.message}"
    nil
  end

  # Deletes the announcement by its at:// URI (at://did/collection/rkey --
  # everything deleteRecord needs is right in it).
  def self.delete(at_uri)
    return false unless configured?

    password = ENV['BLUESKY_APP_PASSWORD']
    if password.to_s.empty?
      warn 'BLUESKY_APP_PASSWORD is not set, the Bluesky announcement was not deleted.'
      return false
    end

    m = at_uri.to_s.match(%r{\Aat://([^/]+)/([^/]+)/(.+)\z})
    unless m
      warn "Can't parse the at:// URI #{at_uri}, the announcement was not deleted."
      return false
    end

    session = xrpc_post('com.atproto.server.createSession',
                        { identifier: HANDLE, password: password })
    xrpc_post('com.atproto.repo.deleteRecord',
              { repo: m[1], collection: m[2], rkey: m[3] },
              jwt: session['accessJwt'])
    true
  rescue StandardError => e
    warn "Deleting the Bluesky announcement failed: #{e.message}"
    false
  end

  # Link facets for bare URLs, tag facets for #hashtags -- byte-offset
  # ranges per the AT Protocol.
  def self.build_facets(text)
    facets = []
    text.scan(URL_RE) do
      match = Regexp.last_match
      byte_start = text[0...match.begin(0)].bytesize
      facets << {
        'index' => { 'byteStart' => byte_start, 'byteEnd' => byte_start + match[0].bytesize },
        'features' => [{ '$type' => 'app.bsky.richtext.facet#link', 'uri' => match[0] }]
      }
    end
    text.scan(TAG_RE) do
      match = Regexp.last_match
      byte_start = text[0...match.begin(0)].bytesize
      facets << {
        'index' => { 'byteStart' => byte_start, 'byteEnd' => byte_start + match[0].bytesize },
        'features' => [{ '$type' => 'app.bsky.richtext.facet#tag', 'tag' => match[1] }]
      }
    end
    facets
  end

  def self.xrpc_post(endpoint, body, jwt: nil)
    uri = URI("#{PDS}/xrpc/#{endpoint}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Post.new(uri.path)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{jwt}" if jwt
    req.body = JSON.generate(body)

    resp = http.request(req)
    unless resp.is_a?(Net::HTTPSuccess)
      data = JSON.parse(resp.body) rescue nil
      raise "HTTP #{resp.code} from #{endpoint}: #{data&.dig('message') || data&.dig('error') || resp.body.to_s[0, 200]}"
    end

    JSON.parse(resp.body)
  end
end
