# frozen_string_literal: true

require 'cgi'
require 'json'
require 'time'
require 'uri'
require_relative 'feed_http'
require_relative 'i18n'
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

  # Run-scoped state for the Bluesky sign-in: the session, the error a
  # failed sign-in must keep answering with instead of trying again, and
  # whether the single permitted mid-run refresh has been spent. Declared
  # here rather than sprung into being on first assignment because each of
  # them is read before it is written.
  @bluesky_session = nil
  @bluesky_session_error = nil
  @bluesky_session_refreshed = false

  module_function

  def approval
    SiteConfig.comments_approval
  end

  # A status id is not a number. Mastodon writes decimal snowflakes,
  # GoToSocial writes a 26-character ULID, and both are just an opaque
  # string to everything here -- so the id pattern accepts letters too.
  STATUS_ID = '[A-Za-z0-9]+'

  # ORDER IS THE FIX, not a detail.
  #
  # GoToSocial's web address for a status is /@user/statuses/<ULID>, and
  # Mastodon's is /@user/<id>. Widening the Mastodon pattern alone would
  # make the loosest one match first and capture the literal word
  # "statuses" as the id -- the engine would then ask for
  # /api/v1/statuses/statuses/context, get a 404 and show nothing, which
  # is worse than today's honest nil. Most specific first, Mastodon's
  # last.
  #
  # Pleroma and Akkoma use /notice/<flake>, a third shape again. Out of
  # scope here, written down so the next person does not have to find it
  # twice.
  def parse_toot_url(url)
    text = url.to_s
    m = text.match(%r{\Ahttps?://([^/]+)/@[^/]+/statuses/(#{STATUS_ID})}o) ||     # GoToSocial web
        text.match(%r{\Ahttps?://([^/]+)/users/[^/]+/statuses/(#{STATUS_ID})}o) || # ActivityPub URI
        text.match(%r{\Ahttps?://([^/]+)/@[^/]+/(#{STATUS_ID})}o)                  # Mastodon web
    m && { instance: m[1], id: m[2] }
  end

  # An address in a shape the two patterns above do not know -- an import
  # that carried a foreign permalink, an instance since renamed, a field
  # filled in by hand -- used to end both callers in silence: fetch_mastodon
  # returned nil, so that post simply never got comments and nothing said
  # why, while approval_probe called the same input :blind and sent the
  # author off to reissue a token that was never the problem. Raising says
  # which address is unreadable in both places: fetch_one turns it into a
  # warning naming the post, and doctor into approval_probe_failed, which
  # quotes the message instead of accusing the credentials.
  # A host the site does NOT say it announces on. Only ever true when the
  # site names an instance and the post names a different one: with no
  # instance configured there is nothing to compare against, and the
  # archive's own URLs are then the only thing that knows where the
  # announcements live. Compared without scheme or path, because both
  # spellings turn up in configs written by hand.
  def foreign_host?(host)
    configured = SiteConfig.get('mastodon', 'instance').to_s
                           .sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '').downcase
    return false if configured.empty?

    configured != host.to_s.downcase
  end

  def parse_toot_url!(url)
    parse_toot_url(url) ||
      raise("mastodon_url #{url.to_s.inspect} is not an address this engine can read -- expected " \
            'https://instance/@user/123 or https://instance/users/user/statuses/123, so no ' \
            'engagement or comments can be fetched for that post.')
  end

  # The same list, plus how many post files could not be read at all. A
  # caller that NARROWS something by this list has to know that: a file
  # that will not parse is not a post that went away, and treating the two
  # alike deletes a published post's approved discussion from a file the
  # public reads.
  def entries_with_gaps
    before = unreadable_count
    list = entries.map { |entry| entry[:key] }
    [list, unreadable_count - before]
  end

  def unreadable_count
    @unreadable_count ||= 0
  end

  def entries
    Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
      post = JSON.parse(File.read(file, encoding: 'utf-8'))
      raise JSON::ParserError, 'not a post object' unless post.is_a?(Hash)

      # Both files this feeds are served from the public site and both are
      # keyed by the announcement's address, so an unpublished post landing
      # in them publishes two things the author withheld: where the post was
      # announced, and the whole discussion under it. A post taken back down
      # is a draft again (PostWriter keeps unpublished_from on it), so this
      # one test covers "not published yet" and "no longer published" alike.
      # The test is build_blog.rb's draft?, deliberately -- comments.json
      # must describe the site the build actually produced.
      next if post['state'].to_s == 'draft'

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
      @unreadable_count = unreadable_count + 1
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
    parsed = parse_toot_url!(url)

    # The token goes to the CONFIGURED instance and nowhere else. Which
    # host is asked comes from the post's own mastodon_url -- an imported
    # archive, a hand edit, an account that moved -- and sending the site's
    # bearer token to whatever hostname a post file happens to name hands
    # somebody else's server a credential that can read and write as the
    # author. Without the token the public parts of the thread still
    # answer; the private ones are not this engine's to fetch from a
    # stranger.
    stranger = foreign_host?(parsed[:instance])
    token = approval && !stranger ? mastodon_token! : nil
    if stranger
      warn "⚠️  #{parsed[:instance]} is not the instance in config/site.yml -- asked without the " \
           'token, so anything that needs one (a favourite, a follower-only reply) will be missing.'
    end
    base = "https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}"
    status = JSON.parse(FeedHttp.get(base, bearer: token))
    context = JSON.parse(FeedHttp.get("#{base}/context", bearer: token))
    # Whose decision hides a reply behind a content warning depends on
    # whether anybody is moderating. With moderation off nothing human has
    # looked at these replies before a reader does, so the blanket filter is
    # the only protection there is -- and the client applies the same one on
    # the path where the browser reads /context itself (assets/js/comments.js).
    # With `comments.approval: fav` a person read that exact reply and
    # starred it, and the automatic rule was quietly overruling them: a
    # starred reply behind a warning could never appear, however many times
    # it was starred, and nothing anywhere said so. An explicit approval
    # outranks a blanket rule. The warning itself is not thrown away -- see
    # mastodon_comment.
    all_descendants = context['descendants'] || []
    descendants = approval ? all_descendants : all_descendants.reject { |s| s['sensitive'] }

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
    raise I18n.t('stats.blind_answer', network: kind)
  end

  # `favourited` is absent, not false, on an unauthenticated response --
  # so a token that is missing or lacks read:statuses would read as "the
  # author approved nothing" and silently empty every thread on the site.
  # Refusing to answer at all is the honest failure: fetch_one turns it
  # into a warning and the previous comments.json entry survives.
  def mastodon_token!
    token = ENV['MASTODON_ACCESS_TOKEN'].to_s
    if token.empty?
      raise I18n.t('stats.no_mastodon_token')
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
    record = {
      'id' => status['id'].to_s,
      'author' => (account['display_name'].to_s.empty? ? account['username'] : account['display_name']).to_s,
      'author_url' => account['url'].to_s,
      'avatar' => account['avatar'].to_s,
      'url' => status['url'].to_s,
      'date' => status['created_at'].to_s,
      'favourites' => status['favourites_count'].to_i,
      'html' => mastodon_body(status)
    }
    media = mastodon_comment_media(status)
    record['media'] = media unless media.empty?
    record
  end

  # The pictures of an approved reply, which live outside the sanitised
  # content -- without this an approved picture reply was published as
  # just its words. Images only (a still that will not play reads as
  # broken), and none at all for a sensitive reply: the fold holds its
  # text, and a thumbnail would sit outside the fold.
  def mastodon_comment_media(status)
    return [] if status['sensitive']

    Array(status['media_attachments']).filter_map do |a|
      next unless a.is_a?(Hash) && a['type'] == 'image' && !a['preview_url'].to_s.empty?

      { 'src' => a['preview_url'].to_s,
        'href' => (a['url'] || a['remote_url'] || status['url']).to_s,
        'alt' => a['description'].to_s }
    end
  end

  # Now that a starred reply behind a content warning is published (see
  # fetch_mastodon), the warning has to travel with it. The client renders
  # `html` and knows nothing of spoiler_text, so leaving the field behind
  # would show every reader exactly the text its author chose to fold away
  # -- trading one silent failure for a worse one. <details> because it
  # needs no stylesheet and no new interface string to work: the summary is
  # the warning the reply's author wrote. Escaped, because spoiler_text is
  # plain text from anyone in the Fediverse while `content` is markup
  # Mastodon has already sanitised.
  def mastodon_body(status)
    content = status['content'].to_s
    spoiler = status['spoiler_text'].to_s.strip
    return content if spoiler.empty?

    "<details class=\"comment-cw\"><summary>#{CGI.escapeHTML(spoiler)}</summary>#{content}</details>"
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
  # Two createSession calls per run is the hard ceiling -- the sign-in and,
  # if the PDS rejects the session part-way through, a single refresh.
  def bluesky_authed_get(path)
    jwt = bluesky_session['accessJwt']
    begin
      JSON.parse(FeedHttp.get("#{BlueskyPoster::PDS}/#{path}",
                              bearer: jwt,
                              headers: { 'atproto-proxy' => 'did:web:api.bsky.app#bsky_appview' }))
    rescue StandardError => e
      # A session that expired mid-run was never noticed: the same dead JWT
      # went out for the rest of the run and every post from there on was
      # skipped. Safe -- nothing published gets overwritten -- but silent,
      # and on a --full pass over hundreds of posts it costs the whole run.
      #
      # Exactly one refresh per run, which is the difference between fixing
      # that and re-creating the storm the cache below exists to prevent: a
      # 401 on a session minted seconds ago is not an expiry, it is wrong
      # credentials or a route that never worked, and retrying it per post
      # would hammer createSession just as hard as the old ||= did. An
      # access token lasts hours and a refresh run minutes, so needing a
      # second one inside one run means something else is wrong.
      raise unless session_rejected?(e) && !@bluesky_session_refreshed

      @bluesky_session_refreshed = true
      @bluesky_session = nil
      bluesky_authed_get(path)
    end
  end

  # One sign-in per run -- and, crucially, one ATTEMPT per run. `||=`
  # remembered only success, so a REFUSED sign-in was repeated for every
  # announced post: a single cron tick made as many createSession calls as
  # the site has announcements, every half hour. Bluesky rate-limits that
  # endpoint per account and temporarily locks an account that keeps
  # failing -- and BlueskyPoster signs in the same way, so the lock would
  # take publishing down with the sidebar. The failure is remembered and
  # re-raised instead, which costs this run (every post is skipped rather
  # than the first one) and keeps the account usable for the next.
  def bluesky_session
    return @bluesky_session if @bluesky_session
    raise @bluesky_session_error if @bluesky_session_error

    require_relative 'bluesky_poster'
    password = ENV['BLUESKY_APP_PASSWORD'].to_s
    if password.empty?
      raise I18n.t('stats.no_bluesky_password')
    end

    @bluesky_session = BlueskyPoster.xrpc_post('com.atproto.server.createSession',
                                               { identifier: BlueskyPoster::HANDLE, password: password })
  rescue StandardError => e
    @bluesky_session_error = e
    raise
  end

  # FeedHttp turns any non-2xx into a RuntimeError whose message is the
  # status line, so the text is the only channel there is for telling "this
  # session is no longer accepted" apart from a request that was wrong for
  # some other reason.
  def session_rejected?(error)
    error.message.to_s.start_with?('HTTP 401 ')
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

      approved = bluesky_liked?(post) ||
                 (!own_did.nil? && post.dig('author', 'did') == own_did)
      next unless approved

      out << post
      approved_bluesky(item['replies'], own_did, out)
    end
    out
  end

  # What "the author liked this" looks like on the wire: viewer.like is the
  # AT-URI of the like record, or the key is simply absent. The test used to
  # be "the key is there and is not null", which let any value nobody
  # defined -- an empty string above all -- publish a reply the author never
  # picked. Mastodon's half of the same decision asks for `== true`, and the
  # whole feature is "nothing gets out that I did not choose", so the two
  # networks are held to the same strictness: a like is a reference to a
  # like record, and an empty string is a reference to nothing.
  def bluesky_liked?(post)
    like = post.dig('viewer', 'like')
    like.is_a?(String) && !like.strip.empty?
  end

  # `text` rather than `html`: Bluesky reply text is plain text, so it is
  # the client that escapes it. Keeping the two networks in differently
  # named fields is deliberate -- the field name says how the body may be
  # treated, instead of leaving the client to guess.
  def bluesky_comment(post)
    author = post['author'] || {}
    handle = author['handle'].to_s
    rkey = post['uri'].to_s.split('/').last
    url = "https://bsky.app/profile/#{handle}/post/#{rkey}"
    record = {
      'id' => post['uri'].to_s,
      'author' => (author['displayName'].to_s.empty? ? handle : author['displayName']).to_s,
      'author_url' => "https://bsky.app/profile/#{handle}",
      'avatar' => author['avatar'].to_s,
      'url' => url,
      'date' => post.dig('record', 'createdAt').to_s,
      'favourites' => post['likeCount'].to_i,
      'text' => post.dig('record', 'text').to_s
    }
    media = bluesky_comment_media(post, url)
    record['media'] = media unless media.empty?
    record
  end

  # Same words as the Mastodon side: the view embed carries thumb,
  # fullsize and alt; a labelled post keeps its pictures to itself.
  def bluesky_comment_media(post, url)
    return [] if Array(post['labels']).any?

    embed = post['embed'] || {}
    images = embed['images'] || embed.dig('media', 'images') || []
    Array(images).filter_map do |img|
      next unless img.is_a?(Hash) && !img['thumb'].to_s.empty?

      { 'src' => img['thumb'].to_s,
        'href' => (img['fullsize'].to_s.empty? ? url : img['fullsize'].to_s),
        'alt' => img['alt'].to_s }
    end
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
  # :blind means one thing only: the network answered ABOUT THIS POST and
  # left the viewer state out of the answer. It used to be returned for two
  # situations the credentials have nothing to do with -- an address
  # parse_toot_url could not read, and an announcement that is deleted or
  # momentarily unreachable, where there is no post to carry a viewer at
  # all. doctor renders :blind as "your credentials cannot see your
  # favourites" with a fix that says reissue the token, so a post the author
  # deleted last month came back as a bug report about env.sh. Both now
  # raise, which doctor already handles: approval_probe_failed quotes the
  # message instead of naming a culprit.
  def approval_probe(entry)
    if entry[:kind] == :mastodon
      parsed = parse_toot_url!(entry[:key])
      # The same boundary fetch_mastodon keeps: the write-scoped token goes
      # to the CONFIGURED instance and nowhere else. The entry is whatever
      # announcement is newest, and on an archive with a legacy or imported
      # one that can be a host the site does not run on -- sending the
      # bearer there hands a stranger a credential that can post as the
      # author. Refused with a sentence doctor already renders (it turns a
      # raise into approval_probe_failed) rather than leaked.
      if foreign_host?(parsed[:instance])
        raise "the newest announcement is on #{parsed[:instance]}, which is not the instance in " \
              'config/site.yml -- the token is not sent to another server to test it, so favourite ' \
              'visibility cannot be checked from here.'
      end
      status = JSON.parse(FeedHttp.get("https://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}",
                                       bearer: mastodon_token!))
      status.key?('favourited') ? :ok : :blind
    else
      path = "xrpc/app.bsky.feed.getPostThread?depth=0&uri=#{URI.encode_www_form_component(entry[:key])}"
      post = bluesky_authed_get(path).dig('thread', 'post')
      # #notFoundPost and #blockedPost come back in place of a post, so
      # there is no viewer to read and nothing here is a verdict on the
      # credentials.
      if post.nil?
        raise "the announcement #{entry[:key]} did not come back from the network -- it was deleted, " \
              'blocked or briefly unreachable, so there was no thread to test the app password against.'
      end

      post['viewer'].nil? ? :blind : :ok
    end
  end

  def fetch_one(entry)
    entry[:kind] == :mastodon ? fetch_mastodon(entry[:key]) : fetch_bluesky(entry[:key])
  rescue StandardError => e
    warn I18n.t('poster.stats_fetch_failed', key: entry[:key], message: e.message)
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
