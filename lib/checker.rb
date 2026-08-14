# frozen_string_literal: true

require 'json'
require 'set'
require 'fileutils'
require 'net/http'
require 'uri'
require 'timeout'
require_relative 'slug'
require_relative 'i18n'

# What `./blog.sh check` finds. Doctor's counterpart, and deliberately a
# separate thing: doctor answers "is this installation sound", reads a
# handful of config values and takes a second, while this walks every post
# and every media file in the archive. Rolled into one command, the fast
# half would stop being run.
#
# It reads the CONTENT rather than the built site. A finding has to name a
# post and a slug -- something to go and fix -- rather than a file under
# public.nosync, and it must work before a build has ever run. Judging
# links still needs to know what addresses the build produces, so those are
# derived here from the same rules build_blog.rb uses.
#
# It only ever reports. Nothing here deletes an orphaned media directory or
# rewrites a post: the whole value of the tool is that its output can be
# trusted, and a checker that also acts is one that has to be trusted twice.
module Checker
  Finding = Struct.new(:level, :text, :fix, keyword_init: true) do
    def error?
      level == :error
    end

    def warn?
      level == :warn
    end
  end

  # Everything a page of this site can be, other than a post: the generated
  # pages and the roots. A link to one of these is fine even though no post
  # produces it.
  #
  # The four files at the end are written by every build, unconditionally,
  # and they were missing -- so a post linking to its own site's feed was
  # reported as a dead link, with the advice that it was probably a permalink
  # left over from an import. A checker that is confidently wrong about a
  # working address costs more than one that says nothing, which is the rule
  # the comment on known_paths sets out and this list was breaking.
  FIXED_PATHS = ['/', '/search/', '/markdown/',
                 '/rss.xml', '/sitemap.xml', '/robots.txt', '/404.html'].freeze

  # A listing's later pages live under <listing>/page/N/, whatever the
  # listing is -- the front page, a tag, a series, a content type. How many
  # there are depends on site.page_size, so counting them here is exactly
  # the second opinion known_paths refuses to give; the base address is the
  # thing worth checking, and it is checked. Trailing digits only, so a post
  # whose slug happens to be "page" is unaffected.
  PAGE_SUFFIX = %r{/page/\d+/?\z}.freeze

  module_function

  def t(key, **vars)
    I18n.t("check.#{key}", **vars)
  end

  def ok(text)
    Finding.new(level: :ok, text: text)
  end

  def warn(text, fix = nil)
    Finding.new(level: :warn, text: text, fix: fix)
  end

  def error(text, fix = nil)
    Finding.new(level: :error, text: text, fix: fix)
  end

  def run(root:, progress: nil, online: false, online_progress: nil)
    posts = load_posts(root)
    return [warn(t('no_posts'))] if posts.empty?

    known = known_paths(posts)
    findings = []
    findings.concat(check_media(root, posts, progress))
    findings.concat(check_degenerate_images(posts))
    findings.concat(check_internal_links(posts, known))
    findings.concat(check_orphan_media(root, posts))
    findings.concat(check_redirects(posts))
    findings.concat(check_series_names(posts))
    local_clean = findings.none? { |f| f.error? || f.warn? }
    findings << ok(t('all_clear', posts: posts.size)) if local_clean

    if online
      cache = Cache.new(File.join(root, 'tmp', 'link-check.json'))
      findings.concat(check_external_links(posts, cache: cache, online_progress: online_progress))
      cache.save
    end
    findings
  end

  # --- reading the archive ------------------------------------------------

  def load_posts(root)
    dir = File.join(root, 'content.nosync', 'posts')
    Dir.glob(File.join(dir, '*', '*.json')).sort.filter_map do |path|
      post = JSON.parse(File.read(path, encoding: 'utf-8'))
      next unless post.is_a?(Hash)

      post['__path'] = path
      post['__year'] = File.basename(File.dirname(path))
      post
    rescue JSON::ParserError
      nil
    end
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  def post_path(post)
    return "/draft/#{post['draft_token']}/#{post['slug']}/" if draft?(post)
    # A page is served at the root, not under a year. Reading its
    # address off the year was quiet in both directions: a link to
    # /about/ was reported dead, and the dated address it invented
    # instead was accepted from anywhere.
    return "/#{post['slug']}/" if post['page']

    "/posts/#{post['__year']}/#{post['slug']}/"
  end

  # Every address the build will answer at: the posts themselves, the tag
  # listings, the redirect stubs a post carries, and the fixed pages.
  #
  # Type listings are deliberately absent. Which types exist is decided by
  # a heuristic in build_blog.rb (dominant_content_type), and copying it
  # here would give this tool a second opinion that drifts from the first
  # -- a checker that reports links as dead because it disagrees with the
  # build is worse than one that says nothing about them. /type/ links are
  # therefore accepted without inspection.
  def known_paths(posts)
    paths = Set.new(FIXED_PATHS)
    posts.each do |post|
      paths << post_path(post)
      (post['tags'] || []).each do |tag|
        slug = Slug.slugify(tag.to_s)
        next if slug.empty?

        paths << "/tag/#{slug}/"
        # A tag the site names in its menu gets a feed of its own. Which
        # tags those are is a config question, so the feed is accepted
        # wherever the tag itself is known rather than worked out again.
        paths << "/tag/#{slug}/rss.xml"
      end
      # Series listings are derived the same way tag listings are -- from a
      # key the post carries -- so unlike the content types there is nothing
      # to guess and no second opinion to drift. They were simply forgotten
      # when series arrived in this cycle, which made every link to one a
      # reported dead link and gave `check` a non-zero exit over a healthy
      # archive.
      series = Slug.slugify(post['series'].to_s)
      paths << "/series/#{series}/" unless series.empty?
      Array(post['former_slugs']).each { |former| paths << "/posts/#{former}/" }
      Array(post['redirect_from']).each { |origin| paths << origin.to_s }
    end
    paths
  end

  # --- the checks ----------------------------------------------------------

  # A post whose media never arrived. The import summary said so at the
  # time and nothing has said so since, which is why a whole archive can
  # carry these for years without anyone knowing.
  def check_media(root, posts, progress)
    missing = []
    posts.each_with_index do |post, index|
      progress&.call(index + 1, posts.size)
      dir = File.join(root, 'media.nosync', post['__year'], post['slug'].to_s)
      media_urls(post).each do |url|
        next if url.empty? || url.include?('://')

        missing << [post['slug'], url] unless File.exist?(File.join(dir, url))
      end
    end
    return [] if missing.empty?

    missing.first(20).map do |slug, url|
      error(t('media_missing', slug: slug, file: url), t('media_missing_fix'))
    end + more(missing.size - 20)
  end

  # Images the build will drop on the floor: a size of 1px or less is the
  # tracking pixel rule, and the block goes with its caption. Nothing on
  # the rendered page shows that anything used to be there.
  def check_degenerate_images(posts)
    found = posts.flat_map do |post|
      (post['content'] || []).filter_map do |block|
        next unless block.is_a?(Hash) && block['type'] == 'image'

        media = (block['media'] || []).first || {}
        w = Integer(media['width'], exception: false)
        h = Integer(media['height'], exception: false)
        next if w.nil? || h.nil?

        [post['slug'], media['url'].to_s, w, h] if w <= 1 || h <= 1
      end
    end
    return [] if found.empty?

    found.first(20).map do |slug, url, w, h|
      warn(t('image_degenerate', slug: slug, file: url, width: w, height: h), t('image_degenerate_fix'))
    end + more(found.size - 20)
  end

  # Links from one post to another address on this site that nothing will
  # ever answer at -- the residue of an import that rewrote permalinks, or
  # of a slug that was renamed before renaming kept a redirect.
  def check_internal_links(posts, known)
    dead = []
    posts.each do |post|
      internal_links(post).each do |url|
        path = url.split('#').first.split('?').first.to_s
        next if path.empty? || path.start_with?('/type/') || path.start_with?('/assets/')
        next if known.include?(path) || known.include?("#{path}/")

        # A later page of a listing is judged by the listing it belongs to.
        base = path.sub(PAGE_SUFFIX, '/')
        next if base != path && (known.include?(base) || known.include?("#{base}/"))

        dead << [post['slug'], url]
      end
    end
    return [] if dead.empty?

    dead.first(20).map { |slug, url| error(t('link_dead', slug: slug, url: url), t('link_dead_fix')) } +
      more(dead.size - 20)
  end

  # Media directories no post claims. Pure disk, invisible from anywhere --
  # left behind by a delete, a rename, or an import that ran twice.
  def check_orphan_media(root, posts)
    media_root = File.join(root, 'media.nosync')
    return [] unless Dir.exist?(media_root)

    owned = posts.map { |post| File.join(post['__year'], post['slug'].to_s) }.to_set
    orphans = Dir.glob(File.join(media_root, '*', '*')).select { |p| File.directory?(p) }.filter_map do |dir|
      rel = dir.sub("#{media_root}/", '')
      rel unless owned.include?(rel)
    end
    return [] if orphans.empty?

    orphans.first(20).map { |rel| warn(t('media_orphan', dir: rel), t('media_orphan_fix')) } +
      more(orphans.size - 20)
  end

  # Two posts claiming one old address. The build answers with whichever it
  # rendered last, so the loser's readers land on the winner's post and no
  # warning is printed anywhere.
  # Two series whose slugs differ by a character are usually one series
  # with a typo in it -- and the archive keeps the mistake invisible: the
  # misspelling founds its own series, and with fewer than two members it
  # never even gets a page to be noticed on. The draft preview says this
  # at writing time; this is the net for the typo made half a year ago.
  #
  # Two guards against crying wolf, because a check nobody believes is a
  # check nobody runs. Slugs whose difference is digits only are left
  # alone -- rok-2025 next to rok-2026 is two year-series, not a typo.
  # And a distance of two only counts when one side has a single post:
  # two established series that merely have similar names are not news.
  def check_series_names(posts)
    groups = posts.reject { |p| draft?(p) }
                  .group_by { |p| Slug.slugify(p['series'].to_s) }
                  .reject { |slug, _| slug.empty? }
    findings = []
    groups.keys.sort.combination(2) do |a, b|
      next if a.delete('0-9') == b.delete('0-9')

      distance = edit_distance(a, b)
      next if distance > 2
      next if distance == 2 && [groups[a].size, groups[b].size].min > 1

      names = [a, b].map { |slug| groups[slug].map { |p| p['series'].to_s.strip }.uniq.first }
      findings << warn(t('series_similar', a: names[0], count_a: groups[a].size,
                                           b: names[1], count_b: groups[b].size),
                       fix: t('series_similar_fix'))
    end
    findings
  end

  # Plain Levenshtein over two short slugs; nothing here is hot.
  def edit_distance(a, b)
    return (a.length - b.length).abs if a.empty? || b.empty?

    previous = (0..b.length).to_a
    a.each_char.with_index do |ca, i|
      current = [i + 1]
      b.each_char.with_index do |cb, j|
        current << [previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1)].min
      end
      previous = current
    end
    previous.last
  end

  def check_redirects(posts)
    claims = Hash.new { |h, k| h[k] = [] }
    posts.each do |post|
      Array(post['redirect_from']).each { |origin| claims[origin.to_s] << post['slug'] }
      Array(post['former_slugs']).each { |former| claims["/posts/#{former}/"] << post['slug'] }
    end
    claims.filter_map do |origin, slugs|
      next if slugs.uniq.size < 2

      error(t('redirect_collision', origin: origin, slugs: slugs.uniq.join(', ')), t('redirect_collision_fix'))
    end
  end

  # --- the outside world (--online only) -----------------------------------

  # Asked for by name, never as part of an ordinary run: this is the only
  # part of check that leaves the machine, it takes minutes rather than a
  # second, and over an archive going back twenty years it will find things
  # nobody can do anything about.
  #
  # What counts as a finding is deliberately narrow. A host that does not
  # resolve, and a 404/410, are the web saying "this is gone". A timeout, a
  # refused connection, a 5xx, a TLS error, a 403 -- those are the web
  # saying "not right now", and reporting them turns one flaky evening into
  # forty findings that are all still fine tomorrow. A checker nobody
  # believes is worse than no checker.
  ONLINE_GONE = [404, 410].freeze
  # Politeness rather than throughput: one request at a time, and a pause
  # between two requests to the SAME host. An archive with two hundred
  # links to one site should not read as an attack on it.
  ONLINE_HOST_PAUSE = 1.0

  def check_external_links(posts, cache: nil, online_progress: nil)
    urls = external_urls(posts)
    return [] if urls.empty?

    results = {}
    last_seen = {}
    urls.each_with_index do |url, index|
      online_progress&.call(index + 1, urls.size)
      cached = cache && cache.fetch(url)
      if cached
        results[url] = cached
        next
      end

      host = begin
        URI.parse(url).host
      rescue URI::InvalidURIError
        nil
      end
      if host && last_seen[host]
        wait = ONLINE_HOST_PAUSE - (Time.now - last_seen[host])
        sleep(wait) if wait.positive?
      end
      verdict = probe(url)
      last_seen[host] = Time.now if host
      results[url] = verdict
      cache&.store(url, verdict)
    end

    gone = results.select { |_, verdict| verdict[:gone] }
    return [ok(t('online_ok', count: urls.size))] if gone.empty?

    owners = url_owners(posts)
    gone.keys.first(20).map do |url|
      error(t('link_gone', slug: owners[url].to_s, url: url, reason: gone[url][:reason]),
            t('link_gone_fix'))
    end + more(gone.size - 20)
  end

  # HEAD first: a link checker has no use for the body, and a HEAD over a
  # few thousand links is the difference between minutes and an afternoon.
  #
  # But HEAD is never believed when it says the page is GONE. Some servers
  # answer it with 405 or 501 while serving GET perfectly; worse, some
  # answer 404 to HEAD and 200 to GET for the very same address --
  # bsky.app does exactly this on profile pages, and the first run of this
  # check over a real archive reported thirty-four live links as dead
  # because of it. So anything that looks fatal is confirmed with a GET,
  # which costs one extra request per apparently-dead link and buys the
  # only thing this tool has: being right.
  RETRY_WITH_GET = ([405, 501] + ONLINE_GONE).freeze

  def probe(url, redirects_left = 4)
    uri = URI.parse(url)
    return { gone: false } unless uri.is_a?(URI::HTTP) && uri.host

    res = request(uri, Net::HTTP::Head)
    res = request(uri, Net::HTTP::Get) if res.is_a?(Net::HTTPResponse) && RETRY_WITH_GET.include?(res.code.to_i)

    case res
    when :dns
      { gone: true, reason: t('reason_no_host') }
    when :unreachable, nil
      { gone: false }
    else
      code = res.code.to_i
      if [301, 302, 303, 307, 308].include?(code) && res['location'] && redirects_left.positive?
        return probe(URI.join(url, res['location']).to_s, redirects_left - 1)
      end

      ONLINE_GONE.include?(code) ? { gone: true, reason: code.to_s } : { gone: false }
    end
  rescue URI::Error
    { gone: false }
  end

  def request(uri, klass)
    # Required here rather than at the top of the file, and it is not
    # tidiness: feed_http reads SiteConfig at LOAD time, and doctor --
    # which shares this file's knowledge of what addresses exist --
    # has to run on a config nothing else can read. Requiring it up
    # there killed doctor on an unreadable site.yml, which is the one
    # case doctor exists for. Same lazy-require reasoning as rexml in
    # the sidebar fetchers (docs/decisions.md).
    require_relative 'feed_http'
    req = klass.new(uri)
    req['User-Agent'] = FeedHttp::USER_AGENT
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 10, read_timeout: 15) do |http|
      http.request(req)
    end
  rescue SocketError
    # The host does not resolve at all -- a dead domain, which is the one
    # network condition that will still be true tomorrow.
    :dns
  rescue StandardError, Timeout::Error
    :unreachable
  end

  def external_urls(posts)
    posts.flat_map { |post| all_links(post) }
         .select { |url| url.start_with?('http://', 'https://') }
         .uniq
  end

  # Which post to name in the finding. The first one that carries the link:
  # the same dead address usually sits in several, and listing all of them
  # would bury the twenty findings under their own footnotes.
  def url_owners(posts)
    posts.each_with_object({}) do |post, acc|
      all_links(post).each { |url| acc[url] ||= post['slug'] }
    end
  end

  # --- shared --------------------------------------------------------------

  # Long lists are capped rather than printed in full: a thousand identical
  # findings is not more information than twenty, and it buries every other
  # kind. The count of what was left out is part of the report, though --
  # silently truncating would read as "that was all of it".
  def more(remaining)
    remaining.positive? ? [warn(t('and_more', count: remaining))] : []
  end

  def media_urls(post)
    (post['content'] || []).flat_map do |block|
      next [] unless block.is_a?(Hash)

      Array(block['media']).filter_map { |m| m['url'].to_s if m.is_a?(Hash) }
    end
  end

  def internal_links(post)
    all_links(post).select { |url| url.start_with?('/') }
  end

  # Both places a link can live: a block that is a link card, and a
  # formatting span inside any text the post carries.
  def all_links(post)
    (post['content'] || []).flat_map do |block|
      next [] unless block.is_a?(Hash)

      urls = []
      urls << block['url'].to_s if block['type'] == 'link'
      Array(block['formatting']).each do |span|
        urls << span['url'].to_s if span.is_a?(Hash) && span['type'] == 'link'
      end
      Array(block['items']).each do |item|
        Array(item.is_a?(Hash) ? item['formatting'] : nil).each do |span|
          urls << span['url'].to_s if span.is_a?(Hash) && span['type'] == 'link'
        end
      end
      urls
    end.reject(&:empty?)
  end

  # Remembers what an address answered, so a second run only asks about the
  # links it has not seen lately. Without it nobody runs this twice: a few
  # thousand requests is minutes, and most of the answers were the same
  # yesterday.
  #
  # A failure to read or write it is not an error -- the check simply asks
  # the network again, which is the thing it was going to do anyway.
  class Cache
    MAX_AGE = 14 * 24 * 60 * 60

    def initialize(path)
      @path = path
      @data = File.exist?(path) ? (JSON.parse(File.read(path, encoding: 'utf-8')) || {}) : {}
      @data = {} unless @data.is_a?(Hash)
      @dirty = false
    rescue StandardError
      @data = {}
      @dirty = false
    end

    def fetch(url)
      entry = @data[url]
      return nil unless entry.is_a?(Hash) && entry['at'].is_a?(Numeric)
      return nil if Time.now.to_i - entry['at'] > MAX_AGE

      { gone: entry['gone'] ? true : false, reason: entry['reason'] }
    end

    def store(url, verdict)
      @data[url] = { 'gone' => verdict[:gone], 'reason' => verdict[:reason], 'at' => Time.now.to_i }
      @dirty = true
    end

    def save
      return unless @dirty

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(@data), encoding: 'utf-8')
    rescue StandardError
      nil
    end
  end
end
