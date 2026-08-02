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
    end

    # Deliberately not @files.size: in dry-run nothing is fetched, so
    # @files stays empty, and reporting 0 media would understate exactly
    # the number someone reads a preview to find out -- how much this
    # import is about to download.
    def count
      @registered
    end

    # Downloads url and registers it, returning the local filename to
    # store in the post (or nil when it couldn't be fetched -- the caller
    # decides whether that costs the whole block or just the media).
    def from_url(url)
      return nil if url.to_s.empty?

      filename = allocate(extension_for(url))
      return filename if @dry_run

      body = self.class.fetch(url)
      if body.nil?
        @failures << url
        release
        return nil
      end

      path = File.join(@tmpdir, filename)
      File.binwrite(path, body)
      @files[path] = filename
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

    # Registers a file the export already contains. Same contract as
    # from_url, minus the network.
    def from_file(path)
      return nil if path.to_s.empty?
      # The existence check used to be skipped in dry-run, so a preview of an
      # archive whose media tree is incomplete promised more posts and more
      # files than the real run could write, and the real run then dropped
      # the missing ones without naming them. A stat is not a fetch, so this
      # keeps the dry-run contract (nothing is read, written or downloaded).
      return nil unless File.exist?(path)

      filename = allocate(File.extname(path))
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
