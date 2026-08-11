# frozen_string_literal: true

require 'json'
require 'cgi'
require_relative 'embed'
require_relative 'feed_http'

# lib/embed_lookup.rb -- the two platforms whose player address cannot be
# derived from their page address, asked once, when the post is written.
#
# This is the only place in the authoring path that touches the network,
# which is why it is a separate file rather than a branch in lib/embed.rb:
# everything there is a pure string transform that works on a train with no
# signal, and this deliberately isn't.
#
# Why each of them needs asking, both established against the live services:
#
# * Funkwhale -- the obvious transform (rewrite the library URL into the
#   embed path) produces a player that LOOKS right and stays a permanently
#   black rectangle on a current, popular instance, because the page it
#   builds points at a JS module path that moved. Its oEmbed endpoint, on
#   the other hand, answers correctly on the same instance.
# * Bandcamp -- the page address contains no id at all, only a slug, and
#   the official embed needs the numeric id. There is no oEmbed endpoint to
#   ask either (both candidate URLs answer 404), so the id has to come from
#   the page's own twitter:player metadata.
#
# What gets stored is an address, never the HTML either service returned.
# The rule the rest of the engine follows does not stop applying because a
# lookup was involved: a post carries no third party's markup, and the
# iframe is built by the renderer out of a URL this file has validated.
module EmbedLookup
  OEMBED_PATH = '/api/v2/oembed/'
  # Enough for a metadata tag near the top of the document; a Bandcamp page
  # is megabytes of player state, and none of it is needed.
  MAX_PAGE_BYTES = 200_000
  TWITTER_PLAYER_RE = /<meta[^>]+(?:property|name)=["']twitter:player["'][^>]*>/i
  CONTENT_ATTR_RE = /content=["']([^"']+)["']/i
  IFRAME_SRC_RE = /<iframe[^>]+src=["']([^"']+)["']/i

  module_function

  # Fills in `embed_src` for one block, or returns nil and leaves the block
  # alone. Never raises: a lookup that fails is a post without a player,
  # not a save that dies -- the caller says so out loud and writes the post.
  def resolve(block)
    src = case block['provider'].to_s
          when 'funkwhale' then funkwhale_src(block)
          when 'bandcamp' then bandcamp_src(block)
          end
    return nil unless src

    block['embed_src'] = src
    # Re-validated through the same door the renderer uses, so a service
    # answering with someone else's address changes nothing.
    Embed.src(block) ? src : (block.delete('embed_src') && nil)
  rescue StandardError
    nil
  end

  def funkwhale_src(block)
    origin = block['embed_origin'].to_s
    page = block['url'].to_s
    return nil if origin.empty? || page.empty?

    body = fetch("#{origin}#{OEMBED_PATH}?url=#{CGI.escape(page)}&format=json")
    return nil unless body

    html = JSON.parse(body)['html'].to_s
    m = IFRAME_SRC_RE.match(html)
    m && CGI.unescapeHTML(m[1])
  rescue JSON::ParserError
    nil
  end

  def bandcamp_src(block)
    body = fetch(block['url'].to_s)
    return nil unless body

    tag = TWITTER_PLAYER_RE.match(body)
    return nil unless tag

    content = CONTENT_ATTR_RE.match(tag[0])
    content && CGI.unescapeHTML(content[1])
  end

  def fetch(url)
    body = FeedHttp.get(url)
    body && body[0, MAX_PAGE_BYTES]
  rescue StandardError
    nil # offline, a timeout, a 404 -- all the same answer: no player yet
  end
end
