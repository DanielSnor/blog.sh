# frozen_string_literal: true

require 'cgi'
require 'time'
require 'yaml'
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
    end

    def label
      "Markdown tree (#{File.basename(@dir)})"
    end

    def total
      @total
    end

    def platform_tag
      'jekyll'
    end

    def each_item(&block)
      posts = Dir.glob(File.join(@dir, '_posts', '**', '*.{md,markdown,html}'))
      drafts = Dir.glob(File.join(@dir, '_drafts', '**', '*.{md,markdown,html}'))
      # No _posts/ means this is not a Jekyll tree but a plain folder of
      # markdown -- a converter's output. Same shape, wider net.
      posts = Dir.glob(File.join(@dir, '**', '*.{md,markdown}')) if posts.empty? && drafts.empty?
      files = (posts + drafts).sort
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
      post
    end

    private

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

    # Markdown is the native tongue, with two dialect notes: image lines
    # point at files in THIS tree (MarkdownParser would treat them as
    # authoring uploads), so they ride through the parse as sentinels and
    # become blocks in localize(); and Liquid tags are Jekyll's, not
    # markdown's -- highlight becomes a code fence, the rest is dropped.
    def markdown_blocks(body)
      body = body.gsub(/\{%\s*highlight\s+(\S+)\s*%\}(.*?)\{%\s*endhighlight\s*%\}/m) do
        "\n```#{Regexp.last_match(1)}\n#{Regexp.last_match(2).strip}\n```\n"
      end
      body = body.gsub(/\{%[^%]*%\}/, '').gsub(/\{\{[^}]*\}\}/, '')
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
      filename = if src.start_with?('http://', 'https://')
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

    def slug_of(meta, path)
      explicit = meta['slug'] || meta['basename']
      return Slug.slugify(explicit.to_s) if explicit && !explicit.to_s.empty?

      base = File.basename(path).sub(/\.(md|markdown|html)\z/, '').sub(/\A\d{4}-\d{2}-\d{2}-/, '')
      # A Hugo page bundle is a directory with an index.md -- the
      # directory is the name.
      base = File.basename(File.dirname(path)) if base == 'index'
      Slug.slugify(base)
    end

    def item_date(meta, path)
      return Time.parse(meta['date'].to_s) if meta['date'] && !meta['date'].to_s.empty?

      if (m = File.basename(path).match(/\A(\d{4})-(\d{2})-(\d{2})-/))
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
