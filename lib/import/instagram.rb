# frozen_string_literal: true

require 'time'
require_relative '../slug'
require_relative '../media_dimensions'
require_relative 'html_blocks'

module Import
  # Imports an Instagram account export -- the zip from Settings → Accounts
  # Centre → Your information and permissions → Download your information,
  # unpacked. Requested in **HTML** rather than JSON: that is the format
  # Instagram offers first, and it ships the photos and videos themselves,
  # so this import needs no network and no token.
  #
  # HTML is the awkward part. Meta's export is a rendered page whose class
  # names are minified per build ("_a6-h _a6-i"), so nothing here keys on
  # them; it reads the structure instead, which has been stable across
  # exports: one post is a `uiBoxWhite` box holding a caption, then its
  # media, then the timestamp. Caption is whatever text precedes the first
  # media reference, the date is the first timestamp-shaped text after the
  # last one, and everything between is Instagram's own metadata tables
  # (latitude, device id, "Has Camera Metadata"), which an archive of what
  # you wrote has no use for.
  #
  # Scope: your grid and your IGTV videos. Not imported, deliberately --
  #   * archived posts, which you removed from your own profile once
  #     already, and which an import would quietly put back;
  #   * profile photos, which are avatar history rather than posts;
  #   * stories, likes, comments and messages, which the export separates
  #     for the same reason this does.
  class Instagram
    # Both are used by the export: photos are `<a href>` + `<img src>` of
    # the same file, a video is `<video src>` wrapping an `<a href>`. Taken
    # together and deduplicated, which also keeps a carousel in order.
    MEDIA_REF = /(?:href|src)="(media\/[^"]+)"/.freeze

    # One post's box. `pam` and `uiBoxWhite` are Facebook's decade-old
    # layout classes and are what has survived every export format change;
    # the hashed ones next to them have not.
    POST_BOX = /<div class="[^"]*\buiBoxWhite\b[^"]*">/.freeze

    # "Jan 12, 2023 1:44 am". Anchored, so it matches the timestamp and not
    # a caption that happens to mention a month.
    TIMESTAMP = /\A[A-Z][a-z]{2} \d{1,2}, \d{4} \d{1,2}:\d{2} [ap]m\z/.freeze
    TIMESTAMP_FORMAT = '%b %d, %Y %I:%M %p'

    IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .webp .heic].freeze
    VIDEO_EXTENSIONS = %w[.mp4 .mov .m4v].freeze

    # A hashtag line at the end of a caption is Instagram's reach machinery,
    # not prose -- and it is already the post's tags, so as text it would
    # render as a wall of one-word links under every photo. Same treatment
    # as the Pixelfed import, minus the assumption that they sit on lines of
    # their own: on Instagram the whole tail is usually one line.
    HASHTAG_LINE = /\A(?:#[[:word:]]+[[:space:]]*)+\z/.freeze

    def initialize(export_dir)
      @export_dir = export_dir
    end

    def label
      "Instagram (@#{account})"
    end

    def preamble
      names = content_files.map { |path| File.basename(path) }
      "Reading #{names.join(', ')} from #{content_dir}…"
    end

    def total
      @total
    end

    def each_item(&block)
      items = content_files.flat_map { |path| parse_file(path) }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      blocks = text_blocks(item[:caption])
      blocks.concat(media_blocks(item, media))
      return :empty if blocks.empty?

      {
        'slug' => build_slug(item, blocks),
        'title' => nil,
        'date' => timestamp(item).iso8601,
        'state' => 'published',
        'tags' => hashtags(item[:caption]),
        'content' => blocks,
        'source' => {
          'platform' => 'instagram',
          'account' => account,
          # No post_url: the export states neither a post's shortcode nor
          # its URL anywhere, and a guessed one would 404 for every post
          # while looking authoritative. The media id below is what the
          # export does carry, and it is enough to match a re-import.
          'original_id' => original_id(item)
        }
      }
    end

    private

    def content_dir
      File.join(@export_dir, 'your_instagram_activity', 'content')
    end

    # posts_1.html, posts_2.html, ... on a large account -- sorted
    # numerically, since posts_10 sorts before posts_2 as a string and the
    # import would run out of order. IGTV last: it is a separate file with
    # the same shape, and dates interleave with the grid anyway.
    def content_files
      @content_files ||= begin
        posts = Dir[File.join(content_dir, 'posts_*.html')]
                .sort_by { |path| File.basename(path)[/\d+/].to_i }
        igtv = File.join(content_dir, 'igtv_videos.html')
        posts + (File.exist?(igtv) ? [igtv] : [])
      end
    end

    # Everything before the first post box is the page header; everything
    # after the last box's timestamp is the page footer, and neither holds
    # text this looks at.
    def parse_file(path)
      html = File.read(path, encoding: 'utf-8')
      html.split(POST_BOX).drop(1).filter_map { |chunk| parse_post(chunk, path) }
    end

    def parse_post(chunk, path)
      refs = chunk.scan(MEDIA_REF).flatten.uniq
      head, tail = split_at_media(chunk, refs.first)
      date = text_nodes(tail).find { |node| node.match?(TIMESTAMP) }
      return nil unless date

      { caption: plain_text(head), media: refs, date: date, file: path }
    end

    # The caption is what comes before the post's first photo; the date is
    # after its last. With no media at all (which the export permits even if
    # the app no longer does) the whole box is caption, and the date is
    # found in it by shape.
    #
    # Splitting on the path cuts the middle of the `<a href="…">` that
    # holds it, so each half is trimmed back to a tag boundary -- otherwise
    # the caption keeps a dangling `<a target="_blank" href="` that no
    # tag-stripping regex can match, and it ends up in the post's text.
    def split_at_media(chunk, first_ref)
      return [chunk, chunk] unless first_ref

      head, _, rest = chunk.partition(first_ref)
      [head.sub(/<[^<]*\z/, ''), rest.sub(/\A[^>]*>/, '')]
    end

    def text_nodes(fragment)
      fragment.gsub(/<[^>]*>/, "\n").split("\n").map { |node| HtmlBlocks.decode_entities(node).strip }
              .reject(&:empty?)
    end

    # Tags dropped rather than turned into separators, so a caption's own
    # newlines are all that remain -- they are what separates its sentences
    # from its hashtag tail.
    def plain_text(fragment)
      HtmlBlocks.decode_entities(fragment.gsub(%r{<br\s*/?>}i, "\n").gsub(/<[^>]*>/, '')).strip
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

    # Nothing in the export states a pixel size, so every file is measured
    # -- and it has to be, since build_blog.rb drops an image block without
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

    def timestamp(item)
      Time.strptime(item[:date], TIMESTAMP_FORMAT)
    end

    # Instagram's own id for the post's first attachment, which the export
    # spells out in every filename ("..._17972948920990787.jpg"). Stable
    # across exports, which is what a re-import matches on. Without media
    # -- or with a filename that doesn't carry one -- the timestamp stands
    # in: it is unique per post in practice, and the alternative is an id
    # that changes each run and duplicates the whole archive.
    def original_id(item)
      id = item[:media].first.to_s[/_(\d{10,})\.\w+\z/, 1]
      id || timestamp(item).to_i.to_s
    end

    def build_slug(item, blocks)
      text = blocks.find { |block| block['type'] == 'text' }&.fetch('text', '').to_s
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "instagram-#{original_id(item)}" : slug
    end

    # From the profile page of the export. The label is in whatever
    # language the export was requested in, so a miss is expected rather
    # than exceptional -- the export directory's name is a fair fallback,
    # and only the summary line and the source record read this.
    def account
      @account ||= begin
        path = File.join(@export_dir, 'personal_information', 'personal_information',
                         'personal_information.html')
        nodes = File.exist?(path) ? text_nodes(File.read(path, encoding: 'utf-8')) : []
        index = nodes.index('Username')
        index ? nodes[index + 1].to_s : File.basename(File.expand_path(@export_dir))
      rescue StandardError
        File.basename(File.expand_path(@export_dir))
      end
    end
  end
end
