# frozen_string_literal: true

require 'cgi'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a Medium export -- the unpacked ZIP from Settings → Download
  # your information, which is just posts/*.html, one self-contained file
  # per post with the metadata encoded in microformat classes (.p-name,
  # .dt-published, .p-canonical, .e-content). Drafts are the files whose
  # name starts with draft_.
  #
  # The images are NOT in the export: every one hotlinks Medium's CDN, so
  # they download from there -- which works for as long as Medium serves
  # them, another reason not to postpone a migration.
  #
  # The canonical URL's trailing hex hash is the one stable thing Medium
  # gives a post (medium.com itself redirects any .../anything-hash to the
  # post), so it is the re-import identity here.
  class Medium
    attr_accessor :keep_permalinks

    def initialize(dir, keep_permalinks: false)
      @dir = dir
      @keep_permalinks = keep_permalinks
      @untagged = 0
      @comments = 0
    end

    def label
      "Medium export (#{File.basename(File.expand_path(@dir))})"
    end

    def total
      @total
    end

    def platform_tag
      'medium'
    end

    def each_item(&block)
      files = Dir.glob(File.join(@dir, 'posts', '*.html')).sort
      @total = files.size
      files.each(&block)
    end

    def map(path, media)
      html = File.read(path, encoding: 'utf-8')
      draft = File.basename(path).start_with?('draft_')
      canonical = anchor_href(html, 'p-canonical')

      slug, hash = identity(path, canonical, draft)
      return :no_identity if hash.nil?

      body = content_of(html)
      title = text_of(html[%r{<h1[^>]*class="[^"]*p-name[^"]*"[^>]*>(.*?)</h1>}m, 1])
      summary = text_of(html[%r{<section[^>]*class="[^"]*p-summary[^"]*"[^>]*>(.*?)</section>}m, 1])

      parsed = HtmlBlocks.parse(preprocess(body, title, summary))
      blocks = localize_images(parsed.blocks, media)
      return :empty if blocks.empty? && summary.empty?

      # Medium's export cannot tell a post from a response written under
      # someone else's article -- both are posts/*.html. The shape gives
      # it away (a published one-paragraph body with no image is almost
      # never an article), and a wrong guess costs least as a draft: the
      # text is kept, it just doesn't publish until a human looks.
      state = draft ? 'draft' : 'published'
      if state == 'published' && possible_comment?(blocks)
        state = 'draft'
        @comments += 1
      end

      summary_block = summary.empty? ? [] : [{ 'type' => 'text', 'text' => summary }]
      tags = tags_of(html)
      @untagged += 1 if tags.empty? && state == 'published'

      post = {
        'slug' => Slug.slugify(slug),
        'title' => title.empty? ? slug : title,
        'date' => date_of(html, path).iso8601,
        'state' => state,
        'tags' => tags,
        'content' => summary_block + blocks,
        'source' => {
          'platform' => 'medium',
          'account' => account_of(html),
          'post_url' => canonical.empty? ? nil : canonical,
          'original_id' => hash
        }.compact
      }
      if @keep_permalinks && state == 'published'
        origin = Permalinks.local_path(canonical)
        post['redirect_from'] = [origin] if origin
      end
      post
    end

    def postscript
      notes = []
      notes << I18n.t('import.note.medium_responses', count: @comments) if @comments.positive?
      notes << I18n.t('import.note.medium_untagged', count: @untagged) if @untagged.positive?
      notes.empty? ? nil : notes.join("\n  ")
    end

    private

    # slug-and-hash come from the canonical URL's last segment; a draft
    # has no canonical, but its filename carries the same pair.
    def identity(path, canonical, draft)
      if draft
        m = File.basename(path).match(/\Adraft_(.*)-([0-9a-f]+)\.html\z/)
        return [m[1], m[2]] if m
      end
      m = URI.parse(canonical).path.to_s.match(%r{([^/]*?)-([0-9a-f]+)\z})
      m ? [m[1], m[2]] : [nil, nil]
    rescue URI::InvalidURIError
      [nil, nil]
    end

    def content_of(html)
      # The footer follows the content and holds nothing to import; cutting
      # it first means the greedy match below safely ends at the section
      # that closes e-content.
      before_footer = html.split(/<footer[\s>]/).first.to_s
      before_footer[%r{<section[^>]*class="[^"]*e-content[^"]*"[^>]*>(.*)</section>}m, 1].to_s
    end

    def date_of(html, path)
      stamp = html[%r{<time[^>]*class="[^"]*dt-published[^"]*"[^>]*datetime="([^"]+)"}, 1]
      return Time.parse(stamp) if stamp

      # Drafts carry no published time; the file's own mtime is the export's
      # only honest answer to "when was this last worked on".
      File.mtime(path)
    rescue StandardError
      File.mtime(path)
    end

    def account_of(html)
      href = anchor_href(html, 'p-author')
      href[%r{/(@[^/"]+)}, 1] || href[%r{https?://([^/"]+)}, 1]
    end

    # The anchor is found first and its address read second, rather than
    # both in one pattern. HTML does not promise an attribute order, and
    # Medium's own exports write href BEFORE class -- so a pattern that
    # demanded class first matched nothing at all. That cost every
    # PUBLISHED post: no canonical address meant no id, and the post was
    # skipped as :no_identity. Drafts came through, because their id is
    # read from the file name, which is exactly why an export could look
    # like it half-worked. Verified against the fixture Ghost's own
    # medium-export tool ships:
    #   <a href="https://medium.com/@JoeBloggs/testpost-efefef12121212"
    #      class="p-canonical">
    # The class attribute carries more than one name ("p-author h-card"),
    # so the name is matched inside it rather than against the whole.
    def anchor_href(html, name)
      tag = html[/<a\b[^>]*class="[^"]*#{Regexp.escape(name)}[^"]*"[^>]*>/]
      tag ? tag[/href="([^"]*)"/, 1].to_s : ''
    end

    def tags_of(html)
      section = html[%r{<div[^>]*class="[^"]*p-tags[^"]*"[^>]*>(.*?)</div>}m, 1].to_s
      section.scan(%r{<a[^>]*>(.*?)</a>}m).flatten.map { |t| text_of(t) }.reject(&:empty?)
    end

    # What Medium bakes into the body that an import must not repeat: the
    # title again as the first heading, the summary again as a subtitle
    # heading, and the decorative divider that opens every post. Bookmark
    # cards (mixtapeEmbed) keep their durable part, the link. Code blocks
    # arrive as pre with the language in a data attribute and lines as
    # <br> -- normalized to what HtmlBlocks already reads.
    def preprocess(body, title, summary)
      body = body.gsub(%r{<div[^>]*class="[^"]*graf--mixtapeEmbed[^"]*"[^>]*>.*?</div>}m) do |card|
        url = card[%r{<a[^>]*href="([^"]+)"}, 1].to_s
        label = text_of(card[%r{<strong[^>]*class="[^"]*markup--strong[^"]*"[^>]*>(.*?)</strong>}m, 1])
        url.empty? ? '' : %(<p><a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(label.empty? ? url : label)}</a></p>)
      end
      body = body.gsub(%r{<hr[^>]*class="[^"]*section-divider[^"]*"[^>]*/?>}, '')
                 .gsub(%r{<div[^>]*class="[^"]*section-divider[^"]*"[^>]*>\s*<hr[^>]*/?>\s*</div>}m, '')
      body = body.gsub(%r{<(h[1-6]|blockquote)[^>]*>(.*?)</\1>}m) do |match|
        same_text?(text_of(Regexp.last_match(2)), title) || same_text?(text_of(Regexp.last_match(2)), summary) ? '' : match
      end
      body.gsub(%r{<pre[^>]*data-code-block-lang="([^"]+)"[^>]*>(.*?)</pre>}m) do
        lang = Regexp.last_match(1)
        code = Regexp.last_match(2).gsub(%r{<br\s*/?>}, "\n")
        %(<pre><code class="language-#{CGI.escapeHTML(lang)}">#{code}</code></pre>)
      end
    end

    # Curly quotes and spacing are the only differences between the <h1>
    # and its copy in the body -- normalize both sides before comparing.
    def same_text?(a, b)
      return false if b.to_s.empty?

      normalize(a) == normalize(b)
    end

    def normalize(text)
      text.to_s.tr('‘’“”', %q('' "")).gsub(/\s+/, ' ').strip.downcase
    end

    def possible_comment?(blocks)
      texts = blocks.count { |b| b['type'] == 'text' }
      blocks.none? { |b| b['type'] == 'image' } && texts <= 1 && blocks.size <= 1
    end

    def text_of(fragment)
      CGI.unescapeHTML(fragment.to_s.gsub(/<[^>]+>/, '')).gsub(/\s+/, ' ').strip
    end

    # Same contract as the other importers: download, measure, or lose the
    # one image rather than the post.
    def localize_images(blocks, media)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = block.dig('media', 0, 'url').to_s
        filename = url.start_with?('http') ? media.from_url(url) : nil
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end
  end
end
