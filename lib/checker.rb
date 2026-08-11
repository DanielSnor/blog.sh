# frozen_string_literal: true

require 'json'
require 'set'
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
  FIXED_PATHS = ['/', '/search/', '/markdown/'].freeze

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

  def run(root:, progress: nil)
    posts = load_posts(root)
    return [warn(t('no_posts'))] if posts.empty?

    known = known_paths(posts)
    findings = []
    findings.concat(check_media(root, posts, progress))
    findings.concat(check_degenerate_images(posts))
    findings.concat(check_internal_links(posts, known))
    findings.concat(check_orphan_media(root, posts))
    findings.concat(check_redirects(posts))
    findings << ok(t('all_clear', posts: posts.size)) if findings.none? { |f| f.error? || f.warn? }
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
        paths << "/tag/#{slug}/" unless slug.empty?
      end
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

  # Both places a link can live: a block that is a link card, and a
  # formatting span inside any text the post carries.
  def internal_links(post)
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
    end.select { |url| url.start_with?('/') }
  end
end
