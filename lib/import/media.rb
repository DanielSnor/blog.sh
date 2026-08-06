# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'fileutils'
require_relative '../media_dimensions'

module Import
  # Collects one post's media on its way to PostWriter, which expects a
  # { source_path => desired_filename } hash. Two sources, because that's
  # the split every importer falls on: a platform API hands out URLs to
  # download (Tumblr, Bluesky), while an official export archive already
  # has the files on disk (Twitter, WordPress attachments).
  #
  # Filenames are numbered per post (01.jpg, 02.png, ...) in the order the
  # adapter registers them. That numbering is deterministic for a given
  # post, which is what makes a re-import land on the same filenames and
  # PostWriter's "skip if it already exists" copy a no-op rather than
  # duplicating media.
  #
  # In dry-run nothing is fetched or read: a filename is still allocated
  # and counted, so the summary is accurate, but no network traffic and no
  # writes happen. Adapters must therefore never depend on the downloaded
  # bytes -- take image dimensions from the platform's metadata, which
  # every API and export provides anyway.
  class Media
    attr_reader :files, :failures

    def initialize(tmpdir, dry_run: false)
      @tmpdir = tmpdir
      @dry_run = dry_run
      @files = {}
      @failures = []
      @counter = 0
      @registered = 0
      # source (url or path) -> allocated filename. @files can't serve this
      # purpose even though it looks like it should: it is keyed by source
      # too, so registering the same image twice used to OVERWRITE the
      # first filename with the second -- the post says 02.jpg, the disk
      # says 12.jpg, and the build reports MISSING media. Old posts use
      # the same image in the text and in a gallery all the time (9 of
      # 1623 posts in one real archive), so the same source now simply
      # gets its first filename back. Kept separately from @files because
      # it must work in dry-run as well, where @files stays empty --
      # otherwise the preview would count the duplicate the real run
      # no longer writes.
      @by_source = {}
    end

    # Deliberately not @files.size: in dry-run nothing is fetched, so
    # @files stays empty, and reporting 0 media would understate exactly
    # the number someone reads a preview to find out -- how much this
    # import is about to download. The preview's wording carries the other
    # half of the truth: this is what the run will GO AFTER, not what will
    # arrive -- one real archive registered 64 files of which the source
    # had kept none, and a bare number here read as a promise.
    def count
      @registered
    end

    # Lets an adapter tell a preview from a real run -- in dry-run no
    # bytes exist, so any "is the downloaded file actually an image?"
    # judgement has to be suspended.
    def dry_run?
      @dry_run
    end

    # Downloads url and registers it, returning the local filename to
    # store in the post (or nil when it couldn't be fetched -- the caller
    # decides whether that costs the whole block or just the media).
    def from_url(url)
      return nil if url.to_s.empty?
      return @by_source[url] if @by_source.key?(url)

      filename = allocate(extension_for(url))
      if @dry_run
        @by_source[url] = filename
        return filename
      end

      body = self.class.fetch(url)
      if body.nil?
        @failures << url
        release
        return nil
      end

      path = File.join(@tmpdir, filename)
      File.binwrite(path, body)
      @files[path] = filename
      @by_source[url] = filename
      filename
    end

    # Pixel dimensions of something already registered, read straight from
    # the downloaded file's header. For sources whose metadata carries no
    # size -- a feed or a WordPress export hands over HTML, and an <img>
    # rarely states width/height -- this is the only way to get them, and
    # they are not optional: build_blog.rb's degenerate_image? tests
    # `width.to_i <= 1`, so a dimensionless image block is dropped from the
    # page exactly like a 1x1 pixel.
    #
    # nil in dry-run, where nothing was fetched. That's fine: dimensions
    # don't affect a preview's counts, only the real write.
    def dimensions(filename)
      return nil if @dry_run

      path = @files.key(filename)
      path && MediaDimensions.image(path)
    end

    # Un-registers a downloaded file an adapter decided was not media
    # after all (the Wayback Machine answers missing images with an HTML
    # page and a 200) -- so the fake never gets copied into the post's
    # media directory.
    def discard(filename)
      return if @dry_run

      path = @files.key(filename)
      return unless path

      @files.delete(path)
      # Or a later reference to the same source would resurrect a filename
      # whose bytes were just judged to not be media at all.
      @by_source.delete_if { |_, name| name == filename }
      @registered -= 1
      begin
        File.delete(path)
      rescue SystemCallError
        nil
      end
    end

    # Registers a file the export already contains. Same contract as
    # from_url, minus the network.
    def from_file(path)
      return nil if path.to_s.empty?
      # The existence check used to be skipped in dry-run, so a preview of an
      # archive whose media tree is incomplete promised more posts and more
      # files than the real run could write, and the real run then dropped
      # the missing ones without naming them. A stat is not a fetch, so this
      # keeps the dry-run contract (nothing is read, written or downloaded).
      # Recorded rather than just skipped: the count is then honest AND the
      # summary still names what the archive is missing.
      unless File.exist?(path)
        @failures << path
        return nil
      end

      return @by_source[path] if @by_source.key?(path)

      filename = allocate(File.extname(path))
      @by_source[path] = filename
      return filename if @dry_run

      @files[path] = filename
      filename
    end

    # Follows redirects and retries transient failures. Importing an
    # archive of a few thousand posts hits connection resets often enough
    # that a single one must not end an hours-long run -- so this returns
    # nil and lets the caller record a failure instead of raising.
    def self.fetch(url, redirects: 5, retries: 3)
      return nil if redirects.zero?

      res =
        begin
          Net::HTTP.get_response(URI(url))
        rescue StandardError => e
          if retries.positive?
            sleep 1
            return fetch(url, redirects: redirects, retries: retries - 1)
          end
          warn "  fetch gave up on #{url}: #{e.message}"
          return nil
        end

      case res
      when Net::HTTPRedirection then fetch(res['location'], redirects: redirects - 1, retries: retries)
      when Net::HTTPSuccess then res.body
      when Net::HTTPServerError, Net::HTTPTooManyRequests
        # "Not now", not "not there" -- the same distinction wayback.rb
        # draws. This used to fall through the case silently: any failed
        # status became a bare nil, no retry, no line saying why, and an
        # hours-long import ended with media quietly missing.
        if retries.positive?
          sleep 1
          return fetch(url, redirects: redirects, retries: retries - 1)
        end
        warn "  fetch gave up on #{url}: HTTP #{res.code}"
        nil
      else
        # 404 and friends are answers, not weather -- retrying won't
        # change them, but the run report must say what happened.
        warn "  fetch failed on #{url}: HTTP #{res.code}"
        nil
      end
    end

    private

    def allocate(ext)
      @counter += 1
      @registered += 1
      format('%02d%s', @counter, ext)
    end

    # A failed fetch gives its number back, so numbering stays contiguous
    # and a later retry of the same post produces the same filenames.
    def release
      @counter -= 1
      @registered -= 1
    end

    # Extension from the URL path, since that's all a CDN URL reliably
    # offers; .jpg is the safe assumption when there is none, matching
    # what image hosts serve by default.
    def extension_for(url)
      ext = File.extname(URI.parse(url).path.to_s)
      ext.empty? ? '.jpg' : ext
    rescue URI::InvalidURIError
      '.jpg'
    end
  end
end
