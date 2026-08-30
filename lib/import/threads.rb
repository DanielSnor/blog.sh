# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative '../i18n'
require_relative '../slug'
require_relative 'meta_html'
require_relative 'meta_text'

module Import
  # Imports a Threads export -- Meta's "Download your information" with
  # Threads selected, pointed at the unpacked directory. Either format
  # it offers: threads/threads_and_replies arrives as .json or .html
  # depending on what was asked for, and which one is here comes from
  # the export itself. Everything is local, media files included.
  #
  # The JSON's shape is Meta's oddest yet: every post is a media LIST
  # even when there is no media -- a text post is one entry with an
  # empty uri and the text in its title field. The HTML page is the same
  # archive rendered one uiBoxWhite box per post, and is read back into
  # that same odd shape so both formats walk through the same map().
  #
  # Replies are marked natively in the JSON (text_app_post.is_reply) and
  # skipped: an archive holds your own standalone posts, same rule as
  # Bluesky and Twitter. The HTML page carries no such mark anywhere
  # that survives its minified classes, so an account with replies
  # should be imported from JSON -- the HTML reader takes every box at
  # face value. The cross_post_source flag is NOT a skip signal in
  # either format: on the export this was built against it sat on every
  # single post, tests written in the Threads app included, so it
  # records where a post was SHARED TO, not where it came from.
  class Threads
    def initialize(dir, format: nil)
      @dir = File.expand_path(dir)
      @format = format || self.class.format_of(@dir)
      @source = self.class.posts_file(@dir, @format)
      @replies = 0
      @unknown_stamps = {}
    end

    # The directory this export lives in. Media#from_file refuses any path
    # that resolves outside it -- an export naming a file on the importer's
    # own disk got it copied into the archive and published.
    def import_root
      @dir
    end


    # The unpacked export nests differently per era: threads/ at the
    # top, or under your_instagram_activity/ (Threads lives on the
    # Instagram account, and Meta moves furniture).
    def self.posts_file(dir, format = nil)
      (format ? [format] : %i[json html]).each do |candidate_format|
        found = ['threads/threads_and_replies',
                 'your_instagram_activity/threads/threads_and_replies',
                 'threads_and_replies']
                .map { |candidate| File.join(dir, "#{candidate}.#{candidate_format}") }
                .find { |path| File.exist?(path) }
        return found if found
      end
      nil
    end

    # Which format sits at dir, for the wizard and the script to check
    # before building anything -- nil for a wrong path, the ordinary
    # mistake.
    def self.format_of(dir)
      %i[json html].find { |format| posts_file(dir, format) }
    end

    # The format is named because the two are not interchangeable where
    # it matters: JSON timestamps are epochs, the HTML's are printed to
    # the minute (see html_items), and only JSON can tell a reply from
    # a post.
    def label
      "Threads export (#{File.basename(@dir)}, #{@format} export)"
    end

    def total
      @total
    end

    def platform_tag
      'threads'
    end

    def each_item(&block)
      items = @format == :html ? html_items : json_items
      items.sort_by! { |i| timestamp_of(i) }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      entries = item['media'].to_a
      return :empty if entries.empty?

      if entries.any? { |e| e.dig('text_app_post', 'is_reply') }
        @replies += 1
        return :reply
      end

      text = MetaText.repair(entries.first['title']).strip
      blocks = text_blocks(text) + media_blocks(entries, text, media)
      return :empty if blocks.empty?

      date = Time.at(timestamp_of(item))
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug = "threads-#{date.strftime('%Y%m%d%H%M%S')}" if slug.empty?

      {
        'slug' => slug,
        'title' => nil,
        'date' => date.iso8601,
        'state' => 'published',
        'tags' => [],
        'content' => blocks,
        'source' => {
          'platform' => 'threads',
          'account' => File.basename(@dir),
          # No ids anywhere in the export -- same minting as Facebook:
          # the timestamp+content pair survives a re-export of the same
          # format. It does NOT survive the jump between formats for a
          # text-only post: the HTML prints no seconds, so its epochs
          # sit at the top of the minute where the JSON's don't.
          'original_id' => "#{timestamp_of(item)}-#{Digest::MD5.hexdigest(text + entries.map { |e| e['uri'].to_s }.join(','))[0, 10]}"
        }
      }
    end

    # The JSON run counts what it skipped; the HTML run cannot count
    # what nothing in the page marks, so instead of a silent zero it
    # says exactly that, every time -- whether there was anything to
    # miss is precisely what it cannot know.
    def postscript
      return I18n.t('import.note.threads_html_replies') if @format == :html
      return nil if @replies.zero?

      I18n.t('import.note.threads_replies', count: @replies)
    end

    private

    def timestamp_of(item)
      item['media'].to_a.filter_map { |e| e['creation_timestamp'] }.min.to_i
    end

    def json_items
      parsed = JSON.parse(File.read(@source, encoding: 'utf-8'))
      parsed['text_post_app_text_posts'] || []
    end

    # One box per post: the words in the h2 (with their line breaks
    # printed literally), the files as href/src pairs into media/, the
    # printed date last, and between them Meta's own metadata tables
    # ("Has Camera Metadata", reply controls), which an archive of what
    # you wrote has no use for. Timestamps are Pacific standard time all
    # year and printed to the minute -- MetaHtml converts them back, and
    # the language of the export decides nothing more than the month
    # names it uses.
    def html_items
      html = File.read(@source, encoding: 'utf-8')
      html.split(POST_BOX).drop(1).filter_map { |box| parse_box(box) }
    end

    POST_BOX = /<div class="[^"]*\buiBoxWhite\b[^"]*">/.freeze
    TEXT = %r{<h2[^>]*>(.*?)</h2>}m.freeze
    MEDIA_REF = %r{(?:href|src)="((?:your_instagram_activity/)?media/[^"]+)"}.freeze

    # Read back into the JSON export's own shape -- a media list whose
    # first entry carries the text -- so map() serves both formats.
    def parse_box(box)
      timestamp = box_timestamp(box)
      return nil unless timestamp

      text = MetaHtml.plain_text(box[TEXT, 1].to_s)
      refs = box.scan(MEDIA_REF).flatten.uniq
      entries = [{ 'uri' => refs.first.to_s, 'title' => text, 'creation_timestamp' => timestamp }]
      entries.concat(refs.drop(1).map { |ref| { 'uri' => ref, 'creation_timestamp' => timestamp } })
      { 'media' => entries }
    end

    # The date is the last text node shaped like one, which keeps a
    # caption that merely mentions a month out of it. One warn per
    # unknown month-and-meridiem pair, not per post -- an export in a
    # language MetaHtml doesn't know should say so in a line, and the
    # JSON export needs no translation.
    def box_timestamp(box)
      printed = MetaHtml.text_nodes(box).reverse.find { |node| node.match?(MetaHtml::TIMESTAMP_NODE) }
      time = printed && MetaHtml.parse_pacific(printed)
      if !time && printed
        token = printed.gsub(/[\d:,]+/, ' ').split.join(' ')
        unless @unknown_stamps[token]
          @unknown_stamps[token] = true
          warn "  cannot read the timestamp #{printed.inspect} -- posts dated like this are skipped; the JSON export needs no translation"
        end
      end
      time&.to_i
    end

    # Threads text is bare -- no markup -- but half of what people post
    # there is a link, so bare URLs become link spans rather than
    # staying dead text.
    def text_blocks(text)
      text.split(/\n{2,}/).filter_map do |para|
        clean = para.strip
        next nil if clean.empty?

        block = { 'type' => 'text', 'text' => clean }
        spans = []
        clean.scan(%r{https?://[^\s]+}) do
          match = Regexp.last_match
          spans << { 'type' => 'link', 'url' => match[0],
                     'start' => match.begin(0), 'end' => match.end(0) }
        end
        block['formatting'] = spans unless spans.empty?
        block
      end
    end

    def media_blocks(entries, text, media)
      entries.filter_map do |entry|
        uri = entry['uri'].to_s
        next nil if uri.empty?

        # The first candidate when none exists, not nil: Media#from_file has
        # to see a referenced-but-missing file too, or its number goes to
        # the next picture and a re-import of a staged export publishes the
        # wrong one. from_file records the failure and names it in the summary.
        candidates = [File.join(@dir, uri),
                      File.join(@dir, uri.sub(%r{\Ayour_instagram_activity/}, ''))]
        path = candidates.find { |candidate| File.exist?(candidate) } || candidates.first

        filename = media.from_file(path)
        next nil unless filename

        kind = path.match?(/\.(mp4|mov)\z/i) ? 'video' : 'image'
        media_entry = { 'url' => filename }
        if kind == 'image'
          width, height = media.dimensions(filename)
          media_entry['width'] = width if width
          media_entry['height'] = height if height
        end
        block = { 'type' => kind, 'media' => [media_entry] }
        caption = MetaText.repair(entry['title']).strip
        block['caption'] = caption if !caption.empty? && caption != text
        block
      end
    end
  end
end
