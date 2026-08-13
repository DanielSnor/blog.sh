# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative 'feed_http'
require_relative 'site_config'

# lib/post_stats.rb -- favourite/boost/comment counts for announced
# posts, precomputed server-side into public/stats.json, and (when
# comment moderation is on) the approved comments themselves into
# public/comments.json. Handles both networks: a post carries either
# mastodon_url or bluesky_uri (never both -- see
# SiteConfig.comment_network), and that stored value is also the key the
# client looks up in either file.
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
#
# --- Moderation --------------------------------------------------------
#
# With `comments.approval: fav` the same requests do one more job: they
# ask the network which replies the author favourited, and only those are
# published. The check costs nothing extra on the wire -- both networks
# answer "did the authenticated account like this?" as a field on the
# very response this file already asks for, provided the request carries
# credentials the site already has:
#
#   Mastodon   /context descendants carry `favourited` -- but only for an
#              authenticated request, which is why the token is threaded
#              through (scope read:statuses, alongside write:statuses the
#              announcement already needs).
#   Bluesky    getPostThread carries post.viewer.like -- but only when
#              called against the PDS with a session, not against the
#              public AppView, which knows no viewer.
#
# Two rules beyond "was it favourited", both there to keep the result
# readable rather than merely filtered:
#
#   * the author's own replies are approved automatically. Nobody stars
#     their own posts, and without this the author's half of every
#     exchange would vanish and the page would look broken.
#   * a reply shows only if every reply between it and the announcement
#     shows too. Otherwise an approved answer to a rejected comment sits
#     there answering nothing.
#
# The approval step is its own ceiling on how big comments.json can get:
# every entry in it was hand-starred by one person.
module PostStats
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  RECENT_WINDOW_DAYS = 90
  BLUESKY_APPVIEW = 'https://public.api.bsky.app'

  module_function

  def approval
    SiteConfig.comments_approval
  end

  def parse_toot_url(url)
    m = url.to_s.match(%r{\Ahttps?://([^/]+)/@[^/]+/(\d+)}) ||
        url.to_s.match(%r{\Ahttps?://([^/]+)/users/[^/]+/statuses/(\d+)})
    m && { instance: m[1], id: m[2] }
  end

  def entries
    Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
      post = JSON.parse(File.read(file, encoding: 'utf-8'))
      raise JSON::ParserError, 'not a post object' unless post.is_a?(Hash)

      if post['mastodon_url']
        { kind: :mastodon, key: post['mastodon_url'], date: post['date'] }
      elsif post['bluesky_uri']
        { kind: :bluesky, key: post['bluesky_uri'], date: post['date'] }
      end
    rescue StandardError => e
      # Every failure this file can produce, not just an unparseable one --
      # the same guard the publish cron carries. A post file holding an
      # array raised TypeError and killed the sidebar cron on every tick,
      # AFTER the widgets had been written locally: the local build looked
      # current while the live site stayed frozen.
      warn "Skipping unreadable post file #{file}: #{e.class}: #{e.message.lines.first.to_s.strip[0, 80]}"
      nil
    end
  end

  # --- Mastodon ---------------------------------------------------------

  # A status's replies_count only counts direct replies, while the whole
  # thread is shown under the article -- so comments are taken from
  # /context, to keep the listing and post-page numbers consistent.
  #
  # Returns { 'stats' => {...}, 'comments' => [...] or nil }. comments is
  # nil with moderation off: the browser still reads the live thread
  # itself then, and writing a copy nothing renders would be waste.
  def fetch_mastodon(url)
    parsed = parse_toot_url(url)
    return nil unless parsed

    token = approval ? mastodon_token! : nil
    base = "https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}"
    status = JSON.parse(FeedHttp.get(base, bearer: token))
    context = JSON.parse(FeedHttp.get("#{base}/context", bearer: token))
    descendants = (context['descendants'] || []).reject { |s| s['sensitive'] }

    unless approval
      return {
        'stats' => {
          'favourites' => status['favourites_count'].to_i,
          'reblogs' => status['reblogs_count'].to_i,
          'comments' => descendants.size
        },
        'comments' => nil
      }
    end

    blind!(:mastodon) unless status.key?('favourited')

    shown = approved_mastodon(status, descendants)
    {
      'stats' => {
        'favourites' => status['favourites_count'].to_i,
        'reblogs' => status['reblogs_count'].to_i,
        'comments' => shown.size
      },
      'comments' => shown.map { |s| mastodon_comment(s) }
    }
  end

  # The failure this whole feature has to survive, and the one it was not
  # surviving. An answer that does not carry the field saying what the
  # authenticated account liked is not an answer meaning "nothing" -- it is
  # the network declining to say, because the request was not authenticated
  # or the token lacks read:statuses. Read as "nothing", it publishes an
  # empty thread for every post, and since an empty array is not nil the
  # merge in refresh_sidebar.rb writes it straight over what was published:
  # one tick, and every approved comment on the site is gone.
  #
  # The comment above mastodon_token! has always said so, and doctor
  # --online has always tested for it -- but only there, on the path a
  # person runs by hand, and never on the path cron takes. So it is checked
  # here, where the answer arrives, and raising is the point: fetch_one
  # turns it into a warning and the previous comments.json entry survives
  # untouched. A thread nobody answered is still fine; the field is on the
  # announcement itself, so this asks the one status that always exists.
  def blind!(kind)
    raise "comments.approval is on but the #{kind} answer did not say which posts are " \
          "favourited -- the request was not authenticated, or the token is missing " \
          '(Mastodon) read:statuses. Refusing rather than publishing an empty thread ' \
          'over the comments already approved.'
  end

  # `favourited` is absent, not false, on an unauthenticated response --
  # so a token that is missing or lacks read:statuses would read as "the
  # author approved nothing" and silently empty every thread on the site.
  # Refusing to answer at all is the honest failure: fetch_one turns it
  # into a warning and the previous comments.json entry survives.
  def mastodon_token!
    token = ENV['MASTODON_ACCESS_TOKEN'].to_s
    if token.empty?
      raise 'comments.approval is on but MASTODON_ACCESS_TOKEN is not set -- ' \
            'without it the API never says which replies you favourited.'
    end

    token
  end

  # Walks each reply up to the announcement, memoising as it goes: a reply
  # is shown when it was favourited (or is the author's own) AND its whole
  # chain of parents is shown. The memo doubles as a cycle guard -- ids
  # come from a remote and nothing here should trust the shape of the tree.
  def approved_mastodon(status, descendants)
    root_id = status['id']
    own_id = status.dig('account', 'id')
    by_id = descendants.each_with_object({}) { |s, acc| acc[s['id']] = s }
    memo = {}
    descendants.select { |s| mastodon_shown?(s, root_id, own_id, by_id, memo) }
  end

  def mastodon_shown?(status, root_id, own_id, by_id, memo)
    id = status['id']
    cached = memo[id]
    return cached unless cached.nil?

    memo[id] = false
    approved = status['favourited'] == true ||
               (!own_id.nil? && status.dig('account', 'id') == own_id)
    parent_id = status['in_reply_to_id']
    parent = by_id[parent_id]
    parent_shown = parent_id == root_id ||
                   (!parent.nil? && mastodon_shown?(parent, root_id, own_id, by_id, memo))
    memo[id] = approved && parent_shown
  end

  # `html` rather than `text`: Mastodon sanitises status content itself
  # and the client has always inserted it as HTML -- the alternative is
  # showing readers raw markup. Everything else here is the reply
  # author's to choose, i.e. anyone in the Fediverse, and the client
  # escapes all of it (assets/js/comments.js).
  def mastodon_comment(status)
    account = status['account'] || {}
    {
      'id' => status['id'].to_s,
      'author' => (account['display_name'].to_s.empty? ? account['username'] : account['display_name']).to_s,
      'author_url' => account['url'].to_s,
      'avatar' => account['avatar'].to_s,
      'url' => status['url'].to_s,
      'date' => status['created_at'].to_s,
      'favourites' => status['favourites_count'].to_i,
      'html' => status['content'].to_s
    }
  end

  # --- Bluesky ----------------------------------------------------------

  # One request per post: getPostThread carries the counts and the whole
  # reply tree at once. The values keep the Mastodon-era key names
  # (favourites/reblogs) on purpose -- stats.json stays one shape and the
  # client renders it without caring which network it came from.
  #
  # With moderation on the same call goes through the PDS with a session
  # instead of the public AppView, which is the only way post.viewer.like
  # is filled in at all.
  def fetch_bluesky(uri)
    path = "xrpc/app.bsky.feed.getPostThread?depth=10&uri=#{URI.encode_www_form_component(uri)}"
    data = if approval
             bluesky_authed_get(path)
           else
             JSON.parse(FeedHttp.get("#{BLUESKY_APPVIEW}/#{path}"))
           end
    thread = data['thread'] || {}
    post = thread['post'] || {}

    unless approval
      return {
        'stats' => {
          'favourites' => post['likeCount'].to_i,
          'reblogs' => post['repostCount'].to_i,
          'comments' => count_bluesky_replies(thread['replies'])
        },
        'comments' => nil
      }
    end

    # Same refusal as the Mastodon side, and it catches a second thing for
    # free: #notFoundPost and #blockedPost come back in place of a post, so
    # thread['post'] is nil and there is no viewer to read -- which would
    # otherwise have published nulls and an empty discussion for a post that
    # was merely unreachable for a moment.
    blind!(:bluesky) if post['viewer'].nil?

    shown = approved_bluesky(thread['replies'], post.dig('author', 'did'), [])
    {
      'stats' => {
        'favourites' => post['likeCount'].to_i,
        'reblogs' => post['repostCount'].to_i,
        'comments' => shown.size
      },
      'comments' => shown.map { |p| bluesky_comment(p) }
    }
  end

  # app.bsky.* through the account's own PDS, which proxies to the AppView
  # for an authenticated caller -- named explicitly via atproto-proxy so
  # the route doesn't rest on the PDS's default. One session per run, not
  # per post: BlueskyPoster creates one per call because a blog publishes
  # rarely, but this runs over every announced post on every cron tick.
  def bluesky_authed_get(path)
    require_relative 'bluesky_poster'
    @bluesky_session ||= begin
      password = ENV['BLUESKY_APP_PASSWORD'].to_s
      if password.empty?
        raise 'comments.approval is on but BLUESKY_APP_PASSWORD is not set -- ' \
              'without it the API never says which replies you liked.'
      end

      BlueskyPoster.xrpc_post('com.atproto.server.createSession',
                              { identifier: BlueskyPoster::HANDLE, password: password })
    end

    JSON.parse(FeedHttp.get("#{BlueskyPoster::PDS}/#{path}",
                            bearer: @bluesky_session['accessJwt'],
                            headers: { 'atproto-proxy' => 'did:web:api.bsky.app#bsky_appview' }))
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

  # Depth-first, so a sub-conversation stays grouped under the reply that
  # started it -- and descending only into replies that are themselves
  # shown is what enforces the "no answer without its question" rule here:
  # a rejected comment takes its whole subtree with it.
  def approved_bluesky(replies, own_did, out)
    (replies || []).each do |item|
      post = item.is_a?(Hash) ? item['post'] : nil
      next unless post && post['record']
      next if (post['labels'] || []).any?

      approved = !post.dig('viewer', 'like').nil? ||
                 (!own_did.nil? && post.dig('author', 'did') == own_did)
      next unless approved

      out << post
      approved_bluesky(item['replies'], own_did, out)
    end
    out
  end

  # `text` rather than `html`: Bluesky reply text is plain text, so it is
  # the client that escapes it. Keeping the two networks in differently
  # named fields is deliberate -- the field name says how the body may be
  # treated, instead of leaving the client to guess.
  def bluesky_comment(post)
    author = post['author'] || {}
    handle = author['handle'].to_s
    rkey = post['uri'].to_s.split('/').last
    {
      'id' => post['uri'].to_s,
      'author' => (author['displayName'].to_s.empty? ? handle : author['displayName']).to_s,
      'author_url' => "https://bsky.app/profile/#{handle}",
      'avatar' => author['avatar'].to_s,
      'url' => "https://bsky.app/profile/#{handle}/post/#{rkey}",
      'date' => post.dig('record', 'createdAt').to_s,
      'favourites' => post['likeCount'].to_i,
      'text' => post.dig('record', 'text').to_s
    }
  end

  # --- driver -----------------------------------------------------------

  # Answers one question for `doctor --online`: can this site's
  # credentials see its own approvals at all? Returns :ok when the
  # network answered with viewer state, :blind when it answered without
  # it, and raises when it didn't answer.
  #
  # :blind is the failure worth naming. A token missing read:statuses
  # doesn't refuse anything -- it gets a perfectly good response with
  # `favourited` left out of it, which reads as "the author has approved
  # nothing" and empties every thread on the site. The probe asks about
  # the announcement rather than a reply so it works on a post nobody has
  # answered yet.
  def approval_probe(entry)
    if entry[:kind] == :mastodon
      parsed = parse_toot_url(entry[:key])
      return :blind unless parsed

      status = JSON.parse(FeedHttp.get("https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}",
                                       bearer: mastodon_token!))
      status.key?('favourited') ? :ok : :blind
    else
      path = "xrpc/app.bsky.feed.getPostThread?depth=0&uri=#{URI.encode_www_form_component(entry[:key])}"
      data = bluesky_authed_get(path)
      data.dig('thread', 'post', 'viewer').nil? ? :blind : :ok
    end
  end

  def fetch_one(entry)
    entry[:kind] == :mastodon ? fetch_mastodon(entry[:key]) : fetch_bluesky(entry[:key])
  rescue StandardError => e
    warn "Stats fetch failed (#{entry[:key]}): #{e.message}"
    nil
  end

  # recent_only: true skips posts older than RECENT_WINDOW_DAYS -- the
  # caller (refresh_sidebar.rb) merges the result into the previous
  # content of stats.json and comments.json, so a skipped old post simply
  # keeps its last known numbers and comments instead of disappearing.
  # Failed posts are likewise just skipped; one failed request doesn't
  # wipe out what is already published.
  #
  # That window is worth knowing about with moderation on: starring a
  # reply under a post older than RECENT_WINDOW_DAYS publishes it at the
  # next *full* refresh, up to a week away. `refresh-sidebar.sh --full`
  # is the way to not wait.
  #
  # Returns { key => { 'stats' => {...}, 'comments' => [...] or nil } }.
  def fetch_all(recent_only: false)
    list = entries
    if recent_only
      cutoff = Time.now - (RECENT_WINDOW_DAYS * 24 * 60 * 60)
      list = list.select { |e| Time.parse(e[:date]) >= cutoff rescue true }
    end

    list.each_with_object({}) do |entry, acc|
      result = fetch_one(entry)
      acc[entry[:key]] = result if result
    end
  end
end
