# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require 'yaml'
require_relative 'markdown_writer'
require_relative 'embed'
require_relative 'file_size'
require_relative 'post_address'
require_relative 'path_glob'

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
    PathGlob.under(dir, '*', '*.json').sort.filter_map do |path|
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
    PostAddress.page?(post)
  end

  def truthy?(value)
    return false if value.nil? || value == false

    !%w[false no 0].include?(value.to_s.strip.downcase)
  end

  # --- one post ------------------------------------------------------------

  def export_post(post, root:, target:, taken:, dry_run:, result:)
    year = post['__year'].to_s
    slug = post['slug'].to_s
    dir = dir_for(post)
    name = file_name(post, slug, dir, taken, result)
    path = File.join(target, *dir, name)
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

  def file_name(post, slug, dir, taken, result)
    base = if page?(post) || draft?(post)
             slug
           else
             "#{date_of(post).strftime('%Y-%m-%d')}-#{slug}"
           end
    # Slugs are unique across the archive, so this is a belt-and-braces
    # count rather than an expected case -- but two files silently
    # becoming one is the sort of loss an export must never take. Keyed
    # by directory as well as name: a draft and a page may share a slug
    # without sharing a file, and renaming one of those would be a
    # collision reported where there is none.
    name = base
    suffix = 1
    while taken[File.join(*dir, name)]
      suffix += 1
      name = "#{base}-#{suffix}"
      result.collisions += 1
    end
    taken[File.join(*dir, name)] = true
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
    PathGlob.under(source, '*').sort.each do |file|
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
  # Video and audio skip the markdown path even though the writer HAS
  # syntax for them, because that syntax is this engine's own: `!![cap](url)`
  # is, to CommonMark -- which is what Jekyll, Hugo and Eleventy read -- a
  # literal "!" followed by an IMAGE. Exported that way, a YouTube video
  # renders on the destination site as an exclamation mark and a broken
  # image, and re-importing the tree fetched YouTube's HTML page and filed
  # it in the archive as `02.jpg`. Caught against a real 118-post archive;
  # no fixture would have shown it, because both ends were ours.
  #
  # An attachment is here for the same reason, one step further out. Its
  # markdown form is `[label](file.pdf)` with a BARE filename -- that is
  # what tells the parser an attachment from an ordinary link -- and the
  # export has to write the path it really has, `/assets/<year>/<slug>/`.
  # Read back, that is no longer a filename, so the block came home as a
  # paragraph with a link in it: the label, the size and the block type
  # gone, and the file itself left behind in the tree because nothing
  # claimed it. The HTML form loses none of that, and a download link is
  # what the block means on the destination site anyway.
  HTML_ONLY = %w[video audio link file].freeze

  def render_blocks(blocks, media_rel)
    fallbacks = Hash.new(0)
    parts = Array(blocks).map do |block|
      type = block['type'].to_s
      unless HTML_ONLY.include?(type)
        rendered = MarkdownWriter.blocks_to_markdown([block], media_rel)
        next rendered unless rendered.strip.empty?

        # An empty text block is a spacer: the build renders <p></p>, which
        # shows nothing, so the writer producing nothing for it is the
        # right answer rather than "markdown has no syntax for this". It
        # went out as a VISIBLE <pre> box holding its own JSON, on a page
        # where the author had asked for a gap -- and was counted in the
        # summary among the blocks markdown could not express.
        #
        # The comment still goes, with no HTML under it: it costs one line
        # every engine drops on the floor, and it is what brings the
        # spacer home again on a re-import.
        next block_comment(block, media_rel) if spacer?(block)
      end

      fallbacks[type] += 1
      "#{block_comment(block, media_rel)}\n#{html_fallback(block, media_rel)}"
    end
    [parts.reject { |p| p.to_s.empty? }.join("\n\n"), fallbacks]
  end

  # A text block with nothing in it -- what the author gets by leaving a
  # blank line where a paragraph would be.
  def spacer?(block)
    block['type'].to_s == 'text' && block['text'].to_s.strip.empty?
  end

  # The block itself, in a comment above its HTML. Every engine drops an
  # HTML comment on the floor, so the destination site is unaffected --
  # and Import::Jekyll reads it back, which is what lets a video survive
  # the trip out and home again instead of arriving as a paragraph of
  # markup. No blank line between the two: that keeps comment and markup
  # a single HTML block to any markdown parser.
  #
  # Media paths are rewritten to where they are IN THE EXPORT, so the
  # importer can find the file the block names.
  #
  # "--" is escaped as a JSON string escape (still the same string to any
  # JSON reader): a caption containing "-->" would otherwise close the
  # comment early and spill markup into the page.
  def block_comment(block, media_rel)
    json = JSON.generate(with_export_paths(block, media_rel)).gsub('--', '-\\u002d')
    "<!-- blogsh:block #{json} -->"
  end

  def with_export_paths(block, media_rel)
    copy = block.dup
    %w[media poster].each do |key|
      entries = copy[key]
      next unless entries.is_a?(Array)

      copy[key] = entries.map do |entry|
        entry.is_a?(Hash) && entry['url'] ? entry.merge('url' => File.join(media_rel, entry['url'].to_s)) : entry
      end
    end
    copy
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
  def html_fallback(block, media_rel)
    case block['type'].to_s
    when 'link'
      title = escape_html((block['title'] || block['url']).to_s)
      description = escape_html(block['description'].to_s)
      link = escape_html(block['url'].to_s)
      %(<p class="link-block"><a href="#{link}"><strong>#{title}</strong></a><br>#{description}</p>)
    when 'file' then file_html(block, media_rel)
    when 'video', 'audio' then player_html(block, media_rel)
    else
      # What the build does with a block type it does not know: show it
      # rather than swallow it.
      "<pre>#{escape_html(block.to_json)}</pre>"
    end
  end

  # The build's file card, without the icon and the arrow that are only
  # shapes in this site's stylesheet. `download` stays: it is the whole
  # difference between an attachment and a link, and every browser reads
  # it. The size rides along as text for the reason the block carries it
  # at all -- so the page can say what a click costs -- and is left out
  # when nothing knows it, rather than printed as "0 B".
  #
  # Falls through to the <pre> when there is no file to point at: a block
  # counted as "written as HTML" that wrote nothing would be a lie told
  # by the summary itself, the same rule player_html follows.
  def file_html(block, media_rel)
    file = (block['media'] || []).first
    return "<pre>#{escape_html(block.to_json)}</pre>" unless file.is_a?(Hash) && !file['url'].to_s.empty?

    href = escape_html(File.join(media_rel, file['url'].to_s))
    label = block['label'].to_s.empty? ? File.basename(file['url'].to_s) : block['label'].to_s
    size = FileSize.human(file['size'])
    %(<p class="file-block"><a href="#{href}" download>#{escape_html(label)}</a>) +
      (size ? " (#{escape_html(size)})" : '') + '</p>'
  end

  # The markup the build renders, minus what only means something inside
  # this site's stylesheet: a local file becomes the HTML5 element
  # pointing into assets/, YouTube and the platforms Embed knows become
  # the player's iframe, and an address nothing recognises stays a link
  # -- the same courtesy the build shows. Wrapped in a <figure> when the
  # block has a caption, so the words under it survive too.
  #
  # Falls through to the <pre> when there is nothing at all to point at:
  # a block counted as "written as HTML" that wrote nothing would be a
  # lie told by the summary itself.
  def player_html(block, media_rel)
    file = (block['media'] || []).first
    id = block['youtube_id'].to_s
    inner =
      if file
        src = escape_html(File.join(media_rel, file['url'].to_s))
        element = block['type'].to_s == 'audio' ? 'audio' : 'video'
        %(<#{element} controls preload="metadata" src="#{src}"></#{element}>)
      elsif !block['embed_html'].to_s.strip.empty?
        block['embed_html']
      elsif !id.empty?
        # youtube-nocookie, as the build uses: the same player without
        # tracking cookies until the visitor presses play.
        %(<iframe src="https://www.youtube-nocookie.com/embed/#{escape_html(id)}" ) +
          %(title="YouTube" frameborder="0" loading="lazy" allowfullscreen></iframe>)
      elsif (src = Embed.src(block))
        %(<iframe src="#{escape_html(src)}" frameborder="0" loading="lazy" allowfullscreen></iframe>)
      elsif !block['url'].to_s.empty?
        %(<a href="#{escape_html(block['url'])}">#{escape_html(block['url'])}</a>)
      end
    return "<pre>#{escape_html(block.to_json)}</pre>" if inner.nil?

    caption = block['caption'].to_s.strip
    caption.empty? ? inner : "<figure>#{inner}<figcaption>#{escape_html(caption)}</figcaption></figure>"
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
    # `page` is a type in the front matter's vocabulary; any other type is a
    # content-type override the author set by hand, and it is a DECISION
    # rather than a description -- ContentType.dominant honours it above its
    # own scan of the blocks. Left out, a post the author filed as a photo
    # despite carrying mostly text came home a text post and moved to a
    # different /type/ listing, silently, since nothing about it looked
    # wrong. The importer has always read this key; only the export was
    # quiet about it.
    meta['type'] = page?(post) ? 'page' : post['type'].to_s.strip
    meta.delete('type') if meta['type'].to_s.empty?
    meta['permalink'] = permalink(post)

    redirects = redirect_paths(post)
    # The key jekyll-redirect-from reads, in the shape it reads it: on a
    # Jekyll site with that plugin every address this post ever had goes
    # on answering, which is the difference between exporting data and
    # exporting a site.
    meta['redirect_from'] = redirects unless redirects.empty?

    %w[series series_part pinned hero toc unlisted].each do |key|
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
    # Recorded because it CANNOT be, which is the whole point. The outer
    # `title:` is flattened to '' for engines that have no concept of a post
    # without one, and an importer then cannot tell "this post has no title"
    # from "this tree came from an engine that writes none" -- so it does the
    # sensible thing and substitutes the slug. On the archive this was measured
    # against that is 2752 of 4367 pages coming home with a machine slug where
    # their name used to be, undoing the naming outright. `unless nil?` above
    # cannot say this; a flag can.
    keys['untitled'] = true if post['title'].nil?
    sources = media_sources(post)
    keys['media_src'] = sources unless sources.empty?
    keys
  end

  # Exported filename -> the address the file was fetched from. The one
  # thing about a media file that cannot be measured back out of it: an
  # importer re-reads the width and the height from the bytes, but nothing
  # in a JPEG says where it was downloaded. Dropped here, the tree would
  # come home unable to say which of its files the archive already has --
  # and the next import would fetch every one of them again, which is the
  # exact loss this key was added to prevent.
  #
  # A flat map rather than a key per block, because it has to serve both
  # kinds of block: video, audio and attachments ride home inside the
  # `blogsh:block` comment with their entries intact, but an image is
  # written as plain markdown and arrives back as nothing but a path.
  def media_sources(post)
    map = {}
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      %w[media poster].each do |key|
        entries = block[key]
        next unless entries.is_a?(Array)

        entries.each do |entry|
          next unless entry.is_a?(Hash)

          name = entry['url'].to_s
          src = entry['src'].to_s
          map[name] = src unless name.empty? || src.empty?
        end
      end
    end
    map
  end
end
