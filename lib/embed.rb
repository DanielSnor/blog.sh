# frozen_string_literal: true

require 'cgi'
require 'uri'

# lib/embed.rb -- the platforms whose watch/listen address can be turned
# into a player by looking at it, with no network call anywhere.
#
# One module, used from both ends of the engine: the CLI's parser stores
# what it recognised (provider + the identifying part), and the build turns
# that back into an <iframe> src. Keeping the knowledge in one place is what
# stops the two from drifting -- a stored post and a rendered page have to
# agree about what a URL meant.
#
# The engine never stores foreign HTML for these. The same rule YouTube has
# followed since the beginning: a provider's embed code can carry whatever
# the provider likes, so the iframe is built here out of a validated id.
# That also means a platform changing its embed path is one edit for every
# post already written, instead of a re-import.
#
# Every pattern below was checked against the live services rather than
# their documentation, which is where the traps came from: an unlisted
# Vimeo link needs its hash or the player answers 403, a Spotify URL copied
# from a browser carries an `intl-xx` segment that 404s the embed path,
# SoundCloud has no numeric id to extract at all, and Mixcloud's widget
# redirects to a second hostname that the page's CSP has to allow too.
module Embed
  # A single video/audio track's id is all that goes into the data. What
  # the id means per provider is written into each pattern below.
  VIMEO_RE = %r{\Ahttps?://(?:www\.)?vimeo\.com/(\d+)(?:/([0-9a-zA-Z]+))?}
  # The hash comes as ?h= on this form, and it is the same second capture
  # the /vimeo.com/ pattern takes from the path -- both feed one m[1]/m[2]
  # extraction below. Without it the player answers 403 for an unlisted
  # video, which is a broken embed rather than a degraded one.
  VIMEO_PLAYER_RE = %r{\Ahttps?://player\.vimeo\.com/video/(\d+)(?:[^\s]*[?&]h=([0-9a-zA-Z]+))?}
  # intl-cs, intl-de ... is what a browser's address bar hands over today,
  # and it is exactly what the /embed/ path does not accept.
  SPOTIFY_RE = %r{\Ahttps?://open\.spotify\.com/(?:intl-[a-z-]+/)?(track|album|playlist|episode|show|artist)/([A-Za-z0-9]+)}
  SOUNDCLOUD_RE = %r{\Ahttps?://(?:www\.|m\.)?soundcloud\.com/[\w-]+/[\w%-]+}
  MIXCLOUD_RE = %r{\Ahttps?://(?:www\.)?mixcloud\.com/([\w-]+/[\w%-]+)}
  ARCHIVE_RE = %r{\Ahttps?://archive\.org/details/([\w.@%-]+)}
  # PeerTube is federated, so there is no domain to match on: the shape of
  # the path is the signal. Both forms the software itself serves are
  # accepted, and its own normalisation treats the short id and the full
  # UUID identically for watch and embed alike.
  #
  # The id has to have PeerTube's exact shape, not merely be a word: `/w/`
  # is a short path any site might use, and turning someone's ordinary link
  # into an iframe pointing at a page that isn't a player is worse than
  # leaving it a link. So: a full UUID, or the short id PeerTube derives
  # from one, which is base64url of sixteen bytes and therefore always
  # exactly 22 characters.
  #
  # A 22-character slug on some other site's /w/ page would still be taken
  # for one. That is the residual cost of a federated platform having no
  # domain to check, and it fails visibly (an empty player, one edit away
  # from being a plain link) rather than quietly.
  PEERTUBE_ID_RE = /\A(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9_-]{22})\z/
  PEERTUBE_PATH_RE = %r{\A/(?:w|videos/watch)/([^/]+)/?\z}

  # Funkwhale is federated like PeerTube, so again the path is the signal.
  # Unlike PeerTube, its address cannot be turned into a player by string
  # surgery -- see lib/embed_lookup.rb for why that was tried first and
  # abandoned -- so these two are resolved once, when the post is written.
  FUNKWHALE_PATH_RE = %r{\A/library/(?:tracks|albums|artists|playlists)/(\d+)/?\z}
  BANDCAMP_RE = %r{\Ahttps?://([a-z0-9-]+\.bandcamp\.com)/(?:album|track)/[\w-]+}i

  VIDEO_PROVIDERS = %w[vimeo peertube archive_org].freeze
  AUDIO_PROVIDERS = %w[spotify soundcloud mixcloud funkwhale bandcamp].freeze

  # The two whose player address is only knowable by asking. Everything
  # else in this file is a pure string transform.
  LOOKUP_PROVIDERS = %w[funkwhale bandcamp].freeze

  # Height in CSS pixels for the audio players, which are a fixed-height
  # strip rather than a 16:9 picture -- Spotify's compact player, and what
  # SoundCloud's and Mixcloud's widgets are drawn for.
  # Bandcamp is the tall one: what its page offers as a player is the card
  # player, which is drawn with the cover art above the controls.
  AUDIO_HEIGHTS = {
    'spotify' => 152, 'soundcloud' => 166, 'mixcloud' => 120,
    'funkwhale' => 150, 'bandcamp' => 400
  }.freeze

  module_function

  # The block fields for a URL this module recognises, or nil. Only the
  # provider and the identifying parts -- the caller owns type and caption.
  def detect(url)
    text = url.to_s.strip
    if (m = VIMEO_RE.match(text)) || (m = VIMEO_PLAYER_RE.match(text))
      # The second capture is the unlisted-video hash. Without it the
      # player answers 403 for those, which is a broken embed, not a
      # degraded one -- verified against a real unlisted video.
      { 'provider' => 'vimeo', 'embed_id' => m[1], 'embed_hash' => m[2] }.compact
    elsif (m = SPOTIFY_RE.match(text))
      { 'provider' => 'spotify', 'embed_kind' => m[1].downcase, 'embed_id' => m[2] }
    elsif SOUNDCLOUD_RE.match?(text)
      # No id to extract: the widget takes the whole watch URL, which is
      # also how a private track's secret_token reaches the player.
      { 'provider' => 'soundcloud' }
    elsif (m = MIXCLOUD_RE.match(text))
      { 'provider' => 'mixcloud', 'embed_id' => m[1] }
    elsif (m = ARCHIVE_RE.match(text))
      { 'provider' => 'archive_org', 'embed_id' => m[1] }
    elsif BANDCAMP_RE.match?(text)
      # No id anywhere in the address: Bandcamp's URL is a slug, and its
      # official embed needs a numeric id that only the page itself knows.
      { 'provider' => 'bandcamp' }
    else
      peertube(text) || funkwhale(text)
    end
  end

  # Same host validation as PeerTube -- a federated instance's origin ends
  # up in the page's CSP, so it is parsed rather than pattern-matched.
  def funkwhale(text)
    uri = safe_uri(text)
    return nil unless uri && FUNKWHALE_PATH_RE.match?(uri.path.to_s)

    { 'provider' => 'funkwhale', 'embed_origin' => origin_of(uri) }
  end

  # PeerTube's host ends up in the page's CSP, so it is parsed rather than
  # pattern-matched out of the raw string: `https://good.example@evil.test/w/x`
  # reads as the good host to a careless regex and as the evil one to the
  # browser. URI.parse plus an explicit hostname shape is the version that
  # cannot disagree with what the browser will do.
  def peertube(text)
    uri = safe_uri(text)
    return nil unless uri

    m = PEERTUBE_PATH_RE.match(uri.path.to_s)
    return nil unless m && PEERTUBE_ID_RE.match?(m[1])

    { 'provider' => 'peertube', 'embed_id' => m[1], 'embed_origin' => origin_of(uri) }
  end

  # A URL that can safely have its host used as an origin: http(s), no
  # userinfo, and a hostname that looks like one.
  def safe_uri(text)
    uri = begin
      URI.parse(text.to_s)
    rescue URI::InvalidURIError
      return nil
    end
    return nil unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)
    return nil if uri.userinfo
    return nil unless uri.host.to_s.match?(/\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\z/i)

    uri
  end

  def origin_of(uri)
    port = uri.port && ![80, 443].include?(uri.port) ? ":#{uri.port}" : ''
    "https://#{uri.host}#{port}"
  end

  def video?(block)
    VIDEO_PROVIDERS.include?(block['provider'].to_s)
  end

  def audio?(block)
    AUDIO_PROVIDERS.include?(block['provider'].to_s)
  end

  def kind(fields)
    VIDEO_PROVIDERS.include?(fields['provider'].to_s) ? 'video' : 'audio'
  end

  # The iframe src for a stored block, or nil when the block is not one of
  # ours (or lost the fields it needs -- a hand-edited JSON, an import).
  def src(block)
    id = block['embed_id'].to_s
    case block['provider'].to_s
    when 'vimeo'
      return nil if id.empty?

      hash = block['embed_hash'].to_s
      "https://player.vimeo.com/video/#{id}#{hash.empty? ? '' : "?h=#{CGI.escape(hash)}"}"
    when 'spotify'
      kind = block['embed_kind'].to_s
      return nil if id.empty? || kind.empty?

      "https://open.spotify.com/embed/#{kind}/#{id}"
    when 'soundcloud'
      url = block['url'].to_s
      return nil unless SOUNDCLOUD_RE.match?(url)

      "https://w.soundcloud.com/player/?url=#{CGI.escape(url)}"
    when 'mixcloud'
      return nil if id.empty?

      "https://www.mixcloud.com/widget/iframe/?feed=#{CGI.escape("/#{id}/")}"
    when 'archive_org'
      id.empty? ? nil : "https://archive.org/embed/#{id}"
    when 'peertube'
      origin = block['embed_origin'].to_s
      return nil if id.empty? || !origin.match?(%r{\Ahttps://[a-z0-9.-]+(?::\d+)?\z}i)

      "#{origin}/videos/embed/#{id}"
    when 'funkwhale', 'bandcamp'
      # Looked up once when the post was written (lib/embed_lookup.rb) and
      # stored as a plain address -- so the build is still a pure function
      # of the post, and a post written offline simply has no player yet
      # rather than a half-fetched one.
      resolved_src(block)
    end
  end

  # The stored player address, re-checked at render time against where it
  # is allowed to point: whatever the lookup returned, only an https URL on
  # the expected host may end up in an iframe.
  def resolved_src(block)
    src = block['embed_src'].to_s
    uri = safe_uri(src)
    return nil unless uri && uri.is_a?(URI::HTTPS)

    case block['provider'].to_s
    when 'funkwhale' then origin_of(uri) == block['embed_origin'].to_s ? src : nil
    when 'bandcamp' then uri.host.to_s.match?(/\A(?:[a-z0-9-]+\.)?bandcamp\.com\z/i) ? src : nil
    end
  end

  # What the page's frame-src has to allow for this block. Mixcloud needs
  # two: its widget URL answers with a redirect to player-widget.mixcloud.com,
  # and a CSP naming only the address in the src blocks the player the
  # moment it follows that redirect.
  # An imported embed's HTML with the parts that execute taken out --
  # <script>, on* handlers, javascript: addresses.
  #
  # NOT a sanitiser, and not pretending to be one: the site's CSP is what
  # actually stops a script (`script-src 'self' <hash> <analytics>`, no
  # unsafe-inline, and frame-src comes from the provider table above, not
  # from this HTML). Measured before writing this: a crafted embed_html
  # cannot run script, load one, frame a foreign site or post a form on a
  # blog.sh page today.
  #
  # It is worth doing anyway for two reasons. The FEED has no CSP -- the
  # same HTML goes into every item's description, and readers differ. And
  # the page's safety should not rest on one meta tag that a themed
  # template could soften.
  #
  # The cost is nothing that works: an embed built out of a script
  # (Instagram, Twitter/X -- blockquote plus widgets.js) is already inert
  # under that CSP, so what the reader sees does not change. Iframe embeds
  # -- YouTube, Vimeo, Spotify -- never come through here; they are built
  # from the provider and the id.
  #
  # At RENDER, never on the way in: the archive holds what it was given,
  # and the page shows only what it will honour.
  SCRIPT_RE = %r{<script\b[^>]*>.*?</script\s*>|</?script\b[^>]*>}mi
  # The separator before an attribute name is whitespace OR a solidus:
  # `<svg/onload="steal()">` is the same tag to a browser as
  # `<svg onload="steal()">`, and a rule that knew only whitespace let
  # exactly that spelling through -- untouched, onto every page drawing
  # the icon and into the feed, while `doctor` called it fine.
  #
  # A solidus is also an ordinary character in a path, though, so this is
  # applied INSIDE TAGS ONLY. Let loose over the whole document it turns
  # `<a href="/only=1">x</a>` into `<a href=">x</a>`: the cure eating the
  # content it was protecting.
  # A tag, with its quoted values skipped over so that a ">" inside an
  # attribute does not end it early.
  TAG_RE = /<[a-z][a-z0-9:-]*(?:[^>"']|"[^"]*"|'[^']*')*>/i
  # One attribute of a tag: the separator that introduces it, its name,
  # and its value taken WHOLE when it is quoted. Taking the value whole is
  # the point -- a pattern hunting for handlers in the tag's text reads
  # `href="/only=1"` as a solidus, the name "only" and a value, and eats a
  # perfectly good link. An attribute is a thing; ask it its name.
  ATTR_RE = /([\s\/]+)([a-z_:][-a-z0-9_:.]*)(\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/i
  HANDLER_NAME_RE = /\Aon[a-z]+\z/i
  URL_NAME_RE = /\A(?:href|src|xlink:href)\z/i
  # An SVG animation element exists to change another element's attribute
  # while the page is open -- `<animate attributeName="href"
  # values="javascript:alert(1)">` is a script in another spelling, and
  # the URL it carries sits in an attribute no URL rule would think to
  # read. Nothing in an icon or an embed needs one.
  ANIMATE_RE = %r{</?(?:animate|animateTransform|animateMotion|set)\b[^>]*>}mi
  # A style block is not a script, and it acts on the page just the same.
  # The two Instagram embeds in this house's own archive carry
  #
  #   body > iframe { min-width: auto !important }
  #
  # -- a rule written for somebody else's page, reaching outside the
  # embed to every iframe under this one's <body>, with !important on it.
  # Nothing hostile; simply not this site's to decide. And unlike the
  # scripts above, this one is NOT already inert: the page's own policy is
  # `style-src 'self' 'unsafe-inline'`, which it has to be for a post's
  # colour formatting, so an imported rule applies in full. In the feed
  # there is no policy at all.
  #
  # <link> goes with it: a stylesheet by another spelling, plus the one
  # element in a body fragment that exists to fetch something.
  #
  # The cost is the same as it was for scripts -- nothing that works. An
  # embed's own styling is written for the site it came from, and what the
  # reader sees on a blog.sh page is the same blockquote either way.
  STYLE_RE = %r{<style\b[^>]*>.*?</style\s*>|</?style\b[^>]*>|<link\b[^>]*>}mi

  def without_scripts(html)
    html.to_s
        .gsub(SCRIPT_RE, '')
        .gsub(STYLE_RE, '')
        .gsub(ANIMATE_RE, '')
        .gsub(TAG_RE) { |tag| tag_without_scripts(tag) }
  end

  # Handlers and javascript: URLs, removed where attributes actually live.
  def tag_without_scripts(tag)
    tag.gsub(ATTR_RE) do |whole|
      lead = Regexp.last_match(1)
      name = Regexp.last_match(2)
      assignment = Regexp.last_match(3)
      if name.match?(HANDLER_NAME_RE) then ''
      elsif name.match?(URL_NAME_RE) && assignment && js_url?(assignment.sub(/\A\s*=\s*/, ''))
        "#{lead}#{name}=\"#\""
      else
        whole
      end
    end
  end

  # "javascript:" as a BROWSER reads it, rather than as a regex sees it:
  # entities decoded, and the whitespace and control characters HTML
  # tolerates inside a scheme taken out. `href="javascript&#58;bad()"` is
  # none of those things to a rule looking for a literal colon, and every
  # one of them to a reader.
  def js_url?(value)
    plain = value.to_s.sub(/\A["']/, '').sub(/["']\z/, '')
    plain = plain.gsub(/&#x0*([0-9a-f]{1,6});/i) { codepoint(Regexp.last_match(1).to_i(16)) }
                 .gsub(/&#0*(\d{1,7});/) { codepoint(Regexp.last_match(1).to_i) }
    plain.gsub(/[\s\u0000-\u001f\u007f]/, '').downcase.start_with?('javascript:')
  end

  # A number that is not a character stays the text it was: this asks
  # whether an address is a script, and must not raise over a malformed
  # entity while doing it.
  def codepoint(number)
    [number].pack('U')
  rescue StandardError
    ''
  end

  def frame_origins(block)
    case block['provider'].to_s
    when 'vimeo' then ['https://player.vimeo.com']
    when 'spotify' then ['https://open.spotify.com']
    when 'soundcloud' then ['https://w.soundcloud.com']
    when 'mixcloud' then ['https://www.mixcloud.com', 'https://player-widget.mixcloud.com']
    when 'archive_org' then ['https://archive.org']
    when 'peertube', 'funkwhale' then src(block) ? [block['embed_origin'].to_s] : []
    when 'bandcamp'
      # Every artist has their own subdomain, and the stored player address
      # keeps it. A CSP naming the bare bandcamp.com would block exactly
      # the iframe the page just rendered.
      resolved = src(block)
      uri = resolved && safe_uri(resolved)
      uri ? [origin_of(uri)] : []
    else []
    end
  end

  # A block that is waiting for its one network lookup. Everything else
  # answers this with false, which is what keeps the lookup out of the
  # build and out of every re-save.
  def needs_lookup?(block)
    LOOKUP_PROVIDERS.include?(block['provider'].to_s) && resolved_src(block).nil?
  end

  # Every origin a page carrying these blocks needs -- computed per page
  # rather than added to every site's CSP, so a blog that embeds nothing
  # keeps the narrow policy it has today. PeerTube is the reason this can't
  # be a constant: the host is a property of the post, not of the engine.
  def frame_origins_for(blocks)
    Array(blocks).flat_map { |block| frame_origins(block) }.uniq
  end
end
