# frozen_string_literal: true

require 'csv'
require 'cgi'
require 'json'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'pages_note'
require_relative 'permalinks'

module Import
  # Imports a Substack export -- the unpacked ZIP from Settings → Exports,
  # which is posts.csv (metadata) plus posts/<id>.<slug>.html (bodies as
  # web HTML). The export is the author's, so it carries the FULL text of
  # paid posts too; they import like any other, with the paywall marker
  # removed -- but tagged and counted, so an operator can still find them
  # (see PAID_TAG).
  #
  # Two things the export honestly does not have: tags (Substack keeps
  # them only on the live site) and, occasionally, the HTML of the newest
  # posts -- those are skipped and counted rather than imported empty.
  class Substack
    # posts.csv's `audience` column. `only_free` and `everyone` are both
    # public; these two are the ones whose text nobody could read without
    # paying, which is what makes them worth marking.
    PAID_AUDIENCES = %w[only_paid founding].freeze

    # Marks a post whose Substack version was subscribers-only. A tag
    # rather than a draft, because the export is the author's own archive
    # and re-publishing it is the normal case -- but "which of these 300
    # posts were behind the paywall?" used to have no answer anywhere in
    # the run, so the operator could not sort them out before the build.
    PAID_TAG = 'substack-paid'

    attr_accessor :keep_permalinks

    def initialize(dir, site_url: nil, keep_permalinks: false)
      @dir = dir
      @site_url = site_url.to_s.sub(%r{/+\z}, '')
      @keep_permalinks = keep_permalinks
      @paid = 0
      @page_paths = []
    end

    def label
      "Substack export (#{account})"
    end

    def preamble
      "Reading #{File.join(@dir, 'posts.csv')}…"
    end

    def total
      @total
    end

    def platform_tag
      'substack'
    end

    def each_item(&block)
      # The encoding is named for the same reason it is named on the HTML
      # read below: without it CSV follows Encoding.default_external, and
      # a cron or a launchd job runs without a UTF-8 locale. Then an
      # export with one accented title died as
      # CSV::InvalidEncodingError before the first post was written --
      # and even an all-ASCII export lost the &#x2019;-style entities
      # Substack writes into titles and subtitles, because
      # CGI.unescapeHTML only decodes those into a UTF-8 string.
      rows = CSV.read(File.join(@dir, 'posts.csv'), headers: true, encoding: 'utf-8')
      # Counted per run, not per adapter: the wizard previews with the
      # same instance it then imports with, and a counter that only grows
      # reported every paid post twice.
      @paid = 0
      @page_paths = []
      # Oldest first, numeric id as the tiebreaker -- the export's own
      # order is not guaranteed, and imported slugs collide less
      # confusingly when the earlier post got there first.
      items = rows.sort_by { |r| [r['post_date'].to_s, numeric_id(r)] }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      return :thread if item['type'] == 'thread'

      # Imported as a page rather than skipped: Substack's "page" is the
      # about/archive-style standing text, which is exactly what the
      # engine's page type is for.
      is_page = item['type'] == 'page'

      html_path = File.join(@dir, 'posts', "#{item['post_id']}.html")
      # Substack sometimes exports the newest posts as CSV rows with no
      # HTML file at all -- an empty post would look imported and be
      # nothing, so the honest move is a counted skip.
      return :missing_html unless File.exist?(html_path)

      html = preprocess(File.read(html_path, encoding: 'utf-8'))
      parsed = HtmlBlocks.parse(html)
      blocks = leading_blocks(item, media) +
               localize_images(parsed.blocks, media)
      return :empty if blocks.empty?

      state = item['is_published'].to_s.casecmp('true').zero? ? 'published' : 'draft'
      # A row without a date -- most plausibly a never-published draft --
      # used to TypeError out of the whole item and count as a nameless
      # :error. The send timestamp stands in when there is one; a post
      # with neither is skipped under a name the summary can print.
      raw_date = [item['post_date'], item['email_sent_at']].find { |v| !v.to_s.strip.empty? }
      return :undated unless raw_date

      paid = PAID_AUDIENCES.include?(item['audience'].to_s.strip.downcase)
      @paid += 1 if paid

      slug = slug_of(item)
      post = {
        'slug' => slug,
        'title' => item['title'].to_s.empty? ? slug : HtmlBlocks.decode_entities(item['title'].to_s),
        'date' => Time.parse(raw_date).iso8601,
        'state' => state,
        'tags' => paid ? [PAID_TAG] : [],
        'content' => blocks,
        'source' => {
          'platform' => 'substack',
          'account' => account,
          'post_url' => @site_url.empty? ? nil : "#{@site_url}/p/#{slug}",
          'original_id' => numeric_id(item)
        }.compact
      }
      if is_page
        post['page'] = true
        @page_paths << "/#{slug}/"
      end
      # Substack serves a page at /p/<slug> like everything else, so the
      # old address is a real one to keep even for a page -- unlike Ghost
      # or WordPress, where it would be the address the page now has.
      post['redirect_from'] = ["/p/#{slug}"] if @keep_permalinks && state == 'published'
      post
    end

    def postscript
      notes = []
      return notes.compact.first if @paid.zero?

      # lookup rather than t: a missing key aborts, and no summary line is
      # worth failing an import that has already written everything. The
      # posts carry PAID_TAG either way, so the fact is never lost.
      notes << I18n.t('import.note.substack_paid', count: @paid)
      notes.compact.join("\n  ")
    end

    private

    # post_id is "<numeric id>.<slug>" -- both halves are useful: the
    # number is the stable identity re-imports match on, the rest is the
    # public slug and the /p/<slug> path in one.
    def slug_of(item)
      Slug.slugify(item['post_id'].to_s.sub(/\A\d+\./, ''))
    end

    def numeric_id(item)
      item['post_id'].to_s[/\A\d+/].to_i
    end

    def account
      return URI.parse(@site_url).host || @site_url unless @site_url.empty?

      File.basename(File.expand_path(@dir))
    rescue URI::InvalidURIError
      @site_url
    end

    # What Substack shows above the body: the podcast player (for podcast
    # posts, the mp3 is right in the CSV), then the subtitle -- imported
    # as a first paragraph, blog.sh having no separate perex field.
    # Subtitles arrive with HTML entities baked in and need decoding.
    def leading_blocks(item, media)
      blocks = []
      podcast = item['podcast_url'].to_s
      unless podcast.empty?
        filename = media.from_url(podcast)
        blocks << { 'type' => 'audio', 'media' => [{ 'url' => filename }] } if filename
      end
      subtitle = HtmlBlocks.decode_entities(item['subtitle'].to_s).strip
      blocks << { 'type' => 'text', 'text' => subtitle } unless subtitle.empty?
      blocks
    end

    # The parts of Substack's web markup that must not survive into an
    # archive: the paywall marker (the full text follows it -- the export
    # is the author's), subscribe/share/comment furniture, widgets that
    # only worked on Substack, and comment threads. Removed BEFORE
    # HtmlBlocks so none of it can leak through as stray text.
    #
    # Only the OPENING tag is matched; where the element ends is decided
    # by counting (see rewrite_divs), because all of these nest.
    STRIP_DIVS = [
      %r{<div[^>]*class="[^"]*paywall-jump[^"]*"[^>]*>}m,
      %r{<div[^>]*class="[^"]*subscription-widget-wrap[^"]*"[^>]*>}m,
      %r{<div[^>]*class="[^"]*poll-embed[^"]*"[^>]*>}m,
      %r{<div[^>]*class="[^"]*native-video-embed[^"]*"[^>]*>}m,
      %r{<div[^>]*class="[^"]*comment\b[^"]*"[^>]*>}m
    ].freeze

    # The one piece of furniture that is not a <div>: a subscribe/share
    # button is a single <p> with a link in it and never nests, so the
    # plain non-greedy match is still right for it.
    STRIP_BUTTON = %r{<p[^>]*class="[^"]*button-wrapper[^"]*"[^>]*>.*?</p>}m

    # An embedded/digest post card carries its target in a data-attrs JSON
    # attribute (sometimes entity-encoded twice); the durable part is the
    # link, so that is what it becomes.
    CARD = %r{<div[^>]*class="[^"]*(?:digest-post-embed|embedded-post-wrap)[^"]*"[^>]*>}m
    CARD_ATTRS = /data-attrs="([^"]*)"/

    def preprocess(html)
      html = STRIP_DIVS.reduce(html) { |acc, re| rewrite_divs(acc, re) { '' } }
      html = html.gsub(STRIP_BUTTON, '')
      html = rewrite_divs(html, CARD) do |open_tag|
        attrs = decode_attrs(open_tag[CARD_ATTRS, 1].to_s)
        # Two cards, two names for one thing: digest-post-embed calls the
        # target canonical_url, embedded-post-wrap calls it url. Reading
        # only the first left every embedded card as a linkless husk.
        url = (attrs['canonical_url'] || attrs['url']).to_s
        title = attrs['title'].to_s
        url.empty? ? '' : %(<p><a href="#{CGI.escapeHTML(url)}">#{CGI.escapeHTML(title.empty? ? url : title)}</a></p>)
      end
      rewrite_cdn(html)
    end

    # Replaces every <div> whose opening tag matches `opening` with what
    # the block makes of it -- the WHOLE element, opening tag to balanced
    # close.
    #
    # Depth counting rather than `.*?</div>`, because Substack's furniture
    # nests: a subscribe widget is four divs deep, an embedded-post card
    # five. The non-greedy match stopped at the first inner close, so the
    # wrapper disappeared and its insides stayed behind -- a quoted post
    # arrived as four stray paragraphs (its title, 400 characters of
    # somebody else's body, "Read more", "2 years ago · 8 likes").
    #
    # Comments are masked before counting, same length so every index
    # still points into the original: a commented-out <div> would
    # otherwise inflate the depth. A div that never closes is left alone,
    # for the same reason the count exists at all -- furniture leaking as
    # text is a smaller loss than deleting everything after it.
    def rewrite_divs(html, opening)
      masked = html.gsub(/<!--.*?-->/m) { |c| ' ' * c.length }
      out = +''
      pos = 0
      while (m = masked.match(opening, pos))
        stop = div_end(masked, m.end(0))
        out << html[pos...m.begin(0)]
        out << (stop ? yield(html[m.begin(0)...m.end(0)]).to_s : html[m.begin(0)...m.end(0)])
        pos = stop || m.end(0)
      end
      out << html[pos..]
    end

    # Index just past the </div> closing the div whose opening tag ended
    # at `index`, or nil when it never closes.
    def div_end(html, index)
      depth = 1
      while depth.positive? && (nxt = html.match(%r{<div\b|</div>}i, index))
        depth += nxt[0].start_with?('</') ? -1 : 1
        index = nxt.end(0)
      end
      depth.zero? ? index : nil
    end

    def decode_attrs(raw)
      once = CGI.unescapeHTML(raw)
      JSON.parse(once)
    rescue JSON::ParserError
      begin
        JSON.parse(CGI.unescapeHTML(once))
      rescue JSON::ParserError
        {}
      end
    end

    # Substack serves every image through a resizing CDN wrapper whose
    # last path segment is the URL-encoded original -- unwrap it and the
    # full-size file downloads from the source. The old bucketeer S3
    # buckets are dead; their files moved to substack-post-media
    # wholesale.
    FETCH_URL = %r{https://substackcdn\.com/image/fetch/[^"'\s)]*?/(https?%3A[^"'\s)]+)}

    # A family of hosts, not one address: the bucket id differs per
    # publication (bucketeer-abcd1234-…, bucketeer-e05bbc84-…), so the one
    # literal this used to carry rewrote one export's images and left
    # everybody else's pointing at a bucket that no longer answers -- and
    # an image that will not download costs its whole block.
    BUCKETEER = %r{https://bucketeer-[^/"'\s]*\.s3\.amazonaws\.com}

    def rewrite_cdn(html)
      html.gsub(FETCH_URL) { CGI.unescape(Regexp.last_match(1)) }
          .gsub(BUCKETEER, 'https://substack-post-media.s3.amazonaws.com')
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
