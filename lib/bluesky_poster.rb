# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
require_relative 'site_config'
require_relative 'i18n'

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
  # facet, and the link in the announcement was dead.
  #
  # Two alternatives, not one, and the balanced form comes FIRST: an
  # address that opens a bracket keeps the one that closes it
  # (".../Ruby_(programming_language)" is a real Wikipedia URL, and
  # trimming its bracket produced a dead link -- which the first attempt
  # at this did, while the comment claimed otherwise).
  # The excluded tail includes "…", which is not decoration here: the
  # engine appends one itself when it shortens a preview, so an address
  # that ended the preview came out of this with the ellipsis inside the
  # link -- a facet pointing at an address that does not exist. Every
  # other closing mark was already excluded; this one arrives from our
  # own hand rather than the author's, which is why it was missed.
  URL_RE = %r{https?://\S*?\([^\s()]*\)|https?://\S*[^\s.,;:!?'")\]…]}
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
      warn I18n.t('poster.no_bluesky_password_post')
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

    # The shape is checked, not assumed. A PDS that answers 200 with
    # something else -- a proxy in front of it, a version that changed its
    # mind, an error body with a 200 -- used to be written into the post as
    # a perfectly good announcement whose address is at:///app.bsky.feed.post/
    # and leads nowhere, for ever: the post then carries an announcement it
    # does not have, so nothing offers to send one again.
    uri = result['uri'].to_s
    rkey = uri.split('/').last.to_s
    unless uri.start_with?('at://') && uri.include?('/app.bsky.feed.post/') && !rkey.empty?
      warn "Posting to Bluesky failed: the server answered without a usable record address (#{result.inspect[0, 120]})"
      return nil
    end

    { url: "https://bsky.app/profile/#{HANDLE}/post/#{rkey}", uri: uri }
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
      warn I18n.t('poster.no_bluesky_password_delete')
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

  # Looks for an announcement of this post that is already on the account,
  # and answers it in the same shape publish does -- or nil.
  #
  # This is what stands between the author and two announcements of one
  # post. The record can reach the PDS and be accepted while the reply
  # never reaches us (a connection dropped at exactly the wrong moment),
  # and the engine then stores nothing: as far as the post's file is
  # concerned, nothing was announced. `./blog.sh bluesky` exists for that
  # very situation -- and read the missing address as "never sent", so it
  # sent a second one. Asking the account first turns the guess into a
  # question with an answer.
  def self.find_announcement(post_url)
    return nil unless configured?

    password = ENV['BLUESKY_APP_PASSWORD']
    return nil if password.to_s.empty? || post_url.to_s.empty?

    session = xrpc_post('com.atproto.server.createSession',
                        { identifier: HANDLE, password: password })
    listed = xrpc_get('com.atproto.repo.listRecords',
                      { repo: session['did'], collection: 'app.bsky.feed.post', limit: 100 },
                      jwt: session['accessJwt'])

    hit = Array(listed['records']).find { |r| r.dig('value', 'text').to_s.include?(post_url) }
    return nil unless hit

    rkey = hit['uri'].to_s.split('/').last
    { url: "https://bsky.app/profile/#{HANDLE}/post/#{rkey}", uri: hit['uri'] }
  rescue StandardError => e
    # Never fatal: not finding out is the state we were already in.
    warn "Could not check Bluesky for an existing announcement: #{e.message}"
    nil
  end

  def self.xrpc_get(endpoint, params, jwt: nil)
    uri = URI("#{PDS}/xrpc/#{endpoint}")
    uri.query = URI.encode_www_form(params)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Get.new(uri.request_uri)
    req['Authorization'] = "Bearer #{jwt}" if jwt
    resp = http.request(req)
    raise "HTTP #{resp.code} from #{endpoint}" unless resp.is_a?(Net::HTTPSuccess)

    JSON.parse(resp.body)
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
