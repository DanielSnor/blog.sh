# frozen_string_literal: true

# build/output.rb -- putting a file on disk, and taking one off again.
#
# The most dangerous machinery in the build, gathered in one place: the
# write that must not truncate what it replaces, the copy that must not
# go through a hardlink into the media archive, the permissions a page
# needs before a web server will serve it, and the sweep that deletes
# what this build did not produce.
#
# Everything here is about the filesystem rather than about a blog, and
# the numbers say so: emit is asked once per artefact, prune_public
# walks the whole output tree, and between them they are the only code
# in the engine that removes anything a reader might still be reading.
#
# WRITTEN, POST_DIGEST and BuildCache stay outside -- they are the
# build`s bookkeeping and half the file consults them. They resolve from
# in here anyway: a module body`s lexical scope ends at Object, which is
# where a script`s top-level constants live. TRAVERSED moved with the
# code because nothing else has ever asked it anything.
module Output
  module_function

  def world_readable?(path, stat = nil)
    PublicFile.readable?(path, stat)
  end

  # A file nobody can reach is as good as unreadable, so the directories on
  # the way to it get the same treatment -- read AND execute, since a
  # directory without +x cannot be entered even when it can be listed.
  #
  # Directories this run has already put right, so the walk below costs one
  # hash lookup per file after the first time it climbs a given branch.
  TRAVERSED = {}

  # Walks up to PUBLIC_DIR, stopping only at a directory THIS RUN has already
  # handled.
  #
  # It used to stop at the first directory that merely LOOKED right, on the
  # grounds that everything above it was made by the same code. That is false
  # the moment a new directory is created inside an old one that is wrong:
  # mkdir_p mints the new leaf at 0777 & ~umask, so publishing a post into a
  # year directory left at 0700 made a correct new page behind a shut gate --
  # the walk stopped on the child it had just created and never looked up.
  # The author then saw a 404 for the post they had just published, rebuilt,
  # and the build said "Postaveno" and changed nothing.
  def make_traversable(dir)
    path = File.expand_path(dir)
    root = File.expand_path(PUBLIC_DIR)
    while path.start_with?(root)
      break if TRAVERSED[path]

      mode = File.stat(path).mode & 0o7777
      File.chmod(mode | PUBLIC_TRAVERSABLE, path) unless (mode & PUBLIC_TRAVERSABLE) == PUBLIC_TRAVERSABLE
      TRAVERSED[path] = true
      parent = File.dirname(path)
      break if parent == path

      path = parent
    end
  rescue SystemCallError
    nil
  end

  def make_readable(path)
    PublicFile.make_readable(path)
  end

  # A page the build cache vouched for: kept, but not written.
  #
  # Everything emit() does BESIDES writing still has to happen, and the
  # permissions are the half that is easy to forget. A rebuild repairing a
  # public.nosync/ somebody chmod'ed shut is a promise made to a reporter
  # whose imported pictures were 600 and whose rebuild did nothing about it
  # -- "chmod, rebuild, nothing". A cache that skipped the repair along with
  # the write would have quietly taken that promise back on every page it
  # skipped, which is every page of an ordinary publish.
  #
  # Both halves, because they fail separately: a file at 644 behind a
  # directory at 744 is a file nobody can reach. make_traversable remembers
  # the directories it has already opened, so the walk up happens once per
  # directory rather than once per page.
  def keep(path)
    WRITTEN[path] = true
    make_traversable(File.dirname(path))
    make_readable(path) unless world_readable?(path)
  end

  def emit(path, content)
    # Every generated artefact comes through here, and the ones belonging to
    # a post carry its slug or its draft token in the path -- values that
    # come off a post file. A path that climbs out of public.nosync is a
    # file prune can never reach, and further up it is not the site's file
    # at all. The media loop below already guards its own filenames; the
    # directory those filenames are joined onto was never asked about.
    PathSafety.contained!(PUBLIC_DIR, path, 'build output')
    WRITTEN[path] = true
    bytes = content.to_s.b
    digest = Digest::SHA256.hexdigest(bytes)

    # What the last build left here, if it still is what it left. Hashing the
    # bytes we already hold in memory is cheaper than reading the file back
    # to compare it: on a 4,394-post archive the read-back was 2.81 s of an
    # 11.2 s build, and every byte of it was read to find out nothing had
    # changed. The record carries size and mtime as well as the digest, so a
    # file edited outside the build falls through to the honest comparison
    # below rather than being vouched for.
    # Through keep(), not a bare return: the directory walk below sits before
    # the old early return on purpose, and this return is earlier still. A
    # file at the right bytes and the right mode behind a directory at 744 is
    # a file nobody can fetch, and that is exactly the shape the walk was
    # added for.
    if BuildCache.written?(path, digest)
      keep(path)
      return
    end

    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    # Before the early return, not after. A file whose bytes AND mode are both
    # right can still sit behind a directory nobody can enter, and that is
    # precisely what `chmod -R a+r public.nosync` leaves behind: read without
    # execute, every directory at 744, every file at 644. The build was then
    # permanently blind to it -- it returned here on the matching bytes and
    # never reached the walk -- while rsync -az carried the 744 to the server
    # verbatim. Directories were half of what PUBLIC_TRAVERSABLE was added for
    # and the half that never got repaired.
    make_traversable(dir)
    # Permissions count as "up to date" too. Without this the fix below could
    # never reach a file that already exists with the wrong ones -- which is
    # what happened to the reporter: chmod, rebuild, nothing, because the
    # bytes matched and the build had nothing else to look at.
    if File.exist?(path)
      stat = File.stat(path)
      if File.binread(path) == bytes
        # The bytes are already right, so there is nothing to write and only
        # the mode can be wrong -- and make_readable is both the thing that
        # fixes it and the thing that forgives a file we do not own. Falling
        # through to binwrite here performed an UNRESCUED write purely to
        # carry a chmod, so a file we could not chmod (a foreign owner, uchg)
        # killed the build mid-loop with an Errno backtrace: no sitemap, no
        # sidebar, no search index, no prune, exit 1 -- on a rebuild that had
        # nothing to write in the first place.
        make_readable(path) unless world_readable?(path, stat)
        BuildCache.record(path, digest)
        return
      end
    end

    # Never THROUGH a second name -- see PublicFile.claim. Media arrive in
    # public.nosync/ as a link to the archive's own file, so an in-place write
    # here is a write into media.nosync/. And when the name cannot be made
    # ours, the answer is to leave it alone and say so: writing anyway is how
    # an attachment in the archive became a rendered page.
    unless PublicFile.claim(path)
      warn t('build.name_not_ours', path: path)
      return
    end

    # Not File.binwrite: that truncates the target first and finds out
    # afterwards whether it can write, so a full volume or a container
    # stopped mid-build left a page, a feed or the search index on disk at
    # half its length -- served, and byte-for-byte wrong. A sibling temp
    # renamed into place is either the old file or the new one. It also
    # means the write can no longer go THROUGH a hardlink into the media
    # archive: a rename replaces the name, it does not touch what the other
    # name still points at. PublicFile.claim above stays as the thing that
    # says so out loud rather than the only thing preventing it.
    AtomicWrite.binwrite(path, bytes)
    make_readable(path)
    BuildCache.record(path, digest)
  end

  # The same bargain as a post page, for the outputs made out of the whole
  # archive rather than out of one post: the feed, the sitemap, the search
  # index, the archive map. Their inputs are a list of posts, so their key is
  # the digests of that list -- and when it has not moved, the block is never
  # called and the work inside it never happens.
  #
  # The block matters as much as the key. Building the search index costs
  # half a second of reading every post's text; passing the finished bytes in
  # and then deciding not to write them would have spent all of it.
  def cached_emit(dest, key)
    if BuildCache.page_fresh?(dest, key)
      keep(dest)
      return
    end

    BuildCache.remember_page(dest, key)
    emit(dest, yield)
  end

  # The identity of a list of posts, in order. Order is part of it: the feed
  # and the archive both say something different when the same posts are
  # arranged differently.
  def posts_digest(list)
    Digest::SHA256.hexdigest(list.map { |post| POST_DIGEST[post['__path']] }.join(','))
  end


  # The site's favicon PNG wrapped in an ICO container, for /favicon.ico.
  #
  # Pages link the PNG directly, which every browser prefers anyway -- this
  # exists for the clients that never read the link and just request
  # /favicon.ico from the root: bots, feed readers, link-preview services,
  # older browsers. Without it each of those is a 404 in the log.
  #
  # An ICO may carry a PNG payload verbatim (a 22-byte header, then the file),
  # so this needs no image library and no second source file to keep in sync --
  # in the spirit of lib/qr_code.rb, the smallest correct slice of a format
  # rather than a dependency. Returns nil when there's no PNG to wrap, so a
  # site without a favicon simply doesn't get the file.
  def build_favicon_ico
    return nil unless File.exist?(FAVICON_PNG)

    png = File.binread(FAVICON_PNG)
    return nil unless png.start_with?("\x89PNG\r\n\x1a\n".b)

    # IHDR is the first chunk of every PNG: width and height are big-endian
    # 32-bit at offset 16. The ICO dimension fields are a single byte each and
    # 0 means 256, so anything larger can't be stated exactly -- browsers load
    # such a file fine but report it as 256, which for something drawn at
    # 16-32px is a distinction without a difference.
    width, height = png[16, 8].unpack('N2')
    header = [0, 1, 1].pack('v3') # reserved, type 1 = icon, one image
    entry = [
      width >= 256 ? 0 : width, height >= 256 ? 0 : height,
      0, 0,   # palette size (0 = not paletted), reserved
      1, 32,  # colour planes, bits per pixel
      png.bytesize, header.bytesize + 16
    ].pack('C4v2V2')

    header + entry + png
  end

  # Media is content-addressed by the migration/import step, so hashing every
  # file on every build would cost more than the copy it saves. Size alone used
  # to stand in for that -- on the stated grounds that media is never edited in
  # place, which stopped being true the moment `doctor --strip-location`
  # existed. That rewrites a photo where it lies AND keeps its exact byte
  # length on purpose, so the two assumptions met: the build saw the same size,
  # skipped the copy, and public.nosync kept the coordinates the archive had
  # just lost. The deploy then had nothing to upload and doctor reported the
  # site clean while the published photo still carried the place it was taken.
  # mtime costs one more stat of a file already being stat'd, and catches any
  # in-place edit rather than only that one.
  def emit_copy(src, dest, compare_content: false)
    WRITTEN[dest] = true
    dir = File.dirname(dest)
    FileUtils.mkdir_p(dir)
    # Before the early return, for the reason emit gives: a picture whose
    # bytes and mode are both right is still unreachable behind a directory
    # nobody can enter, and the return below never reached the walk.
    make_traversable(dir)
    if File.exist?(dest)
      # On a volume that ignores letter case or unicode form, File.exist?
      # answers yes for a file the directory writes differently -- and then
      # the copy is skipped, WRITTEN records the name we asked for, and
      # prune_public (which reads the REAL name from the directory) deletes
      # the file as an orphan. The page keeps its <img> and loses its
      # picture, on the site as well as here, because deploy --prune repeats
      # the deletion. So the file is renamed to the name being recorded
      # before anything else is decided.
      settle_name(dest)
      same = if compare_content
               File.binread(dest) == File.binread(src)
             else
               File.size(dest) == File.size(src) && File.mtime(dest) >= File.mtime(src)
             end
      # ...and readable, for the reason emit gives. A chmod changes neither
      # size nor mtime -- it moves ctime, which nothing here was reading -- so
      # a picture copied under a strict umask stayed unreadable through every
      # rebuild that followed.
      #
      # One inode under two names is the cheapest possible answer: nothing to
      # compare and nothing to write. An archive built before this existed
      # falls THROUGH here even when its copy is up to date, and is relinked
      # once -- otherwise it would keep paying twice for every file that
      # never changes, which for media is all of them.
      return if File.identical?(src, dest) && world_readable?(dest)
      return if links_impossible? && same && world_readable?(dest)
    end

    place_public(src, dest)
    # On a link this changes the mode of the ORIGINAL too -- one inode has one
    # mode. That is the intended direction: a media file the web server cannot
    # read is the bug this makes impossible, and an original that becomes
    # readable is what its owner was going to do by hand anyway.
    make_readable(dest)
  end

  # The same bytes under two names, paid for once. Measured on one real
  # archive: media.nosync and public.nosync held 1.8 GB each -- the same
  # 1.8 GB twice, and every import doubled again.
  #
  # Nothing in the build ever writes INTO a file under public.nosync: pages
  # are written whole by `emit`, and media arrives only through here. So the
  # two names cannot drift apart, and deleting one of them -- prune, or a
  # deploy with --prune -- only drops that name.
  def place_public(src, dest)
    # The name is dropped FIRST, and for both routes. It used to be dropped
    # only on the way to a link, so once one file had failed to link -- one
    # source owned by another uid, one immutable file, one media directory on
    # its own mount -- every later media file took the copy route with the
    # old name still in place. A copy onto an existing link reaches whatever
    # else wears it; a copy onto the source ITSELF is not a copy at all, and
    # FileUtils.cp answers that with an ArgumentError, which is not a
    # SystemCallError and was caught by nothing: the build died where it
    # stood, with the site half written, no prune and no cache saved.
    ours = PublicFile.claim(dest)
    unless links_impossible?
      begin
        File.unlink(dest) if ours && File.exist?(dest)
        File.link(src, dest)
        return
      rescue SystemCallError
        # A volume that refuses the first link will refuse the rest: a
        # separate mount for public.nosync (EXDEV), a source somebody else
        # owns (EPERM), a filesystem with a link limit (EMLINK). Asking again
        # per file would copy the whole archive on every build.
        @links_impossible = true
      end
    end

    unless ours
      warn t('build.name_not_ours', path: dest)
      return
    end

    FileUtils.cp(src, dest) unless File.identical?(src, dest)
  rescue ArgumentError, SystemCallError => e
    # One picture that cannot be placed is one picture missing from one page.
    # Saying so and carrying on is the proportionate answer; the alternative
    # took the entire site down over it.
    warn t('build.media_unplaceable', path: dest, reason: e.message)
  end

  def links_impossible?
    @links_impossible == true
  end

  # Make the directory write the name we are about to record. Only ever a
  # case-or-form rename of one and the same file: the entry is found by
  # identity (dev+ino), never by string comparison.
  def settle_name(dest)
    dir = File.dirname(dest)
    wanted = File.basename(dest)
    children = Dir.children(dir)
    return if children.include?(wanted)

    actual = children.find { |name| File.identical?(File.join(dir, name), dest) }
    return if actual.nil?

    source = File.join(dir, actual)
    File.rename(source, dest)
    # On a case-sensitive volume a rename between two unicode forms of one
    # name is a no-op: the directory still writes the old one, and
    # prune_public would then delete it as an orphan. Copy under the name we
    # mean, and take the old entry away.
    return if Dir.children(dir).include?(File.basename(dest))

    FileUtils.cp(source, dest)
    File.delete(source) unless File.identical?(source, dest)
  rescue SystemCallError
    nil
  end

  # A single pass over public/ -- walking it twice (files separately from
  # directories) costs real time once there are thousands of entries, since
  # stat-ing each one isn't free, especially on a cloud-synced volume.
  def prune_public
    dirs = []
    removed = 0
    PathGlob.under(PUBLIC_DIR, '**', '*', flags: File::FNM_DOTMATCH).each do |path|
      if File.directory?(path)
        dirs << path
      elsif !WRITTEN[path]
        begin
          File.delete(path)
          removed += 1
        rescue SystemCallError => e
          # One file that will not go is one stale file on the site. It used
          # not to be able to matter, because the sweep only ran on builds
          # where something had dropped out of the record -- now it runs on
          # every build, so a single unlinkable orphan (one Locked in the
          # Finder, one left behind by a cron that ran as root in an install
          # that otherwise builds as somebody else) would abort EVERY build
          # from then on, mid-sweep, with the cache never saved. The rmdir
          # twelve lines down has always rescued; this never did.
          warn t('build.prune_failed', path: path, reason: e.message)
        end
      end
    end
    # Nothing deleted means no directory could have been orphaned.
    return 0 if removed.zero?

    # Deepest directories first, so emptied trees collapse all the way up.
    dirs.sort_by { |d| -d.length }.each do |dir|
      Dir.rmdir(dir) if Dir.empty?(dir)
    rescue SystemCallError
      nil
    end
    removed
  end
end
