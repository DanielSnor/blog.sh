# frozen_string_literal: true

require_relative '../post_writer'

module Import
  # Where every media file in this archive was fetched from: source address
  # -> the file on disk. Asked by Media before it downloads anything.
  #
  # It exists because the two ends of a download know different halves of
  # the answer. Media numbers a file per post (01.jpg, 02.png) and only
  # PostWriter, much later, settles the year and slug the number sits
  # under -- so at from_url time nothing could say whether these bytes were
  # already here, and the re-import the docs recommend as safe fetched the
  # whole archive again. Measured on a real 118-post Ghost export: 420
  # images, four and a half minutes of network, and not one file changed on
  # disk. On an archive of a few thousand that is hours, and the traffic
  # that gets an importer throttled or blocked by the source it is rescuing.
  #
  # The `src` each media entry now carries is the missing direction: from
  # the address, which IS known before the fetch, to the file. One pass
  # over content.nosync builds the map; every lookup after that is a hash
  # hit and a stat.
  #
  # The pass is LAZY, and that is not a micro-optimisation: every importer
  # that reads a local tree registers its media through from_file, which
  # never asks this class anything. Building eagerly made those imports
  # read and JSON-parse the entire existing archive -- on a few thousand
  # posts, a wait as long as the import itself -- to answer a question
  # nobody was going to ask.
  class MediaIndex
    # What the archive holds for one address: the file, plus the width and
    # height the post recorded when the file was written. The dimensions
    # are kept because for some files they are the only copy there is --
    # nothing here can measure a video or an SVG. See Media#dimensions.
    Entry = Struct.new(:path, :width, :height) do
      def dimensions
        [width, height] if width && height
      end
    end

    def initialize(map = nil)
      @map = map
    end

    # One index per process. The wizard runs the archive twice (a preview
    # and the real thing) and Run makes a Media per item, so anything but a
    # memo would re-read every post thousands of times over.
    def self.shared
      @shared ||= new
    end

    # REFETCH_MEDIA=1 means "do not take the index's word for it": every
    # address is asked of the source again instead of being answered from
    # the archive. What the run then WRITES is unchanged -- the engine
    # never replaces a media file it already has -- so on a complete
    # archive the flag buys nothing but the traffic, and its use is an
    # archive whose `src` records point somewhere the files did not come
    # from. Validated rather than truthiness-tested, for the same reason
    # LIMIT is: a typo like REFETCH_MEDIA=yes silently meaning "no" is the
    # sort of quiet no-op that gets typed twice.
    #
    # Note what it does NOT do: turn the index off. The index is still
    # built, because a refetch whose source has since died must be able to
    # fall back on the copy the archive already has. Switching it off
    # instead -- which this did at first -- emptied 419 media entries out
    # of 118 posts while all 419 files lay untouched on disk.
    def self.refetch?(env = ENV)
      case env['REFETCH_MEDIA']
      when nil, '', '0' then false
      when '1' then true
      else abort("REFETCH_MEDIA must be 1 or 0 (got #{env['REFETCH_MEDIA'].inspect})")
      end
    end

    def self.build(content_dir: PostWriter::CONTENT_DIR, media_dir: PostWriter::MEDIA_DIR)
      new(scan(content_dir: content_dir, media_dir: media_dir))
    end

    # PostWriter.each_post rather than a Dir.glob and a JSON.parse of its
    # own: the source-id index needs the same files, and an import that
    # read and parsed a few thousand post JSONs twice paid the archive's
    # whole size for a map it already had in memory once.
    def self.scan(content_dir: PostWriter::CONTENT_DIR, media_dir: PostWriter::MEDIA_DIR)
      map = {}
      PostWriter.each_post(content_dir: content_dir) do |path, post|
        dir = File.join(media_dir, File.basename(File.dirname(path)), File.basename(path, '.json'))
        each_media_entry(post) do |entry|
          src = entry['src'].to_s
          name = entry['url'].to_s
          next if src.empty? || !plain_name?(name)

          # Last post wins, and it does not matter which: any copy of the
          # bytes answers the question "must this be fetched again?".
          map[src] = Entry.new(File.join(dir, name), entry['width'], entry['height'])
        end
      end
      map
    end

    # Both shared with PostWriter, which walks the same entries to check
    # what a post says about the files beside it. One rule, one place: two
    # copies of "what counts as a media entry" would answer differently the
    # day either of them learned about a new block.
    def self.plain_name?(name)
      PostWriter.plain_media_name?(name)
    end

    def self.each_media_entry(post, &block)
      PostWriter.each_media_entry(post, &block)
    end

    # Built on first use, not on construction -- see the class comment.
    def map
      @map ||= self.class.scan
    end

    # The archive's copy of this address, or nil. Checked on disk rather
    # than trusted from the JSON: a post may name a file somebody has since
    # deleted, and answering with a path that is not there would turn a
    # skipped download into a missing image.
    #
    # It exists and it is not empty, and deliberately nothing beyond that.
    # An earlier shape asked whether the file still MEASURED, meaning to
    # catch a half-restored backup, and instead disqualified every valid
    # HEIC, TIFF, BMP and SVG in the archive -- this engine's dimension
    # reader knows a handful of formats, and a file it cannot read is not
    # a broken file. Judging an archive's health is `./blog.sh check`'s
    # job; an import only ever adds what is missing.
    def entry_for(src)
      entry = map[src.to_s]
      return nil unless entry && File.file?(entry.path)

      entry if File.size(entry.path).positive?
    end

    # Adds a file this run has just written. Without it, one address used
    # by two different posts -- old blogs do this constantly -- is fetched
    # once per post, because the index was a snapshot taken before the run
    # started.
    #
    # Nothing is added to a map nobody has asked for yet, and that guard is
    # the difference between lazy and lazy-in-name-only: touching @map here
    # forced the whole archive to be read and parsed after the first post,
    # on every import -- including the ones that never look anything up,
    # which is every import of a local tree. Nothing is lost by waiting,
    # because the pass reads the archive from DISK and this post is already
    # written there.
    def remember(src, path, width = nil, height = nil)
      return if @map.nil?
      return if src.to_s.empty? || path.to_s.empty?

      @map[src.to_s] = Entry.new(path, width, height)
    end
  end
end
