# frozen_string_literal: true

require 'cgi'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative '../path_glob'
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
      files = PathGlob.under(@dir, 'posts', '*.html').sort
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
          'account' => account_of(html) || export_account,
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
      name = File.basename(path)
      if draft
        m = name.match(/\Adraft_(.*)-([0-9a-f]+)\.html\z/)
        return [m[1], m[2]] if m
      end
      pair = canonical_pair(canonical)
      return pair if pair

      # The canonical address is not always profile-slug-hash. Medium
      # writes some posts as plain profile and id (.../@user/1234567890),
      # and then there is no slug in the address to read. The file name
      # still carries the pair -- published files are named
      # 2018-08-11_slug-hash.html -- so it stands in, the same way it
      # already does for drafts. Without this the post was dropped as
      # :no_identity: a PUBLISHED post, gone from the archive with no
      # sign it had ever been there. Ghost's own Medium tool falls back
      # to the file name here for the same reason.
      m = name.match(/_(.*)-([0-9a-f]+)\.html\z/)
      m ? [m[1], m[2]] : [nil, nil]
    end

    def canonical_pair(canonical)
      m = URI.parse(canonical).path.to_s.match(%r{([^/]*?)-([0-9a-f]+)\z})
      m && [m[1], m[2]]
    rescue URI::InvalidURIError
      nil
    end

    def content_of(html)
      # The footer follows the content and holds nothing to import; cutting
      # it first means the greedy match below safely ends at the section
      # that closes e-content.
      before_footer = html.split(/<footer[\s>]/).first.to_s
      before_footer[%r{<section[^>]*class="[^"]*e-content[^"]*"[^>]*>(.*)</section>}m, 1].to_s
    end

    # The published time Medium wrote into the post is the best answer,
    # the day in the file name the second best, the file itself the last.
    def date_of(html, path)
      stamp = html[%r{<time[^>]*class="[^"]*dt-published[^"]*"[^>]*datetime="([^"]+)"}, 1]
      return Time.parse(stamp) if stamp

      # Drafts carry no published time and no day in the name; the file's
      # own mtime is the export's only honest answer to "when was this
      # last worked on".
      named_date(path) || File.mtime(path)
    rescue StandardError
      named_date(path) || File.mtime(path)
    end

    # Published files are named 2018-08-11_slug-hash.html, and real
    # exports do hold published posts with no <time class="dt-published">
    # in them at all (the fixture Ghost's own medium-export tool ships,
    # no-date-post.html, is one). Without the name such a post took the
    # mtime, which after unpacking a ZIP is when the export was made: an
    # article from 2018 then sat at the top of the archive, filed under
    # the year of the export and missing from its own -- and every such
    # post got the same minute, so their order was a coin toss. Drafts
    # have no day in the name, so they fall through to the mtime.
    def named_date(path)
      m = File.basename(path).match(/\A(\d{4})-(\d{2})-(\d{2})_/)
      return nil unless m

      # Noon, not midnight: a date-only value read at UTC midnight can
      # land on yesterday in the site's timezone.
      Time.local(m[1].to_i, m[2].to_i, m[3].to_i, 12)
    rescue ArgumentError
      nil
    end

    # The handle this whole export belongs to. A DRAFT carries no author
    # anchor -- Medium writes one only on a published post -- so `account`
    # fell out of its source record, and PostWriter.source_key is nil
    # without one: re-running the identical command over the identical
    # export wrote slug-2, slug-3, slug-4, against the promise the tool
    # prints itself ("posts are matched on their source id, never
    # duplicated"). An export is one person's, so the handle its published
    # posts carry is its drafts' too. Read once, from the first file that
    # names it, in the same order every run.
    def export_account
      return @export_account if defined?(@export_account)

      @export_account = PathGlob.under(@dir, 'posts', '*.html').sort.lazy.filter_map do |path|
        account_of(File.read(path, encoding: 'utf-8'))
      end.first
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

    # The tag list is whatever element in the footer carries class
    # p-tags. Real exports write it as a paragraph ("<p class="p-tags">
    # Tagged in <a class="p-tag">Things</a>"), so a pattern that demanded
    # a <div> found nothing at all and every tag was lost -- silently,
    # because "no tags" is a legitimate answer. The element is therefore
    # matched by its class and closed by a backreference, not by name.
    def tags_of(html)
      section = html[%r{<(div|p)[^>]*class="[^"]*p-tags[^"]*"[^>]*>(.*?)</\1>}m, 2].to_s
      section.scan(%r{<a[^>]*>(.*?)</a>}m).flatten.map { |t| text_of(t) }.reject(&:empty?)
    end

    # What Medium bakes into the body that an import must not repeat: the
    # title again as the first heading, the summary again as a subtitle
    # heading, and the decorative divider that opens every post. Bookmark
    # cards (mixtapeEmbed) keep their durable part, the link. Code blocks
    # arrive as pre with the lines as <br> and the language, if any, in a
    # data attribute -- normalized to what HtmlBlocks already reads.
    # Both shapes Medium has written it in, in one pattern.
    DIVIDER = %r{<div[^>]*class="[^"]*section-divider[^"]*"[^>]*>\s*<hr[^>]*/?>\s*</div>|
                 <hr[^>]*class="[^"]*section-divider[^"]*"[^>]*/?>}xm.freeze

    def preprocess(body, title, summary)
      body = body.gsub(%r{<div[^>]*class="[^"]*graf--mixtapeEmbed[^"]*"[^>]*>.*?</div>}m) do |card|
        url = card[%r{<a[^>]*href="([^"]+)"}, 1].to_s
        label = text_of(card[%r{<strong[^>]*class="[^"]*markup--strong[^"]*"[^>]*>(.*?)</strong>}m, 1])
        url.empty? ? '' : %(<p><a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(label.empty? ? url : label)}</a></p>)
      end
      # Medium writes a section-divider at the head of EVERY
      # <section class="section section--body">. The one opening
      # section--first is the decorative rule under the title; each later
      # one is the break the author typed as "---" in the editor. Removing
      # them all took those breaks with it, so an essay in parts imported
      # as one undivided run of paragraphs, with nothing in the summary to
      # say so (an hr is not an element HtmlBlocks counts as dropped).
      # Ghost's own mg-medium-export scopes its removal the same way.
      body = body.gsub(/(<section[^>]*class="[^"]*section--first[^"]*"[^>]*>\s*)#{DIVIDER}/m) { Regexp.last_match(1) }
      body = body.gsub(DIVIDER, '<hr>')
      body = body.gsub(%r{<(h[1-6]|blockquote)[^>]*>(.*?)</\1>}m) do |match|
        same_text?(text_of(Regexp.last_match(2)), title) || same_text?(text_of(Regexp.last_match(2)), summary) ? '' : match
      end
      # Every <pre> is normalized, not just the ones announcing a
      # language. The export from the ZIP writes plain
      #   <pre class="graf--pre">
      #     <code class="markup--pre-code">line<br>line<br>line</code>
      #   </pre>
      # with no data attribute, and HtmlBlocks reads <pre> verbatim --
      # which drops <br> entirely. A nine-line install script arrived as
      # one line with its words welded together ("updatesudo apt-get")
      # and the markup's own indentation still stuck to the front. So:
      # <br> becomes a newline, the <code> wrapper is unwrapped so the
      # edges of the real text can be trimmed, and the language is taken
      # from wherever it is offered.
      body.gsub(%r{<pre\b([^>]*)>(.*?)</pre>}m) do
        attrs = Regexp.last_match(1)
        inner = Regexp.last_match(2)
        code_attrs = inner[/\A\s*<code\b([^>]*)>/, 1]
        inner = inner.sub(/\A\s*<code\b[^>]*>/, '').sub(%r{</code>\s*\z}, '') if code_attrs
        lang = attrs[/data-code-block-lang="([^"]+)"/, 1] ||
               code_attrs.to_s[/(?:language|lang)-([\w+#-]+)/, 1]
        code = inner.gsub(%r{<br\s*/?>}, "\n").strip
        open = lang ? %(<code class="language-#{CGI.escapeHTML(lang)}">) : '<code>'
        "<pre>#{open}#{code}</code></pre>"
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
