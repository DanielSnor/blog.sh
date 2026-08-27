# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'fileutils'
require_relative '../media_dimensions'

module Import
  # Collects one post's media on its way to PostWriter, which expects
  # [source_path, desired_filename] pairs (see #files). Two sources,
  # because that's the split every importer falls on: a platform API hands
  # out URLs to download (Tumblr, Bluesky), while an official export
  # archive already has the files on disk (Twitter, WordPress attachments).
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
    # How long to wait out a server that is throttling rather than
    # answering. Three one-second naps -- what this used to do -- walk
    # away from an archive that would have answered: a host that
    # rate-limits by REFUSING connections holds the door shut for tens of
    # seconds, and a rescue downloading hundreds of images is exactly the
    # traffic that provokes it. One run lost 36 of 37 pictures that way,
    # every failure a refused connection, while the code alongside it in
    # wayback.rb waited 15, 30, 45, 60 seconds and got everything it
    # asked for. Same shape here.
    RETRIES = 4
    RETRY_BACKOFF = 15

    # The failures worth waiting that long for: the server is there and
    # saying "not now". A name that does not resolve is a host that has
    # been gone for years -- routine in these archives -- and waiting two
    # minutes for each of its images would turn an import into an
    # overnight job, so those keep the old brief pause.
    THROTTLED = [Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT,
                 Net::OpenTimeout, Net::ReadTimeout].freeze

    attr_reader :failures, :reused

    # `index` is a MediaIndex (or nil): the archive's own answer to "have
    # I already fetched this address?", built once per run. With it, a
    # re-import over an archive that is already here costs no network at
    # all -- see MediaIndex for why the question can only be asked from
    # this side.
    #
    # `refetch` (REFETCH_MEDIA=1) stops the index being used to SKIP a
    # download, and nothing else. It deliberately does not switch the index
    # off: a refetch is exactly the run most likely to meet a source that
    # has since died, and without the archive's own copy to fall back on it
    # took 419 media entries out of 118 posts while all 419 files lay
    # untouched on disk.
    def initialize(tmpdir, dry_run: false, index: nil, refetch: false, root: nil)
      @tmpdir = tmpdir
      # The export's own directory. Every path from_file is handed is built
      # by joining strings the EXPORT supplied onto this, and nothing checked
      # the result was still inside it -- so `![x](../../../../etc/passwd)` in
      # a markdown file, or an attachment url of "/../../secret" in an
      # outbox, named any file on the importer's machine. It was copied into
      # media.nosync, the build copied it into public.nosync, and the next
      # deploy put it on the web. The dry run called it "one more media file".
      @root = root && File.expand_path(root.to_s)
      @outside = []
      @dry_run = dry_run
      @index = index
      @refetch = refetch
      @files = {}
      @failures = []
      @counter = 0
      @registered = 0
      @reused = 0
      # Dimensions the archive recorded for a file back when it was
      # written, for the one case where the bytes cannot answer -- see
      # dimensions.
      @remembered = {}
      # Files that live in the archive rather than in @tmpdir. Kept apart
      # because discard() deletes what it un-registers, and these are not
      # ours to delete.
      @kept = {}
      # allocated filename -> the address it came from, which the post
      # records as `src`. Without it written down, the next run has nothing
      # to look this file up by and downloads it all over again.
      @sources = {}
      # Copy-plan pairs @files cannot hold: one archive file standing in
      # for a SECOND name at once. A hand-mangled previous copy can leave
      # the index answering two different addresses with the same file,
      # and a plan keyed by source path then forgot one of the two names
      # -- the post kept the entry, and nothing anywhere was instructed
      # to put a file under it. See #files.
      @extra = []
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

    # The copy plan for PostWriter: [source_path, desired_filename] pairs.
    # A list rather than a hash, because a source path is not unique in
    # the plan -- one archive file can owe the post TWO names (reuse over
    # a hand-corrupted previous copy, where the index answers two
    # addresses with the same file). A hash keyed by source path could
    # only remember one of them, and the entry wearing the forgotten name
    # then hung in the post with no instruction to ever create its file.
    # Names stay unique; only sources repeat.
    def files
      @files.to_a + @extra
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
      # Only what an HTTP fetch could ever answer. A "cid:", "file:" or
      # "about:" reference has no host, so every attempt fails the same way
      # -- and the throttle backoff (15/30/45/60s) then spends minutes per
      # image on an address that was never fetchable. Recorded as a failure
      # so the summary still names it, and the number is spent so the
      # remaining files keep their places.
      unless url.to_s.match?(%r{\Ahttps?://[^/\s]}i)
        filename = allocate(extension_for(url))
        @failures << url
        @by_source[url] = nil
        uncount
        return nil
      end

      # What the archive already holds for this address. Asked before the
      # number is spent, because reuse takes its extension from the FILE
      # rather than from the address.
      held = @index&.entry_for(url)
      return reuse(url, held) if held && !@refetch

      filename = allocate(extension_for(url))
      if @dry_run
        @by_source[url] = filename
        return filename
      end

      body = self.class.fetch(url)
      if body.nil?
        # A fetch that failed must not cost the post a picture that is
        # lying on disk. Only REFETCH_MEDIA=1 reaches here with a file in
        # the archive -- it walked past the reuse above on purpose -- and
        # the copy it walked past is still the only copy there is.
        # Dropping the entry would erase the picture from the post
        # permanently, and on the next run just as surely, since there
        # would be nothing left to look it up by.
        return reuse(url, held, spent: filename) if held

        @failures << url
        # Remembered as a failure, not forgotten: a second reference to
        # the same dead URL in this post answers nil at once instead of
        # re-burning the retries and double-counting the loss.
        @by_source[url] = nil
        uncount
        return nil
      end

      # An address that answers 200 with an HTML PAGE is not a picture: a
      # parked domain, a login wall, a CDN's own "not found" page. The
      # bytes then land in the archive as NN.jpg, the run says "N media
      # file(s)" with no loss reported, `check` finds a file that exists
      # and is not empty and calls the archive sound -- and every reader
      # gets a broken image on a published page, permanently, because the
      # media index remembers the address as fetched. Two adapters carried
      # a comment claiming this defence existed; only wayback.rb had one.
      #
      # Counted as a failure, so the summary names the address the way it
      # names a fetch that never answered. An .html or .htm attachment is
      # somebody asking for a page on purpose and is left alone.
      if self.class.html_page?(body) && !filename.match?(/\.html?\z/i)
        # Same rule as a fetch that failed one branch up: a page served
        # where a picture should be is no reason to throw away the copy
        # this archive already holds. Only REFETCH_MEDIA=1 gets here with
        # a file on disk, and that copy is still the only copy there is.
        return reuse(url, held, spent: filename) if held

        @failures << url
        @by_source[url] = nil
        uncount
        return nil
      end

      path = File.join(@tmpdir, filename)
      File.binwrite(path, body)
      path, filename = retype(path, filename)
      @files[path] = filename
      @by_source[url] = filename
      @sources[filename] = url
      filename
    end

    # A file this archive already holds for that address: registered like a
    # download, minus the download.
    #
    # The extension comes from the FILE, never from the URL. retype renames
    # a download whose bytes contradict its address -- a .ico that is a PNG,
    # five of them in one real archive of 420 -- so the two genuinely
    # differ, and a name guessed from the URL would point the post at
    # something that is not there.
    #
    # The archive's own path goes straight into @files, with no copy into
    # the tmpdir: dimensions() reads the header from there just as happily,
    # and PostWriter.copy_media skips a destination that already exists, so
    # for the post the file belongs to source and destination are the same
    # path and nothing moves. For a DIFFERENT post that shares the picture
    # -- old blogs do this constantly -- it is copied across, which is
    # exactly what that post needs.
    #
    # `spent` is the number from_url had already allocated before a fetch
    # that then failed. Filenames must not depend on which fetches
    # succeeded -- that is the whole point of `uncount` -- so the number is
    # kept and only its extension is corrected to the one the bytes are
    # really filed under.
    def reuse(url, entry, spent: nil)
      ext = File.extname(entry.path)
      filename = spent ? "#{File.basename(spent, File.extname(spent))}#{ext}" : allocate(ext)
      @by_source[url] = filename
      @sources[filename] = url
      @reused += 1
      return filename if @dry_run

      # A second name for a file the plan already carries goes into the
      # extra pairs, never over the first: overwriting here is what used
      # to leave the first entry's name with no copy instruction at all.
      if @files.key?(entry.path) && @files[entry.path] != filename
        @extra << [entry.path, filename]
      else
        @files[entry.path] = filename
      end
      @kept[entry.path] = true
      # The dimensions the post recorded when this file was written. The
      # bytes are asked first and answer for nearly everything (see
      # dimensions); this is what is left when they cannot -- a video, an
      # SVG, or a picture some interrupted run left half-written. Handing
      # back nil instead would cost the post its reserved space and, in
      # Wayback's strip_fake_images, the image block itself.
      dims = entry.dimensions
      @remembered[filename] = dims if dims
      filename
    end

    # The address a registered file was fetched from, so the post can write
    # it down beside the local name. That record is the whole of what makes
    # the next run able to recognise the file.
    def source_of(filename)
      @sources[filename]
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
    #
    # Falls back on what the archive recorded for a file that was reused
    # rather than downloaded: the bytes on disk are the only ones there
    # are, some of them cannot be measured at all (a video, an SVG, a
    # half-written picture), and the alternative is handing back nil --
    # which costs the post its reserved space and, in Wayback's
    # strip_fake_images, the image block itself.
    def dimensions(filename)
      return nil if @dry_run

      path = @files.key(filename) || @extra.find { |_, name| name == filename }&.first
      dims = path && MediaDimensions.image(path)
      dims || @remembered[filename]
    end

    # Un-registers a downloaded file an adapter decided was not media
    # after all (the Wayback Machine answers missing images with an HTML
    # page and a 200) -- so the fake never gets copied into the post's
    # media directory.
    def discard(filename)
      return if @dry_run

      path = @files.key(filename)
      if path.nil?
        # A name living in an extra pair: only the pair is un-registered.
        # Its path is the archive's own file -- and possibly still the
        # primary pair's source -- so nothing on disk is touched.
        idx = @extra.index { |_, name| name == filename }
        return unless idx

        @extra.delete_at(idx)
        @by_source.delete_if { |_, name| name == filename }
        @sources.delete(filename)
        @remembered.delete(filename)
        @registered -= 1
        @reused -= 1
        return
      end

      @files.delete(path)
      # Or a later reference to the same source would resurrect a filename
      # whose bytes were just judged to not be media at all.
      @by_source.delete_if { |_, name| name == filename }
      @sources.delete(filename)
      @remembered.delete(filename)
      @registered -= 1
      # A file that came out of the archive is not ours to delete. The
      # judgement being made here is about bytes a fetch brought back, and
      # for a reused file there was no fetch -- deleting it would take the
      # picture off the post that already has it, on disk, for good.
      if @kept.delete(path)
        @reused -= 1
        return
      end

      begin
        File.delete(path)
      rescue SystemCallError
        nil
      end
    end

    # Registers a file the export already contains. Same contract as
    # from_url, minus the network.
    #
    # `src` is the address the file originally came from, where the export
    # happens to know it -- a tree written by `./blog.sh export` carries one
    # per file. Nothing can re-derive it from the bytes, so a re-import that
    # dropped it would leave the archive unable to recognise its own files
    # the next time round.
    # Whatever the export said, resolved -- symlinks included, since a link
    # inside the export pointing out of it is the same escape wearing a hat.
    # With no root given nothing is refused, which is what the callers that
    # never touch the filesystem get.
    def inside_export?(path)
      return true if @root.nil?

      root = resolved(@root)
      real = resolved(path)
      real == root || real.start_with?(root + File::SEPARATOR)
    end

    # realpath needs the file to exist, and half the paths this judges name a
    # file the export is MISSING -- which still has to be judged, and judged
    # as inside. So the deepest ancestor that does exist is resolved and the
    # rest is appended.
    #
    # Resolving only one side is not enough either: on macOS a temp directory
    # is /var/folders/... and /var is a symlink to /private/var, so a root
    # resolved against a path that was not read as "outside the export" for
    # every missing file in every test. Both sides, or neither.
    def resolved(path)
      full = File.expand_path(path.to_s)
      head = full
      tail = []
      until File.exist?(head)
        parent = File.dirname(head)
        break if parent == head

        tail.unshift(File.basename(head))
        head = parent
      end
      File.join(File.realpath(head), *tail)
    rescue StandardError
      File.expand_path(path.to_s)
    end

    # Paths an export named outside itself. Reported, never copied.
    def outside_export
      @outside
    end

    def from_file(path, src: nil)
      return nil if path.to_s.empty?
      return @by_source[path] if @by_source.key?(path)

      # Allocated BEFORE the existence check, exactly as from_url allocates
      # before the fetch: the number has to be spent whether or not this
      # file is here. Checking first meant numbering depended on WHICH
      # files happened to exist, so a staged or half-synced export gave
      # 01.jpg to the second picture -- and on the re-import that the
      # engine advertises as safe, PostWriter.copy_media skips a name that
      # already exists, leaving the post pointing at the previous run's
      # bytes. The wrong photo, published, silently.
      filename = allocate(File.extname(path))
      # The existence check used to be skipped in dry-run, so a preview of an
      # archive whose media tree is incomplete promised more posts and more
      # files than the real run could write, and the real run then dropped
      # the missing ones without naming them. A stat is not a fetch, so this
      # keeps the dry-run contract (nothing is read, written or downloaded).
      # Recorded rather than just skipped: the count is then honest AND the
      # summary still names what the archive is missing. Remembered as a
      # failure for the same reason from_url remembers one -- a second
      # reference to the same missing file must not count the loss twice.
      # Refused before it is opened, and said out loud: an export naming a
      # file outside itself is not a mistake to absorb quietly.
      unless inside_export?(path)
        warn "  refused (outside the export): #{path}"
        @outside << path
        @by_source[path] = nil
        uncount
        return nil
      end

      unless File.exist?(path)
        @failures << path
        @by_source[path] = nil
        uncount
        return nil
      end

      @by_source[path] = filename
      @sources[filename] = src.to_s unless src.to_s.empty?
      return filename if @dry_run

      @files[path] = filename
      filename
    end

    # Follows redirects and retries transient failures. Importing an
    # archive of a few thousand posts hits connection resets often enough
    # that a single one must not end an hours-long run -- so this returns
    # nil and lets the caller record a failure instead of raising.
    def self.fetch(url, redirects: 5, retries: RETRIES)
      # Exhaustion says so: this was the one failure path with no line at
      # all, so a redirect loop read as media that silently never came.
      if redirects.negative?
        warn "  fetch gave up on #{url}: too many redirects"
        return nil
      end

      # Parsed before the request, and separately: a URL that cannot parse
      # is a permanent answer, and burning three retries with sleeps on it
      # (as the generic rescue below used to) only slowed the run down.
      # Non-ASCII paths -- image filenames with diacritics are routine in
      # the very archives this engine imports -- are percent-encoded,
      # which is the same address.
      uri = parse_url(url)
      if uri.nil?
        warn "  fetch failed on #{url}: not a fetchable URL"
        return nil
      end

      res =
        begin
          Net::HTTP.get_response(uri)
        rescue StandardError => e
          if retries.positive?
            sleep backoff(retries, throttled: THROTTLED.any? { |kind| e.is_a?(kind) })
            return fetch(url, redirects: redirects, retries: retries - 1)
          end
          warn "  fetch gave up on #{url}: #{e.message}"
          return nil
        end

      case res
      when Net::HTTPRedirection
        # A relative Location ("/img/x.jpg") is legal and common; handing
        # it to the next round verbatim used to dial host "" and lose the
        # media after three pointless retries.
        target = begin
          URI.join(uri.to_s, res['location'].to_s).to_s
        rescue StandardError
          res['location']
        end
        fetch(target, redirects: redirects - 1, retries: retries)
      when Net::HTTPSuccess then res.body
      when Net::HTTPServerError, Net::HTTPTooManyRequests
        # "Not now", not "not there" -- the same distinction wayback.rb
        # draws. This used to fall through the case silently: any failed
        # status became a bare nil, no retry, no line saying why, and an
        # hours-long import ended with media quietly missing.
        if retries.positive?
          sleep backoff(retries, throttled: true)
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

    # Waits grow with each attempt, so the last one outlasts a throttling
    # window rather than four times the first one's guess.
    def self.backoff(retries, throttled:)
      return 1 unless throttled

      RETRY_BACKOFF * (RETRIES - retries + 1)
    end

    ESCAPER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

    def self.parse_url(url)
      URI(url)
    rescue URI::InvalidURIError
      begin
        URI(ESCAPER.escape(url))
      rescue URI::InvalidURIError
        nil
      end
    end

    private

    # An extension is whatever followed the last dot in a name somebody
    # else chose, and File.extname hands it over verbatim -- quotes,
    # angle brackets and slashes included. The build escapes it now, but
    # a filename is the wrong place to carry markup in the first place,
    # so nothing but letters and digits survives here. Anything else
    # means the archive was not describing a file type, and .bin says
    # what we actually know.
    # Deliberately narrow: an extension that is already harmless is kept
    # EXACTLY as it was, case and all, and a missing one stays missing.
    # Tidying those would rename media on re-import -- the one thing
    # numbering is careful about -- for no security gain. Only a name that
    # could not be a file type gets replaced.
    SAFE_EXT = /\A\.[A-Za-z0-9]{1,12}\z/.freeze

    def allocate(ext)
      @counter += 1
      @registered += 1
      ext = ext.to_s
      ext = '.bin' unless ext.empty? || SAFE_EXT.match?(ext)
      format('%02d%s', @counter, ext)
    end

    # A failed fetch is uncounted but its NUMBER stays spent. Giving the
    # number back read as tidiness and was a re-import bug with teeth:
    # numbering then depended on WHICH fetches succeeded, so a post whose
    # first image failed handed 01.jpg to its second image -- and when
    # the source recovered, the re-run (advertised as safe) assigned the
    # names the other way around while PostWriter's copy skips files that
    # already exist. Old bytes under a new name, the wrong image
    # published. With the number spent, registration ORDER is the only
    # thing filenames depend on, and every run of the same post agrees
    # with every other. The gap in the sequence on disk is the honest
    # trace of a fetch that failed.
    def uncount
      @registered -= 1
    end

    # The extension had to be guessed from the URL to allocate a name; now
    # the bytes are here and they know better. One real archive of 420
    # images held five files whose extension its own CDN contradicted --
    # image/jpeg served for an AVIF, a favicon called .ico that is a PNG --
    # and the wrong name follows the file onto the published site, where the
    # web server reads it to pick the content type.
    #
    # Only a format MediaDimensions recognises beyond doubt overrules the
    # URL, and only when the name isn't already one of that format's own
    # spellings, so .jpeg is never rewritten to .jpg. The NUMBER never
    # changes, which is what a re-import has to agree on, and the same bytes
    # always yield the same extension, so every run of the same post lands
    # on the same name.
    #
    # from_file is deliberately left out: what an export archive already has
    # on disk is the author's own naming, and renaming their files is not
    # this engine's business.
    def retype(path, filename)
      sniffed = MediaDimensions.sniff(path)
      ext = File.extname(filename)
      return [path, filename] if MediaDimensions.extension_agrees?(ext, sniffed)

      renamed = "#{File.basename(filename, ext)}#{sniffed}"
      dest = File.join(File.dirname(path), renamed)
      File.rename(path, dest)
      [dest, renamed]
    rescue SystemCallError
      # A rename that fails costs the file nothing: the bytes are still
      # under the name the post already believes in.
      [path, filename]
    end

    # The opening of an HTML document, whatever it claims to be. Deliberately
    # narrow: an SVG is XML too (and legitimate media), so only <html>,
    # <head> and a doctype naming html count, after an optional XML
    # declaration and any leading whitespace.
    HTML_PAGE = /\A\s*(?:<\?xml[^>]*\?>\s*)?(?:<!--.*?-->\s*)?(?:<!doctype\s+html|<html[\s>]|<head[\s>])/im

    def self.html_page?(body)
      head = body.to_s.byteslice(0, 1024).to_s
      HTML_PAGE.match?(head.force_encoding('BINARY'))
    rescue StandardError
      false
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
