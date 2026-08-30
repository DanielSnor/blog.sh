# frozen_string_literal: true

require 'csv'
require 'cgi'
require 'time'
require 'uri'
require_relative '../slug'
require_relative 'html_blocks'
require_relative 'permalinks'

module Import
  # Imports a beehiiv export -- the posts CSV from Settings → Exports.
  # One file, no media: each row carries the ENTIRE email as HTML in its
  # content_html column, table layout and all. Most of the work here is
  # undoing that email: slicing out the real content, dropping the
  # template variables, tracking pixels and footer furniture, and
  # unwrapping the layout tables so they don't parse as data tables.
  #
  # One honest limitation of the CSV: the only date in it is created_at
  # -- beehiiv does not export the publish date. For a back-dated or
  # long-scheduled archive the timeline may be off by the gap between
  # writing and publishing.
  class Beehiiv
    attr_accessor :keep_permalinks

    def initialize(csv_path, keep_permalinks: false)
      @path = csv_path
      @keep_permalinks = keep_permalinks
    end

    def label
      "beehiiv export (#{File.basename(@path)})"
    end

    def preamble
      "Reading #{@path} (#{(File.size(@path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def platform_tag
      'beehiiv'
    end

    def each_item(&block)
      rows = CSV.read(@path, headers: true)
      items = rows.sort_by { |r| r['created_at'].to_s }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      html = item['content_html'].to_s
      return :empty if html.strip.empty?

      title = item['web_title'].to_s
      parsed = HtmlBlocks.parse(preprocess(html, title))
      blocks = localize_images(restore_videos(parsed.blocks), media)

      subtitle = CGI.unescapeHTML(item['web_subtitle'].to_s).strip
      leading = subtitle.empty? ? [] : [{ 'type' => 'text', 'text' => subtitle }]
      # The thumbnail steps in only when the body brought no image of its
      # own -- in the email it is usually the same picture again.
      if blocks.none? { |b| b['type'] == 'image' }
        thumb = full_image_url(item['thumbnail_url'].to_s)
        filename = thumb && media.from_url(thumb)
        if filename
          entry = { 'url' => filename }
          width, height = media.dimensions(filename)
          entry['width'] = width if width
          entry['height'] = height if height
          leading.unshift('type' => 'image', 'media' => [entry])
        end
      end
      blocks = leading + blocks
      return :empty if blocks.empty?

      state = item['status'].to_s == 'confirmed' ? 'published' : 'draft'
      tags = item['content_tags'].to_s.split(';').map(&:strip).reject(&:empty?)
      # An issue only paying subscribers ever saw does not walk out of
      # the paywall by itself: it arrives as a draft carrying a tag, so
      # a person decides whether the public archive gets it. Without
      # this the CSV's audience column was read by nobody and a premium
      # issue published exactly like a free one.
      if premium?(item)
        state = 'draft'
        tags << PREMIUM_TAG
      end
      url = item['url'].to_s
      slug = Slug.slugify(url[%r{/p/([^/?#]+)}, 1].to_s)
      slug = Slug.slugify(title) if slug.empty?

      post = {
        'slug' => slug,
        'title' => title.empty? ? slug : title,
        'date' => (Time.parse(item['created_at'].to_s) rescue Time.now).iso8601,
        'state' => state,
        'tags' => tags,
        'content' => blocks,
        'source' => {
          'platform' => 'beehiiv',
          'account' => host_of(url) || publication_host,
          'post_url' => url.empty? ? nil : url,
          'original_id' => item['id']
        }.compact
      }
      post['redirect_from'] = ["/p/#{slug}"] if @keep_permalinks && state == 'published' && !url.empty?
      post
    end

    private

    # Which audiences were behind the paywall. Exports name the column
    # `audience`, older ones `web_audiences` -- Ghost's migrator reads
    # both, and so must we. 'both' is deliberately absent: it means the
    # issue went to the free segment as well, so it was never paid-only
    # and drafting it would hold back most of a normal archive.
    PREMIUM_AUDIENCES = ['premium', 'all premium subscribers', 'all paid subscribers'].freeze
    PREMIUM_TAG = 'beehiiv-premium'

    # The publication these issues belong to. An issue that was never
    # published carries no `url`, so `account` fell out of its source
    # record -- and PostWriter.source_key is nil without one, so the
    # writer could not match what the previous run had written: re-running
    # the identical command over the identical CSV added slug-2, slug-3,
    # slug-4, against the promise the tool prints itself. Every row in the
    # file belongs to one publication, so the host its published issues
    # carry is the unpublished ones' too.
    def publication_host
      return @publication_host if defined?(@publication_host)

      @publication_host = CSV.read(@path, headers: true).lazy
                             .filter_map { |row| host_of(row['url']) }.first
    end

    def host_of(url)
      return nil if url.to_s.strip.empty?

      URI.parse(url.to_s).host
    rescue StandardError
      nil
    end

    def premium?(item)
      audience = item['audience'] || item['web_audiences']
      PREMIUM_AUDIENCES.include?(audience.to_s.strip.downcase)
    end

    # beehiiv serves images through a Cloudflare transform whose
    # parameters bake in the email's quality=80 -- rewritten to
    # quality=100 so the archive keeps the best copy the CDN will give.
    # A bare uploads/... path (thumbnails) gets the full prefix.
    def full_image_url(url)
      return nil if url.empty?
      # The leading slash is trimmed because the prefix already ends in
      # one: joined as they came, the address held // and the CDN answers
      # that with a 404, so a post whose only picture was its thumbnail
      # would have been written without one. Every path in the exports
      # available here begins "uploads/", without the slash -- this is the
      # other spelling, which Ghost's own beehiiv importer allows for.
      return "https://media.beehiiv.com/cdn-cgi/image/quality=100/#{url.sub(%r{\A/+}, '')}" unless url.start_with?('http')

      url.sub(%r{/cdn-cgi/image/[^/]+/}, '/cdn-cgi/image/quality=100/')
    end

    YOUTUBE_THUMB = %r{<a[^>]*href="([^"]*(?:youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{6,})[^"]*)"[^>]*>(?:(?!</a>).)*ytimg(?:(?!</a>).)*</a>}m

    def preprocess(html, title)
      html = drop_email_furniture(html)
      html = slice_content(html)
      html = html.gsub(/\{\{[^}]+\}\}/, '')
                 .gsub(%r{<div[^>]*data-open-tracking="true"[^>]*>.*?</div>}m, '')
                 .gsub(%r{<div[^>]*style="[^"]*display:\s*none[^"]*"[^>]*>.*?</div>}m, '')
      # The one layout idiom worth keeping as meaning: the spacer table
      # beehiiv uses as a divider. Everything else the tables say is
      # "this is an email", and unwrapping them below says it louder.
      html = html.gsub(%r{<table[^>]*class="[^"]*\bj\b[^"]*"[^>]*>.*?</table>}m, '<hr>')
      html = html.gsub(YOUTUBE_THUMB) { "<p>@@beehiiv-video:#{Regexp.last_match(2)}@@</p>" }
      html = html.gsub(%r{<h1[^>]*>(.*?)</h1>}m) do |match|
        strip_tags(Regexp.last_match(1)).casecmp?(title.strip) ? '' : match
      end
      html = html.gsub(/href="([^"]+)"/) { %(href="#{strip_tracking(Regexp.last_match(1))}") }
      # Email HTML is one big layout table; left in place, HtmlBlocks
      # would faithfully render it as a data table of the whole post.
      html.gsub(%r{</?(?:table|thead|tbody|tfoot|tr|td|th)[^>]*>}m, ' ')
    end

    # Email furniture beehiiv marks with one-letter cell classes. The
    # words inside those cells differ per publication and per locale, so
    # the cut goes by structure -- the same selectors Ghost's own
    # migrator removes (mg-beehiiv process.ts): `td.b` is the footer,
    # `td[class="e"]` plus `td[class="ee e "]` are the question and the
    # answers of a beehiiv poll.
    #
    # Both were riding into the archive whole. A real ASOTU issue landed
    # with six 22px social icons as image blocks (6 of its 14 media
    # files), "Follow …", "Sign up here" and an ad slot as text, plus a
    # dead poll whose answers linked back to beehiiv to vote. The text
    # heuristic in slice_content could not have saved it: that email
    # says "unsubscribe" nowhere, and where it is said, the icons stand
    # before the word anyway.
    #
    # The class match is asymmetric on purpose. The footer is one class
    # among others, but the poll cells must match the WHOLE attribute:
    # `class="ee"` alone is ordinary bulleted content and appeared 13
    # times in that same issue.
    FOOTER_CELL_CLASS = 'b'
    POLL_CELL_CLASSES = [%w[e], %w[e ee]].freeze

    # The walk happens on bytes, not characters. String#match(re, pos)
    # counts pos in characters, so on a UTF-8 string every one of the
    # ~1600 cells in an issue re-walks the document from the start to
    # find its offset -- 5 ms on a 114 KB email, 280 ms on one eight
    # times that. Cuts only ever fall on ASCII tag boundaries, so the
    # pieces re-tag as text unharmed.
    def drop_email_furniture(html)
      bytes = html.b
      kept = +''.b
      index = 0
      while (opening = bytes.match(/<td\b[^>]*>/im, index))
        after = furniture_cell?(opening[0]) ? end_of_cell(bytes, opening.end(0)) : nil
        if after
          kept << bytes[index...opening.begin(0)]
          index = after
        else
          kept << bytes[index...opening.end(0)]
          index = opening.end(0)
        end
      end
      kept << bytes[index..]
      kept.force_encoding(html.encoding)
    end

    def furniture_cell?(tag)
      value = tag[/\bclass\s*=\s*"([^"]*)"/i, 1] || tag[/\bclass\s*=\s*'([^']*)'/i, 1]
      return false unless value

      classes = value.split(/\s+/).reject(&:empty?)
      classes.include?(FOOTER_CELL_CLASS) || POLL_CELL_CLASSES.include?(classes.sort)
    end

    # The end of a furniture cell has to be counted, not searched for:
    # the footer is a nest of tables and the first </td> after it opens
    # belongs to a social icon. A cell that never closes (a truncated
    # export) returns nil and is left alone -- the old behaviour, which
    # keeps too much, rather than a cut that would eat the rest of the
    # email.
    def end_of_cell(html, pos)
      depth = 1
      while (token = html.match(%r{<td\b|</td\s*>}im, pos))
        pos = token.end(0)
        depth += token[0].start_with?('</') ? -1 : 1
        return pos if depth.zero?
      end
      nil
    end

    # The real post lives inside #content-blocks; before it sits the
    # email chrome, after it the unsubscribe footer. Structure takes the
    # footer out above; this stays as the net under it for templates
    # that mark their footer some other way. The end marker is a
    # heuristic and says so: a post genuinely discussing unsubscribing
    # would lose its tail, which the summary's block counts would show.
    def slice_content(html)
      opening = html.match(/<[^>]*id=["']content-blocks["'][^>]*>/)
      html = html[opening.end(0)..] if opening
      cut = html.index(/unsubscribe|update your email preferences|powered by beehiiv/i)
      cut ? html[0...cut] : html
    end

    def strip_tracking(href)
      uri = URI.parse(CGI.unescapeHTML(href))
      return href unless uri.query

      kept = URI.decode_www_form(uri.query).reject { |k, _| k.start_with?('utm_') || k == 'last_resource_guid' }
      uri.query = kept.empty? ? nil : URI.encode_www_form(kept)
      CGI.escapeHTML(uri.to_s)
    rescue URI::InvalidURIError, ArgumentError
      href
    end

    def strip_tags(fragment)
      CGI.unescapeHTML(fragment.gsub(/<[^>]+>/, '')).gsub(/\s+/, ' ').strip
    end

    def restore_videos(blocks)
      blocks.map do |block|
        id = block['type'] == 'text' && block['text'].to_s[/\A@@beehiiv-video:([A-Za-z0-9_-]{6,})@@\z/, 1]
        id ? { 'type' => 'video', 'url' => "https://www.youtube.com/watch?v=#{id}", 'youtube_id' => id } : block
      end
    end

    # Same contract as the other importers, plus the quality rewrite.
    def localize_images(blocks, media)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = block.dig('media', 0, 'url').to_s
        url = full_image_url(url).to_s if url.start_with?('http')
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
