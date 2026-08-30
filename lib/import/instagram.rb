# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../slug'
require_relative '../media_dimensions'
require_relative '../path_glob'
require_relative 'html_blocks'
require_relative 'meta_html'

module Import
  # Imports an Instagram account export -- the zip from Settings → Accounts
  # Centre → Your information and permissions → Download your information,
  # unpacked. Either format it offers: the download asks for HTML or JSON,
  # and which one you picked is written in the export itself, so this reads
  # whichever is there rather than asking a question the directory answers.
  # Both ship the photos and videos, so no network and no token.
  #
  # This class is the half that doesn't care which: a caption, a list of
  # files and a time become a post the same way. The two readers below hand
  # it that shape.
  #
  # Scope: your grid and your IGTV videos. Not imported, deliberately --
  #   * archived posts, which you removed from your own profile once
  #     already, and which an import would quietly put back;
  #   * profile photos, which are avatar history rather than posts;
  #   * stories, likes, comments and messages, which the export separates
  #     for the same reason this does.
  class Instagram
    IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .webp .heic].freeze
    VIDEO_EXTENSIONS = %w[.mp4 .mov .m4v].freeze

    # A hashtag line at the end of a caption is Instagram's reach machinery,
    # not prose -- and it is already the post's tags, so as text it would
    # render as a wall of one-word links under every photo. Same treatment
    # as the Pixelfed import, minus the assumption that they sit on lines of
    # their own: on Instagram the whole tail is usually one line.
    HASHTAG_LINE = /\A(?:#[[:word:]]+[[:space:]]*)+\z/.freeze

    # The two formats don't even keep their posts in the same place: HTML
    # writes them under content/, JSON under media/ -- next to the folder
    # of the same name that holds the actual files.
    CONTENT_DIRS = { html: 'content', json: 'media' }.freeze

    def self.content_dir(export_dir, format)
      File.join(export_dir, 'your_instagram_activity', CONTENT_DIRS.fetch(format))
    end

    # What the wizard and the script check before building anything: is
    # there an export here at all, and in which format. nil rather than an
    # exception, since "the user typed the wrong path" is the ordinary case
    # and deserves the ordinary message.
    def self.format_of(export_dir)
      CONTENT_DIRS.each_key do |format|
        next if PathGlob.under(content_dir(export_dir, format), "posts_*.#{format}").empty?

        return format
      end
      nil
    end

    def initialize(export_dir, format: nil)
      @export_dir = export_dir
      @reader = case format || self.class.format_of(export_dir)
                when :json then JsonExport.new(export_dir)
                else HtmlExport.new(export_dir)
                end
    end

    # The directory this export lives in. Media#from_file refuses any path
    # that resolves outside it -- an export naming a file on the importer's
    # own disk got it copied into the archive and published.
    def import_root
      @export_dir
    end


    # The format is named because the two are not interchangeable in one
    # way that matters: their timestamps mean different things (see each
    # reader), so a summary that says which one ran is the difference
    # between a checkable claim and a shrug.
    def label
      "Instagram (@#{@reader.account}, #{@reader.format} export)"
    end

    def preamble
      @reader.preamble
    end

    def total
      @reader.total
    end

    def each_item(&block)
      @reader.each_item(&block)
    end

    def map(item, media)
      caption = normalize(item[:caption])
      blocks = text_blocks(caption)
      blocks.concat(media_blocks(item, media))
      return :empty if blocks.empty?

      {
        'slug' => build_slug(item, blocks),
        'title' => nil,
        'date' => item[:time].iso8601,
        'state' => 'published',
        'tags' => hashtags(caption),
        'content' => blocks,
        'source' => {
          'platform' => 'instagram',
          'account' => @reader.account,
          # No post_url: neither format states a post's shortcode or URL
          # anywhere, and a guessed one would 404 for every post while
          # looking authoritative. The media id below is what the export
          # does carry, and it is enough to match a re-import.
          'original_id' => original_id(item)
        }
      }
    end

    private

    # Some captions arrive decomposed -- "í" as an i and a combining acute,
    # which is what an iOS keyboard produced when they were typed (16 of
    # 288 on the account this was built against, identically in both
    # exports). Nothing downstream breaks either way: slugs and the search
    # index both fold through NFKD first. This is for the stored text
    # itself, so that captions which look the same *are* the same string
    # and compare equal to anything that isn't Unicode-aware -- a grep over
    # content.nosync, a diff between two imports.
    def normalize(caption)
      caption.to_s.unicode_normalize(:nfc)
    rescue ArgumentError, Encoding::CompatibilityError
      caption.to_s
    end

    # A caption becomes one text block per paragraph, after the hashtag tail
    # is cut. Single newlines stay inside their block: the build renders
    # them as line breaks, which is how they looked on Instagram.
    def text_blocks(caption)
      lines = caption.to_s.lines.map(&:rstrip)
      lines.pop while lines.last && (lines.last.empty? || lines.last.match?(HASHTAG_LINE))

      lines.join("\n").split(/\n{2,}/).filter_map do |paragraph|
        text = paragraph.strip
        next if text.empty?

        { 'type' => 'text', 'text' => text }
      end
    end

    def hashtags(caption)
      caption.to_s.scan(/#([[:word:]]+)/).flatten.uniq { |tag| tag.downcase }
    end

    def media_blocks(item, media)
      item[:media].filter_map do |ref|
        extension = File.extname(ref).downcase
        kind = if IMAGE_EXTENSIONS.include?(extension) then 'image'
               elsif VIDEO_EXTENSIONS.include?(extension) then 'video'
               end
        # Subtitle sidecars (.srt) sit next to a video in the export and
        # are referenced the same way; the block schema has nowhere to put
        # them, so they are left in the export rather than copied.
        next unless kind

        path = File.join(@export_dir, ref)
        filename = media.from_file(path)
        next unless filename

        { 'type' => kind, 'media' => [entry(filename, path, kind)] }
      end
    end

    # Neither format states a pixel size, so every file is measured -- and
    # it has to be, since build_blog.rb drops an image block without
    # dimensions exactly like a 1x1 pixel. Measuring is a header read of a
    # local file, cheap enough to do in dry-run too, where it is the only
    # warning you get that a photo would silently vanish from the page.
    def entry(filename, path, kind)
      entry = { 'url' => filename }
      size = File.exist?(path) && (kind == 'video' ? MediaDimensions.video(path) : MediaDimensions.image(path))
      if size
        entry['width'], entry['height'] = size
      else
        warn "  no dimensions for #{File.basename(path)}; it will not be rendered"
      end
      entry
    end

    # Instagram's own id for the post's first attachment, which both
    # formats put at the end of every filename -- HTML after the CDN's own
    # name ("..._n_17972948920990787.jpg"), JSON on its own
    # ("17972948920990787.jpg"). Matching the trailing digits rather than
    # the underscore is what makes the two agree: all 643 ids in the
    # export this was built against are the same in both formats, so an
    # archive imported from one and re-imported from the other overwrites
    # itself in place rather than doubling.
    #
    # Without media, or with a filename that carries no id, the timestamp
    # stands in.
    def original_id(item)
      id = item[:media].first.to_s[/(\d{10,})\.\w+\z/, 1]
      id || item[:time].to_i.to_s
    end

    def build_slug(item, blocks)
      text = blocks.find { |block| block['type'] == 'text' }&.fetch('text', '').to_s
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "instagram-#{original_id(item)}" : slug
    end

    # Reading half, shared: both formats put their posts in the same files
    # under a different extension, and neither names the account anywhere a
    # generic reader could find it.
    class Reader
      def initialize(export_dir)
        @export_dir = export_dir
      end

      attr_reader :total

      def preamble
        names = content_files.map { |path| File.basename(path) }
        "Reading #{names.join(', ')} from #{content_dir}…"
      end

      def each_item
        items = content_files.flat_map { |path| parse_file(path) }
        @total = items.size
        items.each { |item| yield item }
      end

      private

      def content_dir
        Instagram.content_dir(@export_dir, format)
      end

      # posts_1, posts_2, ... on a large account -- sorted numerically,
      # since posts_10 sorts before posts_2 as a string and the import
      # would run out of order. IGTV last: it is a separate file with the
      # same shape, and dates interleave with the grid anyway.
      #
      # The underscore in the glob matters in the JSON export, which also
      # ships a posts.json -- a second serialisation of the same grid with
      # the archived posts mixed back in (307 entries against posts_1's
      # 286). Importing both would double the archive and undo the decision
      # to leave archived posts alone.
      def content_files
        @content_files ||= begin
          posts = PathGlob.under(content_dir, "posts_*.#{format}")
                  .sort_by { |path| File.basename(path)[/\d+/].to_i }
          igtv = File.join(content_dir, "igtv_videos.#{format}")
          posts + (File.exist?(igtv) ? [igtv] : [])
        end
      end

      # The export directory's name, for when the profile file isn't there
      # or spells its labels in a language this doesn't know. Only the
      # summary line and the source record read this.
      def fallback_account
        File.basename(File.expand_path(@export_dir))
      end
    end

    # The HTML export is a rendered page whose class names are minified per
    # build ("_a6-h _a6-i"), so nothing here keys on them; it reads the
    # structure instead, which has been stable across exports: one post is a
    # `uiBoxWhite` box holding a caption, then its media, then the
    # timestamp. Caption is whatever text precedes the first media
    # reference, the date is the first timestamp-shaped text after the last
    # one, and everything between is Instagram's own metadata tables
    # (latitude, device id, "Has Camera Metadata"), which an archive of what
    # you wrote has no use for. The dates print in whatever language the
    # export was requested in -- MetaHtml's tables (Czech and English,
    # each verified against a real Meta export) read them back, and an
    # export in a language they don't know says so by name instead of
    # importing nothing in silence.
    class HtmlExport < Reader
      # Both attributes are used: photos are `<a href>` + `<img src>` of the
      # same file, a video is `<video src>` wrapping an `<a href>`. Taken
      # together and deduplicated, which also keeps a carousel in order.
      MEDIA_REF = /(?:href|src)="(media\/[^"]+)"/.freeze

      # One post's box. `pam` and `uiBoxWhite` are Facebook's decade-old
      # layout classes and are what has survived every export format
      # change; the hashed ones next to them have not.
      POST_BOX = /<div class="[^"]*\buiBoxWhite\b[^"]*">/.freeze

      # The timestamp is recognized among the box's text nodes by shape
      # ("Jan 12, 2023 1:44 am" -- anchored, so a caption that merely
      # mentions a month stays a caption) and converted back by
      # MetaHtml.parse_pacific. The zone is the part the page never
      # prints, and it is Meta's own: Pacific, as a fixed -08:00 --
      # standard time all year, NOT the America/Los_Angeles zone that is
      # the obvious reading. Both facts were measured against this same
      # account's JSON export, whose epochs are beyond argument: read as
      # local time, the archive showed a six-hour hole across every
      # afternoon and 106 of 286 posts between midnight and 6am; read as
      # the DST-observing zone, 173 of 288 posts -- exactly the ones in
      # daylight-saving months -- sat an hour off. The result is handed
      # back in the site's zone, so the date a reader sees and the year
      # the post's URL is built from are the same day -- a post made
      # late on New Year's Eve in Prague is an afternoon of December
      # 31st to the export, and storing that as printed would file it
      # under the wrong year for good.
      def format
        :html
      end

      # From the profile page of the export. The label is in whatever
      # language the export was requested in -- the languages MetaHtml
      # knows are tried, and a miss still just means the directory's
      # name, not a failure.
      def account
        @account ||= begin
          path = File.join(@export_dir, 'personal_information', 'personal_information',
                           'personal_information.html')
          nodes = File.exist?(path) ? MetaHtml.text_nodes(File.read(path, encoding: 'utf-8')) : []
          index = nodes.find_index { |node| MetaHtml.username_label?(node) }
          index ? nodes[index + 1].to_s : fallback_account
        rescue StandardError
          fallback_account
        end
      end

      private

      # Everything before the first post box is the page header; everything
      # after the last box's timestamp is the page footer, and neither
      # holds text this looks at. A file whose boxes all failed to date is
      # the signature of an export in a language the tables don't know,
      # and deserves one loud line rather than a silent zero.
      def parse_file(path)
        html = File.read(path, encoding: 'utf-8')
        boxes = html.split(POST_BOX).drop(1)
        posts = boxes.filter_map { |chunk| parse_post(chunk) }
        if posts.empty? && !boxes.empty?
          warn "  #{File.basename(path)}: none of its #{boxes.size} posts carried a readable date -- " \
               'an export in a language the tables don\'t know? The JSON export needs no translation.'
        end
        posts
      end

      def parse_post(chunk)
        refs = chunk.scan(MEDIA_REF).flatten.uniq
        head, tail = split_at_media(chunk, refs.first)
        printed = MetaHtml.text_nodes(tail).find { |node| node.match?(MetaHtml::TIMESTAMP_NODE) }
        return nil unless printed

        time = MetaHtml.parse_pacific(printed)
        return unknown_stamp(printed) unless time

        { caption: MetaHtml.plain_text(head), media: refs, time: time }
      end

      # One warn per unrecognized month-and-meridiem pair rather than per
      # post, same policy as the Facebook and Threads readers.
      def unknown_stamp(printed)
        @unknown_stamps ||= {}
        token = printed.gsub(/[\d:,]+/, ' ').split.join(' ')
        unless @unknown_stamps[token]
          @unknown_stamps[token] = true
          warn "  cannot read the timestamp #{printed.inspect} -- posts dated like this are skipped; " \
               'the JSON export needs no translation'
        end
        nil
      end

      # The caption is what comes before the post's first photo; the date
      # is after its last. With no media at all (which the export permits
      # even if the app no longer does) the whole box is caption, and the
      # date is found in it by shape.
      #
      # Splitting on the path cuts the middle of the `<a href="…">` that
      # holds it, so each half is trimmed back to a tag boundary --
      # otherwise the caption keeps a dangling `<a target="_blank" href="`
      # that no tag-stripping regex can match, and it ends up in the post's
      # text.
      def split_at_media(chunk, first_ref)
        return [chunk, chunk] unless first_ref

        head, _, rest = chunk.partition(first_ref)
        [head.sub(/<[^<]*\z/, ''), rest.sub(/\A[^>]*>/, '')]
      end

    end

    # The JSON export is the same archive without the page around it, and
    # it is the better of the two where it counts: `creation_timestamp` is
    # an epoch, so no zone has to be inferred and nothing can be off by
    # nine hours.
    #
    # What it costs instead is Meta's mojibake -- text arrives as UTF-8
    # bytes that were escaped one byte at a time, so "Šťastné" reads as
    # "Å ÅyastnÃ©" until it is put back together (see repair). The HTML
    # export has no such problem, which is the one thing HTML does better.
    class JsonExport < Reader
      # A post's caption sits in `title`. On a single-media post that field
      # is often empty and the caption is on the medium instead, so both
      # places are looked at, in that order.
      def format
        :json
      end

      def account
        @account ||= begin
          path = File.join(@export_dir, 'personal_information', 'personal_information',
                           'personal_information.json')
          found = File.exist?(path) ? find_username(JSON.parse(File.read(path, encoding: 'utf-8'))) : nil
          found || fallback_account
        rescue StandardError
          fallback_account
        end
      end

      private

      def parse_file(path)
        entries(JSON.parse(File.read(path, encoding: 'utf-8'))).filter_map { |entry| parse_post(entry) }
      end

      # posts_N.json is a bare array; igtv_videos.json and the archive
      # files wrap theirs in a one-key object whose name has changed
      # between export versions, so the array is taken by shape rather than
      # by name.
      def entries(parsed)
        return parsed if parsed.is_a?(Array)
        return [] unless parsed.is_a?(Hash)

        parsed.values.find { |value| value.is_a?(Array) } || []
      end

      def parse_post(entry)
        media = Array(entry['media'])
        refs = media.filter_map { |item| item['uri'] }.uniq
        epoch = entry['creation_timestamp'] || media.filter_map { |item| item['creation_timestamp'] }.min
        return nil unless epoch

        caption = presence(entry['title']) || presence(media.first&.fetch('title', nil))
        { caption: repair(caption.to_s), media: refs, time: Time.at(epoch.to_i).getlocal }
      end

      def presence(value)
        text = value.to_s
        text.strip.empty? ? nil : text
      end

      # Meta escapes each byte of a UTF-8 string as its own code point, so
      # what JSON hands back is Latin-1 that has to be read as UTF-8 again:
      # "\u00C5\u00A1\u00C5\u00A5astn\u00C3\u00A9" is "\u0161\u0165astn\u00E9" one byte at a time.
      #
      # The range is every byte that can start a UTF-8 sequence, C2..F4 --
      # not just the C2..C3 that Western European text needs. Czech \u0159 is
      # C5 99 and an emoji is F0 9F ..., so a narrower guard leaves exactly
      # the accented alphabets and emoji broken while looking like it
      # works. Guarded rather than applied blindly, since the same
      # conversion would destroy text that arrived intact.
      MOJIBAKE = /[\u00C2-\u00F4][\u0080-\u00BF]/.freeze

      def repair(text)
        return text unless text.match?(MOJIBAKE)

        candidate = text.encode('ISO-8859-1').force_encoding('UTF-8')
        candidate.valid_encoding? ? candidate : text
      rescue Encoding::UndefinedConversionError
        text
      end

      # The profile file nests the username differently between export
      # versions (string_map_data in the ones seen, plain keys in others),
      # so it is searched for rather than reached for. The key is a
      # localized display label, and in a localized export it arrives
      # mojibake-mangled like any other string -- so it goes through
      # repair before the comparison, which on an English key changes
      # nothing.
      def find_username(node)
        case node
        when Hash
          key = node.keys.find { |k| MetaHtml.username_label?(repair(k.to_s)) }
          if key
            value = node[key]
            return repair(value.is_a?(Hash) ? value['value'].to_s : value.to_s)
          end

          node.values.filter_map { |child| find_username(child) }.first
        when Array
          node.filter_map { |child| find_username(child) }.first
        end
      end
    end
  end
end
