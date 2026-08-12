# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'yaml'
require_relative 'markdown_writer'

# lib/exporter.rb -- the archive as a tree of markdown files: what
# `./blog.sh export` writes, and the mirror of lib/import/. The engine
# imports from twenty-two places, so it owes the same courtesy in the
# other direction -- a site that cannot be taken elsewhere is a site
# nobody should be asked to move in.
#
# The tree is Jekyll's, because it is the layout the most other engines
# read: `_posts/<date>-<slug>.md`, `_drafts/<slug>.md`, pages at the
# root, media under `assets/`. Hugo, Eleventy and Astro read it with a
# config line; blog.sh's own Import::Jekyll reads it with nothing at all,
# which is what makes the round-trip test possible.
#
# It only ever reads. Nothing here touches content.nosync, media.nosync
# or the built site: an export that could damage the archive it is
# leaving with would be the one tool nobody could afford to run.
module Exporter
  # Counted rather than merely done, because the summary has to answer
  # the question anyone runs an export to answer -- did all of it come
  # out, and what did not survive the format. `fallbacks` is a Hash of
  # block type => count (see html_fallback), `collisions` the number of
  # files that had to be renamed to avoid overwriting each other.
  Result = Struct.new(:posts, :drafts, :pages, :media, :bytes, :fallbacks,
                      :collisions, keyword_init: true)

  # Where a post's media lives in the export, relative to its root. The
  # year is the archive's own directory rather than the post's date:
  # media.nosync is filed that way, and a post whose date was edited
  # across a new year keeps its files where they actually are.
  ASSETS = 'assets'

  module_function

  # ROOT is the installation, TARGET the directory to fill. `drafts:
  # false` leaves unpublished work at home -- the common case when the
  # export is going somewhere public. `dry_run: true` counts everything
  # and writes nothing, the same promise `./import.sh` makes before it
  # writes.
  def run(root:, target:, drafts: true, dry_run: false, progress: nil)
    posts = load_posts(root)
    posts = posts.reject { |p| draft?(p) } unless drafts
    result = Result.new(posts: 0, drafts: 0, pages: 0, media: 0, bytes: 0,
                        fallbacks: Hash.new(0), collisions: 0)
    taken = {}

    posts.each_with_index do |post, index|
      export_post(post, root: root, target: target, taken: taken,
                  dry_run: dry_run, result: result)
      progress&.call(index + 1, posts.size)
    end
    result
  end

  # The same walk lib/checker.rb makes, kept separate on purpose: that
  # module pulls in net/http and the whole link checker with it, and an
  # export must run on an installation whose network is the reason it is
  # being exported.
  def load_posts(root)
    dir = File.join(root, 'content.nosync', 'posts')
    Dir.glob(File.join(dir, '*', '*.json')).sort.filter_map do |path|
      post = JSON.parse(File.read(path, encoding: 'utf-8'))
      next unless post.is_a?(Hash)

      post['__year'] = File.basename(File.dirname(path))
      post
    rescue JSON::ParserError
      # check reports these by name; an export refusing to run over one
      # bad file would strand everything else in the archive.
      nil
    end
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  # `type: page` is how a page is written; `page: true` is how it was
  # written before, and both are still read -- the same pair
  # scripts/manage_post.rb accepts.
  def page?(post)
    post['type'].to_s == 'page' || truthy?(post['page'])
  end

  def truthy?(value)
    return false if value.nil? || value == false

    !%w[false no 0].include?(value.to_s.strip.downcase)
  end

  # --- one post ------------------------------------------------------------

  def export_post(post, root:, target:, taken:, dry_run:, result:)
    year = post['__year'].to_s
    slug = post['slug'].to_s
    name = file_name(post, slug, taken, result)
    path = File.join(target, *dir_for(post), name)
    media_rel = "/#{ASSETS}/#{year}/#{slug}"

    body, fallbacks = render_blocks(post['content'], media_rel)
    fallbacks.each { |type, count| result.fallbacks[type] += count }

    unless dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{front_matter(post)}#{body}\n", encoding: 'utf-8')
    end

    copy_media(root, target, year, slug, dry_run: dry_run, result: result)

    if page?(post) then result.pages += 1
    elsif draft?(post) then result.drafts += 1
    else result.posts += 1
    end
  end

  # Jekyll's three homes: pages at the root (a page has no date and no
  # listing to sit in), drafts in _drafts/ under a bare name, everything
  # else in _posts/ under its date.
  def dir_for(post)
    return [] if page?(post)

    draft?(post) ? ['_drafts'] : ['_posts']
  end

  def file_name(post, slug, taken, result)
    base = if page?(post) || draft?(post)
             slug
           else
             "#{date_of(post).strftime('%Y-%m-%d')}-#{slug}"
           end
    # Slugs are unique across the archive, so this is a belt-and-braces
    # count rather than an expected case -- but two files silently
    # becoming one is the sort of loss an export must never take.
    name = base
    suffix = 1
    while taken[name]
      suffix += 1
      name = "#{base}-#{suffix}"
      result.collisions += 1
    end
    taken[name] = true
    "#{name}.md"
  end

  # Parsed with the offset it was stored with, not converted: the day in
  # the filename must be the day the site showed, and a post written at
  # 00:30 +02:00 belongs to that date, not to the one UTC would give it.
  def date_of(post)
    Time.parse(post['date'].to_s)
  rescue ArgumentError, TypeError
    Time.new(post['__year'].to_i.positive? ? post['__year'].to_i : 1970, 1, 1)
  end

  # The post's whole media directory, not just the files its blocks name.
  # A poster frame, an imported thumbnail or a file some future block
  # type learns to carry all live here, and an export that copied only
  # what today's writer happens to reference would quietly thin the
  # archive out. Copies, never moves: the original stays where it is.
  def copy_media(root, target, year, slug, dry_run:, result:)
    source = File.join(root, 'media.nosync', year, slug)
    return unless Dir.exist?(source)

    dest = File.join(target, ASSETS, year, slug)
    FileUtils.mkdir_p(dest) unless dry_run
    Dir.glob(File.join(source, '*')).sort.each do |file|
      next unless File.file?(file)

      result.media += 1
      result.bytes += File.size(file)
      FileUtils.cp(file, File.join(dest, File.basename(file))) unless dry_run
    end
  end

  # --- body ----------------------------------------------------------------

  # Block by block rather than in one call, so a block markdown cannot
  # write down can be spotted and given an HTML form instead of
  # disappearing. MarkdownWriter drops what it has no syntax for -- the
  # link card, an imported embed -- which is right for `edit` (the CLI
  # has a loss guard behind it) and wrong here: an export is the last
  # copy somebody keeps.
  #
  # Rendering one block at a time is equivalent to rendering them
  # together: the writer carries no state between blocks, it maps and
  # joins with a blank line, which is what happens here too.
  def render_blocks(blocks, media_rel)
    fallbacks = Hash.new(0)
    parts = Array(blocks).map do |block|
      rendered = MarkdownWriter.blocks_to_markdown([block], media_rel)
      next rendered unless rendered.strip.empty?

      fallbacks[block['type'].to_s] += 1
      html_fallback(block)
    end
    [parts.reject { |p| p.to_s.empty? }.join("\n\n"), fallbacks]
  end

  # Raw HTML inside markdown, which Jekyll, Hugo and Eleventy all pass
  # through untouched -- so the destination site keeps the content even
  # though the markdown could not express it. Deliberately the same
  # markup build/build_blog.rb renders, rather than a prettier version
  # of it: what comes out of the export should look like what the site
  # looked like.
  #
  # blog.sh's own importer reads these back as text, not as blocks --
  # which is why every one of them is counted and said out loud instead
  # of being quietly declared a success.
  def html_fallback(block)
    case block['type'].to_s
    when 'link'
      title = escape_html((block['title'] || block['url']).to_s)
      description = escape_html(block['description'].to_s)
      link = escape_html(block['url'].to_s)
      %(<p class="link-block"><a href="#{link}"><strong>#{title}</strong></a><br>#{description}</p>)
    when 'video', 'audio'
      embed = block['embed_html'].to_s
      next_best = block['url'].to_s
      if !embed.strip.empty? then embed
      elsif !next_best.empty?
        %(<p><a href="#{escape_html(next_best)}">#{escape_html(next_best)}</a></p>)
      else
        ''
      end
    else
      # What the build does with a block type it does not know: show it
      # rather than swallow it.
      "<pre>#{escape_html(block.to_json)}</pre>"
    end
  end

  def escape_html(text)
    text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  # --- front matter --------------------------------------------------------

  # Written as real YAML, and NOT through the CLI's build_frontmatter:
  # that one is deliberately not YAML at all (its reader splits on the
  # first colon and quotes nothing), which is exactly right for a human
  # editing one post and fatal here. Everything downstream of an export
  # -- Jekyll, Hugo, and blog.sh's own importer -- parses front matter
  # with a YAML parser, where an unquoted title containing a colon is a
  # syntax error and takes the whole post down with it.
  #
  # Three layers, outermost first: what every engine understands, what
  # some do, and what only this one does. The last lives under a single
  # `blogsh:` key so it cannot collide with a destination engine's own
  # vocabulary, and so `blog.sh -> blog.sh` is visibly a round-trip
  # rather than a lucky accident.
  def front_matter(post)
    meta = {}
    meta['title'] = post['title'].to_s
    meta['date'] = post['date'].to_s
    meta['slug'] = post['slug'].to_s
    tags = Array(post['tags']).map(&:to_s).reject(&:empty?)
    meta['tags'] = tags unless tags.empty?
    # Jekyll's own word for "not published yet", which is also what its
    # _drafts/ directory means -- said twice on purpose, since a tree
    # flattened by a converter loses the directory but keeps the key.
    meta['published'] = false if draft?(post)
    meta['type'] = 'page' if page?(post)
    meta['permalink'] = permalink(post)

    redirects = redirect_paths(post)
    # The key jekyll-redirect-from reads, in the shape it reads it: on a
    # Jekyll site with that plugin every address this post ever had goes
    # on answering, which is the difference between exporting data and
    # exporting a site.
    meta['redirect_from'] = redirects unless redirects.empty?

    %w[series series_part pinned hero toc].each do |key|
      meta[key] = post[key] unless post[key].nil?
    end

    native = native_keys(post)
    meta['blogsh'] = native unless native.empty?

    # line_width: -1 keeps a long title on one line -- folded across two,
    # it is still valid YAML but no longer something a person can read or
    # a converter reliably re-joins.
    "#{meta.to_yaml(line_width: -1)}---\n\n"
  end

  # Where the post lives on this site today, so the destination can keep
  # the same addresses. Mirrors post_path in build/build_blog.rb -- a
  # draft's token URL is deliberately not exported: it is a private
  # preview address, not a permalink.
  def permalink(post)
    return "/#{post['slug']}/" if page?(post)

    "/posts/#{date_of(post).year}/#{post['slug']}/"
  end

  # Both kinds of old address, merged: `redirect_from` is where the post
  # lived on the platform it came from, `former_slugs` where it lived on
  # this site before a rename. A destination engine has one mechanism for
  # both, so it gets both -- and the exact fields are preserved
  # separately under `blogsh:` so a re-import can tell them apart again.
  def redirect_paths(post)
    from = Array(post['redirect_from']).map(&:to_s)
    former = Array(post['former_slugs']).map { |entry| "/posts/#{entry}/" }
    (from + former).reject(&:empty?).uniq
  end

  # Everything the engine keeps that no other engine has a word for.
  # Written whole rather than selectively: this is the copy somebody
  # restores from, and a field left out here is a field lost for good.
  def native_keys(post)
    keys = {}
    %w[source former_slugs redirect_from unpublished_from mastodon_url
       bluesky_url bluesky_uri draft_token created_at scheduled
       state page].each do |key|
      keys[key] = post[key] unless post[key].nil?
    end
    keys
  end
end
