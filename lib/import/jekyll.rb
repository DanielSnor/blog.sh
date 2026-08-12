# frozen_string_literal: true

require 'cgi'
require 'time'
require 'yaml'
# For the run's postscript below -- the other adapters that speak in the
# summary require it the same way.
require_relative '../i18n'
require_relative '../slug'
require_relative '../markdown_parser'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a tree of markdown posts with front matter -- a Jekyll site
  # (_posts/ and _drafts/), a Hugo content/ directory, or any folder of
  # .md files a converter produced (Meddler's Medium output,
  # Substack2Markdown's, ...). The body IS blog.sh's native language, so
  # it goes through the same MarkdownParser that authoring uses -- no
  # HTML round-trip -- and .html bodies take the HtmlBlocks path instead.
  #
  # Unlike Ghost's Jekyll migrator, which downloads images from the live
  # site, the images here come from the tree itself: the archive works
  # for a site that died years ago.
  class Jekyll
    attr_accessor :keep_permalinks

    # PERMALINK is a pattern like "/:year/:month/:day/:title/" --
    # Jekyll's permalink config, which the tree itself does not reveal
    # post by post. Without one, only posts with an explicit front
    # matter permalink get a redirect.
    def initialize(dir, permalink: nil, keep_permalinks: false)
      @dir = File.expand_path(dir)
      @permalink = permalink
      @keep_permalinks = keep_permalinks
      @rearranged = 0
      @liquid_links = 0
    end

    # Said out loud when the run rearranged anything -- see
    # free_inline_images. An import may transform, but not quietly.
    def postscript
      notes = []
      notes << I18n.t('import.note.ssg_images_freed', count: @rearranged) if @rearranged.positive?
      notes << I18n.t('import.note.ssg_liquid_links_dropped', count: @liquid_links) if @liquid_links.positive?
      notes.empty? ? nil : notes.join("\n  ")
    end

    def label
      "Markdown tree (#{File.basename(@dir)})"
    end

    def total
      @total
    end

    # Nil for a post this engine wrote itself (see apply_own_keys): it
    # already knows where it came from, and a round-trip through export
    # and back must not leave a "jekyll" pill behind on every post.
    def platform_tag
      @own_post ? nil : 'jekyll'
    end

    def each_item(&block)
      posts = Dir.glob(File.join(@dir, '_posts', '**', '*.{md,markdown,html}'))
      drafts = Dir.glob(File.join(@dir, '_drafts', '**', '*.{md,markdown,html}'))
      # No _posts/ means either a plain folder of markdown -- a
      # converter's output -- or a site built entirely on collections
      # (_docs, _tutorials), which Jekyll allows and jekyll/jekyll's own
      # docs/ is. Same shape, wider net, minus the machinery.
      swept = posts.empty? && drafts.empty?
      posts = wider_net if swept
      files = (posts + drafts + (swept ? [] : root_pages)).sort
      @total = files.size
      files.each(&block)
    end

    def map(path, media)
      raw = File.read(path, encoding: 'utf-8')
      meta, body = front_matter(raw)
      return :bad_frontmatter if meta.nil?

      blocks = if path.end_with?('.html')
                 HtmlBlocks.parse(body).blocks
               else
                 markdown_blocks(body)
               end
      blocks = localize(blocks, media, path)
      return :empty if blocks.empty?

      draft = path.include?("#{File::SEPARATOR}_drafts#{File::SEPARATOR}") ||
              meta['published'] == false || meta['draft'] == true
      date = item_date(meta, path)
      slug = slug_of(meta, path)

      post = {
        'slug' => slug,
        'title' => meta['title'].to_s.empty? ? slug : meta['title'].to_s,
        'date' => date.iso8601,
        'state' => draft ? 'draft' : 'published',
        'tags' => tags_of(meta),
        'content' => blocks,
        'source' => {
          'platform' => 'jekyll',
          'account' => File.basename(@dir),
          'original_id' => path.delete_prefix("#{@dir}#{File::SEPARATOR}")
        }
      }
      if @keep_permalinks && !draft
        origin = origin_path(meta, slug, date)
        post['redirect_from'] = [origin] if origin
      end
      apply_own_keys(post, meta)
      post
    end

    private

    # Front matter this engine wrote itself. `./blog.sh export` writes
    # everything markdown has no word for under a single `blogsh:` key,
    # so a tree that came out of blog.sh can go back in whole -- the
    # series, the redirects, the announcement URLs, a draft's token,
    # and above all `source`, which is what makes a re-import land on
    # the same posts instead of doubling the archive. A tree from
    # anywhere else has no such key and nothing here fires.
    #
    # A whitelist rather than a merge: front matter is a file somebody
    # handed us, and a post is not a place to let arbitrary keys in.
    OWN_NESTED_KEYS = %w[source former_slugs redirect_from unpublished_from
                         mastodon_url bluesky_url bluesky_uri draft_token
                         created_at scheduled state page].freeze
    # The ones that sit flat, because a destination engine plausibly
    # understands them too -- Hugo has series, most engines have a pinned.
    OWN_FLAT_KEYS = %w[series series_part pinned hero toc].freeze

    def apply_own_keys(post, meta)
      own = meta['blogsh']
      # Read per post rather than per tree: a folder can hold both an
      # export and something somebody wrote by hand, and only the posts
      # that carry their own history should be treated as returning
      # home. platform_tag asks this too.
      @own_post = own.is_a?(Hash)

      OWN_FLAT_KEYS.each do |key|
        value = meta[key]
        post[key] = value unless value.nil?
      end
      # `type: page` is how a page is written -- the same reading
      # scripts/manage_post.rb gives it. Any other type is a content-type
      # override and passes through as one.
      type = meta['type'].to_s.strip
      if type == 'page' then post['page'] = true
      elsif !type.empty? then post['type'] = type
      end

      return unless own.is_a?(Hash)

      OWN_NESTED_KEYS.each do |key|
        value = own[key]
        post[key] = value unless value.nil?
      end
    end

    # Not writing: _site/ is what Jekyll BUILT (every page a second
    # time), public/ and resources/ are Hugo's, the rest is machinery or
    # somebody else's code. Cast over jekyll/jekyll's own docs/, the
    # undiscriminating glob imported the built copies, the template
    # fragments from _includes/ and the repository's readme -- all of it
    # published, all of it dated the day of the import, because a page
    # in a collection carries no date to fall back on.
    NOT_CONTENT = %w[_site _includes _layouts _data _sass _plugins .jekyll-cache .git
                     node_modules vendor public resources themes].freeze
    # The files a repository keeps for people, not readers. Only in the
    # root: _docs/readme.md is a page about something.
    NOT_A_POST = %w[readme license licence contributing changelog code_of_conduct authors].freeze

    # A Jekyll site keeps its pages as markdown in the ROOT -- about.md,
    # colophon.md -- and `./blog.sh export` writes them there for the
    # same reason. Without this they were the one thing a tree could
    # hold that the importer walked straight past, so a site exported
    # and imported back came home one page short.
    #
    # Only when _posts/ or _drafts/ turned something up: with neither,
    # wider_net has already swept the whole tree and would hand the same
    # files over twice. And only files, never directories -- a Hugo page
    # bundle in the root is a post, and comes in through wider_net.
    NOT_A_PAGE = %w[index home 404 feed rss atom sitemap search tags categories archive robots].freeze

    def root_pages
      Dir.glob(File.join(@dir, '*.{md,markdown}')).reject do |path|
        base = File.basename(path, '.*').downcase
        NOT_A_PAGE.include?(base) || NOT_A_POST.include?(base)
      end
    end

    # Markdown only, deliberately, even though a tree WITH _posts/ reads
    # .html as well. This net is cast over a directory nobody has
    # vouched for, and an .html file in one is far more often a rendered
    # page than a post: pointed at a server backup it turned a scan of
    # nothing into 3,237 items, and pointed at a Jekyll site it made
    # posts out of 404.html and the feed. The narrower net loses the
    # rare .html post in a folder with no _posts/; the wider one loses
    # the author's confidence in the whole import.
    def wider_net
      Dir.glob(File.join(@dir, '**', '*.{md,markdown}')).reject do |path|
        parts = path.delete_prefix("#{@dir}#{File::SEPARATOR}").split(File::SEPARATOR)
        parts[0..-2].any? { |dir| NOT_CONTENT.include?(dir) } ||
          (parts.length == 1 && NOT_A_POST.include?(File.basename(parts[0], '.*').downcase))
      end
    end

    # YAML between --- fences, or Hugo's TOML between +++ -- the TOML
    # reader is a deliberate subset (key = value, arrays, one level),
    # which is what front matter in the wild actually uses.
    def front_matter(raw)
      if (m = raw.match(/\A---\s*\n(.*?)\n---\s*\n?/m))
        [YAML.safe_load(m[1], permitted_classes: [Date, Time]) || {}, m.post_match]
      elsif (m = raw.match(/\A\+\+\+\s*\n(.*?)\n\+\+\+\s*\n?/m))
        [toml_subset(m[1]), m.post_match]
      else
        [{}, raw]
      end
    rescue Psych::Exception
      [nil, nil]
    end

    def toml_subset(text)
      text.each_line.with_object({}) do |line, out|
        next unless (m = line.match(/\A\s*([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*\z/))

        key, value = m[1], m[2]
        out[key] = case value
                   when /\A\[(.*)\]\z/ then Regexp.last_match(1).split(',').map { |v| v.strip.delete('"\'') }
                   when 'true' then true
                   when 'false' then false
                   else value.delete('"\'')
                   end
      end
    end

    # Markdown is the native tongue, with three dialect notes: reference
    # links are markdown this parser does not speak, so they are folded
    # into inline ones first; Liquid tags are Jekyll's, not markdown's --
    # highlight becomes a code fence, the rest is dropped; and image
    # lines point at files in THIS tree (MarkdownParser would treat them
    # as authoring uploads), so they ride through the parse as sentinels
    # and become blocks in localize().
    def markdown_blocks(body)
      body = resolve_references(body)
      body = liquid_free(body)
      body = outside_fences(body) { |prose| join_lazy_list_lines(prose) }
      body = free_inline_images(body)
      body = body.gsub(MarkdownParser::IMAGE_RE) do
        "@@ssg-image:#{CGI.escape(Regexp.last_match(2).strip)}:#{CGI.escape(Regexp.last_match(1).to_s)}@@"
      end
      # Line-anchored form ([ \t], NOT \s -- \s eats the newlines and
      # with them the paragraph break after the image).
      body = body.gsub(/^!\[([^\]]*)\]\(([^)"]+?)(?:[ \t]+"[^"]*")?\)[ \t]*$/) do
        "@@ssg-image:#{CGI.escape(Regexp.last_match(2).strip)}:#{CGI.escape(Regexp.last_match(1).to_s)}@@"
      end
      blocks, = MarkdownParser.parse_body(body, nil)
      blocks
    end

    # Hands BODY to the block a piece at a time, skipping fenced code: a
    # fence is verbatim, so a reference link, a Liquid tag or a wrapped
    # line inside one is somebody's EXAMPLE of markdown and must arrive
    # exactly as written. An unterminated fence runs to the end, the same
    # reading MarkdownParser gives it.
    def outside_fences(body)
      out = +''
      prose = +''
      fence = nil
      body.each_line do |line|
        marker = line.strip[/\A`{3,}/]
        if fence
          out << line
          fence = nil if marker && marker.length >= fence.length && line.strip == marker
        elsif marker
          out << yield(prose) << line
          prose = +''
          fence = marker
        else
          prose << line
        end
      end
      out << yield(prose)
    end

    # --- reference links -------------------------------------------------

    # [text][label] with [label]: url written somewhere else is ordinary
    # markdown that MarkdownParser does not know. Half of jekyll/jekyll's
    # own release notes use it, and left alone the brackets were
    # published verbatim while the definitions arrived as a paragraph of
    # body text reading "[roadmap]: https://...". Folded into inline
    # links here, before Liquid is stripped -- a definition whose address
    # is Liquid has to still be recognizable as Liquid when it gets there.
    REF_DEF = /\A[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*(\S.*?)[ \t]*\z/
    # The code-span alternative comes first so that `[a][b]` inside
    # backticks is left as the example it is. The trailing lookahead
    # keeps an ordinary inline [text](url) out: without it, a [text]
    # whose words happen to match a defined label grew a second address.
    REF_USE = /(`+[^`]*`+)|(!?)\[([^\]\[\n]+)\](?:\[([^\]\n]*)\])?(?![(\[])/

    def resolve_references(body)
      defs = {}
      body = outside_fences(body) { |prose| take_reference_defs(prose, defs) }
      return body if defs.empty?

      outside_fences(body) { |prose| apply_references(prose, defs) }
    end

    # Only a paragraph made up of nothing BUT definitions is taken --
    # that is how they are written (a block of their own at the foot of
    # the post), and it means a line of prose that merely starts with a
    # bracket cannot be mistaken for one and deleted.
    def take_reference_defs(text, defs)
      text.split(/(\n[ \t]*\n)/).map do |chunk|
        lines = chunk.split("\n").reject { |line| line.strip.empty? }
        next chunk if lines.empty?

        found = lines.map { |line| REF_DEF.match(line) }
        next chunk unless found.all?

        found.each { |m| defs[m[1].strip.downcase] ||= reference_url(m[2]) }
        ''
      end.join
    end

    # The address is the first word -- what may follow it is a title in
    # quotes, not part of the link. Liquid is taken whole instead: it
    # holds spaces ({% post_url 2013-05-06-jekyll-1-0-0-released %}) and
    # liquid_free below needs to see all of it to know the address is
    # unusable.
    def reference_url(value)
      liquid = value[/\A(?:\{%[^%]*%\}|\{\{[^}]*\}\})\S*/]
      return liquid if liquid

      value[/\A\S+/].to_s.delete_prefix('<').delete_suffix('>')
    end

    def apply_references(text, defs)
      text.gsub(REF_USE) do
        m = Regexp.last_match
        next m[0] if m[1] # a code span

        label = m[4].to_s.strip.empty? ? m[3] : m[4]
        url = defs[label.strip.downcase]
        next "#{m[2]}[#{m[3]}](#{url})" if url
        # [text][label] with no such label is a broken reference. The
        # words were meant to be read; the brackets were not.
        next "#{m[2]}#{m[3]}" if m[4]

        m[0] # a plain [bracketed] phrase, not a reference at all
      end
    end

    # --- Liquid ----------------------------------------------------------

    # {% raw %} is the author saying "print this, do not run it", and
    # what it wraps is almost always an EXAMPLE of Liquid -- precisely
    # the text the blanket strip below eats. It ate `{{ page.name }}` out
    # of Jekyll's own release notes and left an empty code span, an odd
    # number of backticks, and the list around it collapsed into one
    # paragraph.
    RAW_BLOCK = /\{%\s*raw\s*%\}\n?(.*?)\n?\{%\s*endraw\s*%\}/m
    LIQUID = /\{%[^%]*%\}|\{\{[^}]*\}\}/
    # site.baseurl and site.url are this very site's own root, spelled
    # the way Jekyll wants it spelled: what is left after removing it is
    # still an address that resolves. Every other variable pointed
    # somewhere else entirely.
    SITE_ROOT = /\A\{\{\s*site\.(?:baseurl|url)\s*\}\}/

    def liquid_free(body)
      out = +''
      rest = body
      while (m = RAW_BLOCK.match(rest))
        out << strip_liquid(m.pre_match) << m[1]
        rest = m.post_match
      end
      out << strip_liquid(rest)
    end

    # The first word after "highlight" is the language; what may follow
    # it are the tag's other arguments, which Jekyll documents
    # ({% highlight ruby linenos %}, mark_lines="1 2"). Insisting on the
    # language alone let those blocks fall through to the blanket strip,
    # and a code sample came out as prose: indentation gone, the line
    # breaks turned into spaces, a blank line inside it splitting the
    # sample into several paragraphs.
    #
    # The body may not contain another opening tag, so a block whose
    # {% endhighlight %} was never written stops at itself instead of
    # reaching forward to the next block's closing tag and swallowing
    # everything a reader had in between.
    def strip_liquid(text)
      text = text.gsub(%r{\{%\s*highlight\s+(\S+)[^%]*%\}((?:(?!\{%\s*highlight\b).)*?)\{%\s*endhighlight\s*%\}}m) do
        "\n```#{Regexp.last_match(1)}\n#{Regexp.last_match(2).strip}\n```\n"
      end
      text = drop_liquid_addresses(text)
      text.gsub(/\{%[^%]*%\}/, '').gsub(/\{\{[^}]*\}\}/, '')
    end

    # The one place a blanket strip does damage rather than harm: it
    # leaves the REST of the path standing, so
    # [check the issues]({{ site.repository }}/issues) turned into a
    # working link to /issues -- of the NEW blog. A dead link gets
    # noticed and fixed; a live wrong one never does. Images are left to
    # the strip on purpose: their Liquid is a path prefix, and what
    # remains is a file that really is in this tree.
    def drop_liquid_addresses(text)
      text.gsub(/(?<!!)\[([^\]\n]*)\]\(([^)\n]*)\)/) do
        whole, label, url = Regexp.last_match.values_at(0, 1, 2)
        next whole unless url.match?(LIQUID)

        rest = url.sub(SITE_ROOT, '')
        next "[#{label}](#{rest})" unless rest.match?(LIQUID) || rest.strip.empty?

        @liquid_links += 1
        label
      end
    end

    # --- lists -----------------------------------------------------------

    # kramdown hard-wraps at column ~120, so a long list item continues
    # on the next line with no bullet in front of it -- a lazy
    # continuation, ordinary markdown. parse_list refuses a paragraph it
    # cannot read as a list end to end, so ONE wrapped item turned the
    # whole list into a paragraph with the dashes showing. Two of the ten
    # posts in jekyll/jekyll's own docs do it.
    #
    # Only a paragraph that OPENS with a list item is touched: text
    # followed by a list is a different shape with a different answer,
    # and joining there would eat the text.
    def join_lazy_list_lines(text)
      text.split(/(\n[ \t]*\n)/).map do |chunk|
        lines = chunk.split("\n", -1)
        next chunk unless lines.length > 1 && list_item?(lines.first)

        lines.each_with_object([]) do |line, out|
          if out.empty? || line.strip.empty? || list_item?(line) || interrupts_list?(line)
            out << line
          else
            out[-1] = "#{out[-1]} #{line.strip}"
          end
        end.join("\n")
      end.join
    end

    def list_item?(line)
      stripped = line.strip
      MarkdownParser::UL_ITEM_RE.match?(stripped) || MarkdownParser::OL_ITEM_RE.match?(stripped)
    end

    # Markdown lets these end a paragraph without a blank line before
    # them, so they are a new block, not the tail of the item above.
    def interrupts_list?(line)
      line.match?(/\A[ \t]*(?:\#{1,6}[ \t]|>|\||`{3,}|-{3,}[ \t]*\z|_{3,}[ \t]*\z)/)
    end

    # An image the schema cannot place: one sitting inside a line of text
    # rather than alone on its own. The parser ABORTS on those, which is
    # right when you are saving a post you just wrote -- it stops you
    # losing a picture and points at the line. It is wrong here: nobody
    # importing somebody else's site wrote that line, cannot fix it in the
    # archive, and one such paragraph used to take the whole run down with
    # it. A real Hugo export of 77 posts had 23 of them across 11 files --
    # 14% of the site, and none of the other 66 posts imported either.
    #
    # None of the shapes are exotic. Every WordPress-to-Hugo conversion
    # writes "![](photo.png)*caption*"; every README puts badges in a list;
    # screenshots end sentences. So they are rearranged the way a person
    # would rearrange them, rather than refused:
    #
    #   [![alt](img)](href)  ->  [alt](href)      a badge: keep the LINK,
    #                                             drop the decoration
    #   [![](img)](href)     ->  ![](img)         a thumbnail: keep the
    #                                             PICTURE, drop the
    #                                             click-through
    #   text ![](img) text   ->  text / img / text, each on its own line
    #
    # The count rides back to the caller so the run can say it happened --
    # a silent rewrite of somebody's archive is exactly what an import
    # must not do.
    LINKED_IMAGE = /\[!\[([^\]]*)\]\(([^)\s]+)[^)]*\)\]\(([^)\s]+)[^)]*\)/
    INLINE_IMAGE = /(?<!\\)!\[[^\]]*\]\([^)\s]+[^)]*\)/

    def free_inline_images(body)
      body = body.gsub(LINKED_IMAGE) do
        alt = Regexp.last_match(1).to_s.strip
        img = Regexp.last_match(2)
        href = Regexp.last_match(3)
        @rearranged += 1
        # With alt text the link can speak for itself ("Google Play");
        # without it the picture is the only thing there is to keep.
        alt.empty? ? "\n\n![](#{img})\n\n" : "[#{alt}](#{href})"
      end

      body.split(/\n[ \t]*\n/).map { |para| split_around_images(para) }.join("\n\n")
    end

    def split_around_images(para)
      # Code spans first: "`![x](y)`" is an example of the syntax, not an
      # image, and the parser masks them for the same reason.
      return para unless para.gsub(/`[^`]*`/m, '`x`').match?(INLINE_IMAGE)
      return para if para.strip.match?(/\A#{INLINE_IMAGE.source}\z/)

      pieces = []
      rest = para
      while (m = INLINE_IMAGE.match(rest))
        before = m.pre_match
        pieces << before unless before.strip.empty?
        pieces << m[0]
        rest = m.post_match
        @rearranged += 1
      end
      pieces << rest unless rest.strip.empty?
      # A list whose item ended in a screenshot keeps its bullet and the
      # picture follows it -- the image was last in the item anyway, so
      # nothing changes order.
      pieces.map(&:strip).join("\n\n")
    end

    SENTINEL = /@@ssg-image:([^:@]*):([^@]*)@@/

    def localize(blocks, media, post_path)
      blocks.filter_map do |block|
        if block['type'] == 'text' && (m = block['text'].to_s.strip.match(/\A#{SENTINEL}\z/))
          image_block(CGI.unescape(m[1]), CGI.unescape(m[2]), media, post_path)
        elsif block['type'] == 'image'
          # From the HtmlBlocks path: the URL is still the tree's own.
          image_block(block.dig('media', 0, 'url').to_s, nil, media, post_path)
        else
          block
        end
      end
    end

    # A root-relative path is looked up in the tree, a relative one next
    # to the post, an absolute URL downloaded -- in that order of
    # likelihood for a static site's own images.
    def image_block(src, alt, media, post_path)
      # A data: URI is the image itself, inline -- nothing to fetch,
      # nothing on disk, and no block form for inline bytes here. Dropped
      # quietly and without a number: handed to from_file it showed up in
      # the summary as a missing file, base64 body and all.
      return nil if src.start_with?('data:')

      # Protocol-relative means "the page's scheme", and the page is
      # long gone -- assume https, as a browser on an https page does.
      src = "https:#{src}" if src.start_with?('//')

      # Any scheme, not just http(s): an ftp: or mailto: src is no path
      # in this tree, and joining it onto @dir named a local file the
      # archive never had. from_url's failure line tells the real story
      # -- a remote resource that could not be fetched.
      filename = if src.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
                   media.from_url(src)
                 else
                   local = src.start_with?('/') ? File.join(@dir, src) : File.expand_path(src, File.dirname(post_path))
                   # Unconditionally: from_file spends the number and records
                   # the miss itself. Stat-ing here instead made numbering
                   # depend on which files happened to be present.
                   media.from_file(local)
                 end
      return nil unless filename

      entry = { 'url' => filename }
      width, height = media.dimensions(filename)
      entry['width'] = width if width
      entry['height'] = height if height
      block = { 'type' => 'image', 'media' => [entry] }
      block['caption'] = alt unless alt.to_s.empty?
      block
    end

    # Jekyll pads neither the month nor the day when it reads a filename,
    # and exports in the wild are written both ways
    # (2021-9-1-alt-date-format.md). Insisting on two digits missed the
    # date AND the prefix in the slug, so the post arrived called
    # "2021-9-1-alt-date-format", dated the moment of the import, filed
    # under this year.
    DATED_NAME = /\A(\d{4})-(\d{1,2})-(\d{1,2})-/

    def slug_of(meta, path)
      explicit = meta['slug'] || meta['basename']
      return Slug.slugify(explicit.to_s) if explicit && !explicit.to_s.empty?

      base = File.basename(path).sub(/\.(md|markdown|html)\z/, '').sub(DATED_NAME, '')
      # A Hugo page bundle is a directory with an index.md -- the
      # directory is the name.
      base = File.basename(File.dirname(path)) if base == 'index'
      Slug.slugify(base)
    end

    def item_date(meta, path)
      return Time.parse(meta['date'].to_s) if meta['date'] && !meta['date'].to_s.empty?

      if (m = File.basename(path).match(DATED_NAME))
        # Noon, not midnight: a date-only value read at UTC midnight can
        # land on yesterday in the site's timezone.
        return Time.local(m[1].to_i, m[2].to_i, m[3].to_i, 12)
      end
      File.mtime(path)
    rescue ArgumentError
      File.mtime(path)
    end

    def tags_of(meta)
      %w[tags tag categories category].flat_map do |key|
        value = meta[key]
        case value
        when Array then value.map(&:to_s)
        when String then value.split(/[,\s]+/)
        else []
        end
      end.map(&:strip).reject(&:empty?).uniq { |t| t.downcase }
    end

    # The front matter's own permalink wins, then the pattern given at
    # the door. No pattern, no redirect -- a guessed address would 404
    # with a straight face.
    def origin_path(meta, slug, date)
      explicit = meta['permalink'] || meta['url']
      return explicit.to_s if explicit && !explicit.to_s.empty?
      return nil unless @permalink

      @permalink.gsub(':year', format('%04d', date.year))
                .gsub(':month', format('%02d', date.month))
                .gsub(':day', format('%02d', date.day))
                .gsub(':title', slug)
                .gsub(':slug', slug)
    end
  end
end
