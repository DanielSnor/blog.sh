require 'json'
require 'fileutils'
require 'securerandom'
require 'digest'
require 'time'
require_relative 'atomic_write'
require_relative 'post_address'
require_relative 'address_guard'
require_relative 'post_versions'
require_relative 'exif_location'
require_relative 'media_dimensions'
require_relative 'site_config'
require_relative 'i18n'
require_relative 'path_glob'

module PostWriter
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  MEDIA_DIR = File.join(ROOT, 'media.nosync')
  MEDIA_KEYS = %w[media poster].freeze

  # post: hash matching the post schema (slug, title, date, state, tags, content, source)
  # media_files: [source_path, desired_filename] pairs to copy into
  # media/<year>/<slug>/. A list, not a hash, because one source file can
  # owe the post two names at once (Import::Media#files); a hash -- which
  # the authoring CLI still hands over -- converts on the way in, and its
  # one-name-per-source shape loses nothing there, where every source is a
  # distinct file of the author's own. Names are unique either way; only
  # sources may repeat.
  def self.write(post, media_files: {})
    media_files = media_files.to_a
    date = Time.parse(post.fetch('date'))
    year = date.year.to_s

    # A post already imported from this exact source item is UPDATED, not
    # duplicated -- "matched on their source id" is a promise README and the
    # docs both make, and until now it only held while the slug-producing
    # text at the source never changed. A fixed typo in an RSS title, an
    # edited toot, and the re-import minted a second post under the new
    # slug while the old one sat next to it.
    #
    # The existing slug is kept on purpose: the URL is published, links and
    # announcement toots point at it, and a re-import must never move it
    # just because a title was edited at the source.
    existing_path = find_by_source(post['source'])
    if existing_path
      post = post.merge('slug' => File.basename(existing_path, '.json'))
      return update_matched(existing_path, post, year, media_files)
    end

    dir = File.join(CONTENT_DIR, year)
    FileUtils.mkdir_p(dir)
    # The name is taken by CREATING the file, not by finding it free.
    # Looking and then writing are two steps with a media copy in between,
    # and two runs that start together (a delivery from a phone while an
    # import is running, two phones at once) both saw the same name free:
    # the second one's file replaced the first one's, and both callers
    # were told it had gone well. What claim_slug hands back is a name
    # nobody else can still be holding.
    #
    # `previous` comes back with it. The name can be settled and STILL
    # have a past: claim_slug hands the same name back when the source id
    # matches the file already sitting there (the cold-index fallback),
    # and that file is a previous copy in every sense the two calls below
    # care about.
    post, previous, claimed = claim_slug(post, dir, year)
    slug = post.fetch('slug')
    path = File.join(dir, "#{slug}.json")
    # claim_slug settles the FILE name; it says nothing about the address.
    # An imported page is served at the root, where a page already standing
    # there has no year to be told apart by -- so the import wrote both,
    # reported success, and left an archive whose two pages share one
    # address. Raised, not aborted: the per-item rescue counts it, names it,
    # and the rest of the import goes on.
    #
    # Asked BEFORE a single file is copied. Refusing after the media were
    # already on disk left an orphaned directory behind, which claim_slug
    # then counted as an occupied name -- so running the very same import
    # again put the post somewhere else. An import that is refused has to
    # leave the archive exactly as it found it, or it is not repeatable.
    taken = AddressGuard.occupant(post, content_dir: CONTENT_DIR, slug: slug,
                                  except: path, path: path)
    if taken
      raise "cannot write '#{slug}': a different post is already served at that address " \
            "(#{File.join(File.basename(File.dirname(taken)), File.basename(taken))}) -- " \
            'resolve the slug clash by hand'
    end

    media_files = reconcile_media_names(post, previous, year, slug, media_files)
    copy_media(media_files, year, slug)
    sync_media_dimensions(post, year, slug, previous: previous)

    AtomicWrite.write_json(path, post)
    index[source_key(post['source'])] = path if source_key(post['source'])
    path
  rescue Exception # rubocop:disable Lint/RescueException -- a signal must not leave the reservation behind either
    # A write that is refused has to leave the archive exactly as it found
    # it -- and that now includes the name it had only reserved. Left
    # behind, the reservation would push the next attempt at the same post
    # onto a serial nobody asked for. Exception, not StandardError: Ctrl-C
    # in the middle of the media copy is not a StandardError, and it left
    # exactly the orphan this rescue promises never to leave. And the
    # media directory the copy had begun goes too, when it is empty --
    # compose_post takes a directory that exists for a name that is taken.
    File.delete(path) if claimed && path && File.exist?(path)
    if claimed && slug
      dir_started = File.join(MEDIA_DIR, year, slug)
      Dir.rmdir(dir_started) if Dir.exist?(dir_started) && Dir.empty?(dir_started)
    end
    raise
  end

  # media.strip_location, on unless a site says otherwise. On by default
  # because the cost of the wrong default is asymmetric: a photographer who
  # wants coordinates in their archive notices they are missing and turns
  # this off, while somebody who never knew phones write them finds out from
  # a stranger who read them off the web.
  def self.strip_location?
    SiteConfig.get('media', 'strip_location', default: true) != false
  end

  # Nothing here ever replaces a file the archive already holds, and that
  # is a decision rather than an omission. An import brings bytes from
  # somewhere nobody in this process can vouch for: a source that has been
  # sold answers an image URL with a parked page at a straight-faced 200,
  # a CDN that has had enough answers with 27 bytes of HTML, and a
  # re-import that wrote those over the archive would destroy the only
  # copy left of a picture -- quietly, at the scale of a whole run. So an
  # import only ever ADDS what is missing. Repairing a damaged archive is
  # a separate job with a separate confirmation; `./blog.sh check` is
  # where it starts.
  def self.copy_media(media_files, year, slug)
    return if media_files.empty?

    media_dir = File.join(MEDIA_DIR, year, slug)
    FileUtils.mkdir_p(media_dir)
    media_files.each do |src_path, filename|
      dest = File.join(media_dir, filename)
      next if File.exist?(dest)

      # Copied beside the destination and renamed into place, rather than
      # written straight to it. "Skip what already exists" is what makes a
      # re-import safe, and a copy interrupted halfway -- Ctrl-C, a full
      # disk, a container that went away -- leaves a truncated file that
      # every later run then skips, so the half-image publishes and no
      # amount of re-importing replaces it. A rename either happened or it
      # did not, so the only file under the real name is a complete one.
      copy_media_file(src_path, dest)
    end
  end

  # One file into the archive, the only way the archive accepts one.
  #
  # Split out of copy_media because `edit` had grown a bare FileUtils.cp
  # of its own, so `./blog.sh add` published a phone photo with no
  # coordinates in it and `./blog.sh edit` published the SAME photo with
  # the author's back garden still in it -- the one thing the docs promise
  # about media, broken on the path people use most. One promise wants one
  # implementation.
  #
  # `replace:` is where the two callers genuinely differ. An import never
  # replaces bytes the archive already holds (the paragraph above says
  # why); a person attaching a file to their own post under a name that is
  # already in the folder means to replace it, and always has.
  def self.copy_media_file(src_path, dest, replace: false)
    return if !replace && File.exist?(dest)
    # A directory or a device is not a picture, and FileUtils.cp on one
    # dies halfway through the save with a raw EISDIR.
    raise ArgumentError, "#{src_path} is not a file" unless File.file?(src_path)

    FileUtils.mkdir_p(File.dirname(dest))
    # Copied beside the destination and renamed into place: a copy
    # interrupted halfway leaves a .part nobody serves rather than a
    # truncated picture under the real name.
    tmp = File.join(File.dirname(dest), ".#{File.basename(dest)}.part")
    begin
      FileUtils.cp(src_path, tmp)
      # On the copy, never on the author's own file: what sits in
      # incoming/ or in a photo library is theirs, and the archive's
      # copy is the one about to be published. Between the cp and the
      # rename is the one moment the file is the engine's alone.
      ExifLocation.strip_file(tmp) if strip_location?
      File.rename(tmp, dest)
    rescue Exception # rubocop:disable Lint/RescueException -- a .part must not survive a signal either
      begin
        File.delete(tmp)
      rescue StandardError
        nil
      end
      raise
    end
  end

  # A media file's identity is the address it came from, not its position
  # in the post. Importers number files in the order the source lists them
  # (01, 02, ...) and copy_media never replaces an existing file -- two
  # rules that are each right alone and together mis-attributed pictures
  # the moment the source dropped, added or reordered one: the new "01"
  # landed on the old 01's bytes, so a gallery showed its first picture
  # twice and passed another off as a third. Measured on a real Ghost
  # post, not conjectured.
  #
  # So before anything is copied, an entry whose address any copy of this
  # post has ever known -- the one being replaced, or a kept version of it
  # -- takes back the filename it had, and a genuinely new file is steered
  # clear of every name anything answers for, on disk or in this run.
  # Entries with no address are recognised by their BYTES where the plan
  # still has them (see reconcile_positional); only when the bytes answer
  # nothing does the positional name stand, because renaming on a guess
  # would mint fresh files on every run of a tree import.
  # A set of media names that answers the way the FILESYSTEM answers, not
  # the way a Hash does. Only ever asked "is this name spoken for?", so it
  # keeps nothing but the folded spellings.
  class FoldedNames
    def initialize(names = [])
      @names = {}
      Array(names).each { |name| add(name) }
    end

    def key?(name)
      @names.key?(name.to_s.downcase)
    end

    def add(name)
      @names[name.to_s.downcase] = true
    end

    # `used[name] = true` reads better at the call sites than add(name),
    # and this is the whole of what the callers ever store.
    def []=(name, _value)
      add(name)
    end
  end

  def self.reconcile_media_names(post, previous, year, slug, media_files)
    dir = File.join(MEDIA_DIR, year, slug)
    old_names = {}
    each_media_entry(previous || {}) do |entry, _block|
      src = entry['src'].to_s
      name = entry['url'].to_s
      old_names[src] = name if !src.empty? && plain_media_name?(name) && !old_names.key?(src)
    end
    # An entry whose bytes are being taken from this post's own directory
    # already has a name there: the path in media_files says so. This is
    # what recognises a reuse the index served out of the post's own
    # directory, address or no address.
    own = {}
    media_files.each do |src_path, alloc|
      next unless File.dirname(src_path) == dir

      base = File.basename(src_path)
      own[alloc] = base if plain_media_name?(base)
    end
    on_disk = Dir.exist?(dir) ? Dir.children(dir).reject { |f| f.start_with?('.') } : []
    # Only a post with no remembered names, no reused files AND an empty
    # directory has nothing to reconcile against. The directory is part of
    # that test on purpose: a previous copy with no media at all (the
    # source dropped every picture for one cycle) used to slip through
    # here, and the returning pictures were then never confronted with the
    # files lying on disk -- [pes, kocka] -> drop -> [kocka, pes] swapped
    # the two identities in place.
    return media_files if old_names.empty? && own.empty? && on_disk.empty?

    # The durable half of the memory. `previous` only remembers the
    # CURRENT set, so a picture dropped in one re-import and returned in
    # the next is missing from it -- and treating the return as an arrival
    # minted a fresh copy (or, after a re-encode at the source, a copy per
    # cycle) of a file the archive held all along. The kept versions of
    # this post remember what `previous` has forgotten. Loaded lazily:
    # only an addressed entry nothing else recognises is worth the read.
    version_names(post, old_names, slug, year)

    sha_cache = {}
    rename = {}
    keeps = []
    arrivals = []
    positional = []
    each_media_entry(post) do |entry, _block|
      name = entry['url'].to_s
      src = entry['src'].to_s
      next unless plain_media_name?(name)

      wanted = (old_names[src] unless src.empty?) || own[name]
      if wanted.nil?
        if src.empty?
          keeps << name
          positional << name
        else
          arrivals << name
        end
      elsif wanted == name
        keeps << name
      else
        rename[name] = wanted
      end
    end

    # Entries with no address, recognised by their bytes -- resolved
    # BEFORE the rename claims are settled, so a positional entry that
    # moves to the file it matches vacates a name an addressed entry may
    # be waiting for. Addressed claims keep their precedence: the moves
    # only ever target names no keep and no pending rename answers for.
    moves = reconcile_positional(positional, keeps, rename, media_files, dir, on_disk, sha_cache)

    # A rename target has to be free. An entry with no address whose bytes
    # settle nothing keeps its positional name -- so a recognised entry
    # whose old name is now held by one of those, or claimed by an earlier
    # rename (two entries of a hand-edited previous copy claiming one
    # name, or a kept version remembering a name that has since changed
    # hands), is demoted to an arrival instead: a fresh name, its own
    # bytes. Two entries must never end up sharing a name; that was the
    # gallery defect this method exists to prevent.
    taken = keeps.to_h { |n| [n, true] }
    moves.each_value { |target| taken[target] = true }
    rename.keys.sort.each do |name|
      target = rename[name]
      if taken.key?(target)
        rename.delete(name)
        arrivals << name
      else
        taken[target] = true
      end
    end
    rename.merge!(moves)

    # Folded, because a directory is not a hash: `copy_media` asks the
    # VOLUME whether the destination exists, and on macOS (and on any
    # Windows share) 01.JPG answers for 01.jpg. Media#allocate keeps the
    # source URL's extension exactly as it was, case and all, so 01.JPG is
    # an ordinary name in a real archive -- Posterous served
    # IMG_2669.JPG, and a decade of cameras wrote nothing else. A
    # byte-exact lookup then handed a new picture the name 01.jpg
    # believing it free, copy_media saw the folded name and skipped the
    # copy, and the arrival's bytes were never written anywhere: the post
    # showed the OLD picture twice and the new one was gone, with `check`
    # reporting a reassuring "misnamed" and no loss.
    #
    # Folded on every volume, not only where it matters. An archive is
    # copied between machines, and a name that is free on Linux and taken
    # on macOS is a picture that disappears when somebody moves their
    # site.
    used = FoldedNames.new(on_disk + rename.values + keeps)
    arrivals.uniq.each do |name|
      # An arrival is not always a stranger: a picture dropped in one
      # re-import and brought back in the next arrives as a fresh
      # download, and an unclaimed file on disk may be its own orphaned
      # copy. The bytes decide: identical means reunion (the copy is then
      # skipped as always), different means the file belongs to somebody
      # else. The arrival's own positional name is asked first; failing
      # that, every name on disk that nothing claims -- and that pass
      # runs whether or not the arrival's allocated name collides,
      # because a dead URL in the batch burns a number and hands the
      # return a FREE name, which used to slip past the reunion and mint
      # a byte-identical duplicate of the orphan. Only a claimed name
      # outranks matching bytes: the address decides ownership, the
      # bytes only ever decide identity.
      src_path = plan_source(media_files, name)
      if used.key?(name) && !taken.key?(name) && on_disk.include?(name) &&
         same_bytes?(src_path, File.join(dir, name), sha_cache)
        used[name] = true
        taken[name] = true
        next
      end
      reunion = src_path && File.file?(src_path) && on_disk.sort.find do |cand|
        cand != name && !taken.key?(cand) && plain_media_name?(cand) &&
          same_bytes?(src_path, File.join(dir, cand), sha_cache)
      end
      if reunion
        rename[name] = reunion
        taken[reunion] = true
        used[reunion] = true
        next
      end
      unless used.key?(name)
        used[name] = true
        next
      end
      ext = File.extname(name)
      n = 1
      n += 1 while used.key?(format('%02d%s', n, ext))
      fresh = format('%02d%s', n, ext)
      rename[name] = fresh
      used[fresh] = true
    end

    final = rename.empty? ? media_files : media_files.map { |src_path, name| [src_path, rename.fetch(name, name)] }
    tally_superseded(final, dir, sha_cache)
    return final if rename.empty?

    each_media_entry(post) do |entry, _block|
      to = rename[entry['url'].to_s]
      entry['url'] = to if to
    end
    final
  end

  # The names this post's kept versions remember for addresses `previous`
  # no longer carries, merged into old_names -- first seen wins, newest
  # version first, and nothing already known is overwritten, so the copy
  # being replaced always outranks its own history. Read only when some
  # addressed entry is otherwise unrecognised: versions are a directory of
  # files, and every other write has no reason to open them. A version
  # that will not parse is skipped, not obeyed and not fatal. A version
  # that parses but LIES -- hand-forged to map an address at an orphan
  # holding some other picture's bytes -- is obeyed: from here it is
  # indistinguishable from the legitimate case this memory exists for, a
  # source that re-encoded a picture whose old bytes the archive keeps.
  # The same boundary the previous copy has always had under hand
  # corruption, with the same repair: delete the file, REFETCH_MEDIA=1.
  #
  # A name a newer memory has already promised to some other address is
  # off limits, and not only as a key: a stale version can remember a name
  # that has since changed hands, and taking its word would let the OLD
  # claim win whenever the numbering happened to deal it that name as a
  # keep -- evicting the rightful entry into a fresh copy. The newer
  # memory decides; the address the version spoke of arrives instead, and
  # the reunion pass in the caller still finds its bytes where they lie.
  def self.version_names(post, old_names, slug, year)
    unknown = false
    each_media_entry(post) do |entry, _block|
      src = entry['src'].to_s
      unknown ||= !src.empty? && !old_names.key?(src)
    end
    return unless unknown

    promised = old_names.values.to_h { |name| [name, true] }
    PostVersions.list(slug, year, content_dir: CONTENT_DIR).each do |path|
      version = begin
        JSON.parse(File.read(path, encoding: 'utf-8'))
      rescue StandardError
        nil
      end
      next unless version.is_a?(Hash)

      each_media_entry(version) do |entry, _block|
        src = entry['src'].to_s
        name = entry['url'].to_s
        next if src.empty? || !plain_media_name?(name)
        next if old_names.key?(src) || promised.key?(name)

        old_names[src] = name
        promised[name] = true
      end
    end
  end

  # Entries with no address, recognised by the second identity: their
  # bytes. A tree import hands these over by position, and a source-side
  # swap of two local files used to swap their identities in the post --
  # each entry took the other's name, dimensions and bytes, forever,
  # because "no address" read as "nothing to recognise them by". The plan
  # still has the file itself, and when the bytes under the positional
  # name disagree, a file in the post's directory with the SAME bytes says
  # which name this entry has carried all along.
  #
  # Addressed claims come first: a keep and a pending rename target are
  # both off limits. Two identical no-address entries cannot both have the
  # matched file -- the first (in post order) takes it, the next stays
  # where it is. And an entry the bytes cannot place FALLS BACK to its
  # positional name, never to a fresh mint: minting here would create new
  # files on every run of a tree import, which is the one thing positional
  # naming has always been careful not to do. The cancellation loop keeps
  # the fallbacks honest -- a move onto the position of an entry that
  # stayed put would make two entries share a name.
  #
  # Returns {current name => matched name}; `keeps` loses the movers.
  def self.reconcile_positional(positional, keeps, rename, media_files, dir, on_disk, sha_cache)
    return {} if positional.empty?

    movable = {}
    positional.each do |name|
      src_path = plan_source(media_files, name)
      # Bytes to compare are only in hand for a file the plan takes from
      # OUTSIDE the post's directory: a reuse from inside it is already
      # recognised (own), and a failed fetch left nothing to measure.
      next unless src_path && File.file?(src_path) && File.dirname(src_path) != dir
      # Bytes in place -- the everyday tree re-import. Nothing to solve.
      next if same_bytes?(src_path, File.join(dir, name), sha_cache)

      movable[name] = src_path
    end
    return {} if movable.empty?

    claimed = (keeps - movable.keys).to_h { |n| [n, true] }
    rename.each_value { |target| claimed[target] = true }

    moves = {}
    movable.each do |name, src_path|
      match = on_disk.sort.find do |cand|
        cand != name && !claimed.key?(cand) && !moves.value?(cand) && plain_media_name?(cand) &&
          same_bytes?(src_path, File.join(dir, cand), sha_cache)
      end
      moves[name] = match if match
    end

    # An entry that found no match stays on its position -- and every move
    # onto a STAYING entry's position is cancelled, which can strand the
    # mover on its own position and cancel another move in turn. Swaps and
    # rotations survive this loop untouched: every member of the cycle
    # moves, so no target is a name anybody kept.
    loop do
      staying = movable.keys.reject { |n| moves.key?(n) }
      clash = moves.find { |_, target| staying.include?(target) }
      break unless clash

      moves.delete(clash[0])
    end

    moves.each_key { |name| keeps.delete(name) }
    moves
  end

  # The plan pair behind an allocated name. media_files is a list of
  # pairs rather than a hash -- one source file can owe the post two
  # names -- so Hash#key has no direct equivalent; names are unique in
  # the plan, so the first pair carrying the name is the only one.
  def self.plan_source(media_files, name)
    pair = media_files.find { |_, alloc| alloc == name }
    pair && pair[0]
  end

  # Byte identity, sized first so the hash is only ever paid for files
  # that could be the same file. The cache is per reconcile call: the same
  # on-disk file gets asked about by several entries in one pass, and once
  # per pass is what a hash of it is worth.
  def self.same_bytes?(a, b, cache)
    return false unless a && b && File.file?(a) && File.file?(b)
    return false unless File.size(a) == File.size(b)

    sha = ->(path) { cache[path] ||= Digest::SHA256.file(path).hexdigest }
    sha.call(a) == sha.call(b)
  end

  # How many incoming files this write discarded in favour of the
  # archive's own copy under the same name -- a source that re-encoded a
  # picture and kept its address, mostly. copy_media skips those silently
  # (an import only ever adds), and silence here cost an operator the one
  # fact worth acting on: the source no longer serves what the archive
  # holds. Counted per process, read as a delta by Import::Run, said in
  # the summary. Byte-identical skips are not counted -- a plain re-import
  # discards every download it was told to make, and that is reuse, not
  # news.
  def self.superseded_downloads
    @superseded_downloads ||= 0
  end

  def self.tally_superseded(media_files, dir, sha_cache)
    # Anything sourced from inside the archive -- this post's directory
    # or any other post's -- is a REUSE the index served, not a download:
    # counting it said "the source has drifted" on a plain re-import that
    # fetched nothing, once per run, forever. Only bytes brought in from
    # outside the archive can be news about the source.
    archive = File.expand_path(MEDIA_DIR) + File::SEPARATOR
    media_files.each do |src_path, name|
      next if File.expand_path(src_path).start_with?(archive)

      dest = File.join(dir, name)
      next unless File.file?(src_path) && File.file?(dest)

      @superseded_downloads = superseded_downloads + 1 unless same_bytes?(src_path, dest, sha_cache)
    end
  end

  # Makes the post describe the file that is actually in the archive.
  #
  # An importer measures the bytes it just fetched and writes the numbers
  # into the block; copy_media above then declines to overwrite a file that
  # is already there. Both are right on their own, and together they let a
  # post state 400x600 over a 26-byte file -- with scripts/check.rb calling
  # the archive healthy, because the file exists and the numbers are
  # present. Nothing before this point can close that gap: the adapter does
  # not know the year and the slug, so it cannot name the destination, and
  # here is the first place both are settled.
  #
  # Only entries whose file IS in the archive; one whose file never
  # arrived is left saying exactly what it said. When the bytes answer,
  # they decide. When they do not, see the two cases below -- the answer
  # is neither "keep" nor "drop" but "what this post said last time".
  def self.sync_media_dimensions(post, year, slug, previous: nil)
    media_dir = File.join(MEDIA_DIR, year, slug)
    remembered = remembered_sizes(previous)
    each_media_entry(post) do |entry, _block|
      name = entry['url'].to_s
      next unless plain_media_name?(name)

      path = File.join(media_dir, name)
      next unless File.file?(path)

      width, height = MediaDimensions.image(path)
      if width && height
        entry['width'] = width
        entry['height'] = height
      else
        was = remembered_for(remembered, name, entry)
        if was.nil?
          # Nothing was ever said about this name or address: the file
          # just landed for the first time, nothing was discarded, and
          # whatever numbers the entry carries are the source's own
          # metadata -- a video's stated size, which no image reader here
          # ever measured. Kept.
        elsif was[0] && was[1]
          # The file is here, its bytes say nothing, and this post spoke
          # about it before. What it said is the last record of what the
          # picture was -- and this run's numbers, if different, were
          # measured from a download copy_media then did not write.
          entry['width'] = was[0]
          entry['height'] = was[1]
        else
          # The previous copy knew this file and said nothing, because it
          # could not be measured then either. This run's numbers describe
          # bytes the archive does not hold; the honest answer is the one
          # the post already gave.
          entry.delete('width')
          entry.delete('height')
        end
      end
    end
  end

  # What the copy of this post that is being replaced said about its own
  # media, keyed the two ways an entry can be recognised again: by the
  # address it came from, which survives a renumbering, and by the file
  # name, which is all a post written before `src` existed carries.
  def self.remembered_sizes(previous)
    sizes = { 'src' => {}, 'url' => {} }
    return sizes unless previous.is_a?(Hash)

    each_media_entry(previous) do |entry, _block|
      # [nil, nil] is an answer too: "this post knew the file and said
      # nothing about its size". Skipping those made a file seen before
      # indistinguishable from a file seen for the first time -- which is
      # exactly the gap a REFETCH run stamped its discarded numbers into.
      pair = [entry['width'], entry['height']]
      sizes['src'][entry['src'].to_s] = pair unless entry['src'].to_s.empty?
      sizes['url'][entry['url'].to_s] = pair unless entry['url'].to_s.empty?
    end
    sizes
  end

  def self.remembered_for(sizes, name, entry)
    sizes['src'][entry['src'].to_s] || sizes['url'][name]
  end

  # Every media entry in a post: the files themselves, and a video's
  # poster, which is a file with an address of its own. The block comes
  # with it -- what an entry means depends on what it is part of, and a
  # caller that has to guess from the filename is the guess this engine
  # got wrong twice.
  def self.each_media_entry(post)
    Array(post['content']).each do |block|
      next unless block.is_a?(Hash)

      MEDIA_KEYS.each do |key|
        entries = block[key]
        next unless entries.is_a?(Array)

        entries.each { |entry| yield entry, block if entry.is_a?(Hash) }
      end
    end
  end

  # A media url is a bare filename by construction (the importer allocates
  # "01.jpg"), and callers join it onto a directory -- so anything with a
  # separator or a leading dot in it is not a name to follow. A post JSON
  # is a file on disk that people do edit by hand.
  def self.plain_media_name?(name)
    !name.empty? && !name.start_with?('.') && !name.include?('/') && !name.include?('\\')
  end

  # Overwrites the matched post in place -- or moves it when the source
  # changed the item's date across a year boundary, since the build derives
  # both the URL and the media lookup from the date, and a file left in the
  # old year's directory with a new year's date loses its images (the same
  # inconsistency prompt_and_schedule used to create).
  def self.update_matched(existing_path, post, year, media_files)
    slug = post['slug']
    old_year = File.basename(File.dirname(existing_path))

    # Engine-side state the source can never know about. A re-import that
    # dropped mastodon_url severed the announcement thread -- the post's
    # stats and comments both hang off it -- which is the exact bug cmd_edit
    # had and fixed. state and draft_token are deliberately NOT carried
    # over: what the source says about published/draft wins on re-import,
    # same as it always has.
    old = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    # former_slugs is in the list for the same reason as the announcement
    # URLs: a rename is engine-side history the source can never know
    # about, and dropping it would break every redirect the post carries.
    # pinned and created_at joined it in 1.1 -- the pin is engine-side
    # state (the source has no notion of a front page) and created_at is
    # the draft-era timestamp the publish "was the date edited?" check
    # reads; both were silently dropped on re-import until named here. The
    # guard below only carries a key the importer did not set itself, so an
    # importer that legitimately provides one still wins. `type` stays out:
    # absent, the build re-derives it from the (re-imported) blocks, so it
    # comes back on its own.
    # page, series and series_part joined the list in 1.3. Same rule as the
    # rest: carried over only when the importer said nothing itself, so an
    # adapter that DOES recognise a page still wins, and a series -- which
    # no source has a notion of -- survives every re-import.
    %w[mastodon_url bluesky_url bluesky_uri former_slugs unpublished_from pinned created_at
       page series series_part].each do |key|
      post[key] = old[key] if old && old[key] && !post[key]
    end
    # redirect_from is the one key where "the importer set it itself" is NOT
    # a reason to drop what the post already carried, so it cannot ride in
    # the list above. A post collects old addresses from several places --
    # the importer that understands the source platform, scripts/backfill_
    # redirects.rb, another platform's importer before this one, and an
    # author typing in the addresses a dead blog used to answer for. Each of
    # those knows about a different past, and none of them knows about the
    # others. Under the old guard a re-import with KEEP_PERMALINKS=1 wrote
    # its own single address over all of them, so the stubs the build had
    # been serving stopped being built and every one of those addresses
    # started answering 404 -- silently, with nothing in the summary. Union,
    # old first, so once merged a further re-import adds nothing and the
    # order never moves.
    merged = (Array(old && old['redirect_from']) + Array(post['redirect_from']))
             .map { |path| path.to_s.strip }.reject(&:empty?).uniq
    # A page lives at /<slug>/, so that address redirecting to itself is a
    # loop the build has to refuse -- and it warns about it once per build,
    # forever. Ghost's adapter guards its own writes against this, but the
    # guard reads the SOURCE: a post the platform calls a post and the
    # author later promotes to a page slips past it, and no adapter can
    # take the address back afterwards, because the merge above is what
    # keeps re-imports from dropping addresses. So it comes off here, where
    # both the slug and `page` are settled, which also repairs the sites
    # that already have one import behind them. Only the post's own current
    # address: a former slug redirecting to the page is exactly what
    # former_slugs is for.
    merged -= ["/#{slug}/"] if PostAddress.page?(post)
    merged.empty? ? post.delete('redirect_from') : post['redirect_from'] = merged
    # hero, toc and unlisted need presence rather than truth, and that
    # distinction is the whole point of them: `hero: false` is a post saying
    # "not me", and a guard that tests `old[key]` reads that as "nothing to
    # carry" and throws it away -- which is exactly how the field went
    # missing from the editor before it was a frontmatter key. Only what the
    # importer itself did not set, as above.
    #
    # unlisted was left out of both lists when it arrived in this cycle, and
    # of the three it is the one that costs something to lose: no source has
    # a notion of it, so no adapter ever sets it, and a re-import therefore
    # put a post the author had taken out of the listings back into every
    # one of them -- the homepage, the feeds, the sitemap and the search
    # index. Silently, and against a promise the import summary makes out
    # loud, that re-running is safe because posts are matched on their
    # source id. A post is unlisted for people, not for search engines, so
    # the failure is quiet on the one side that matters.
    %w[hero toc unlisted].each do |key|
      post[key] = old[key] if old&.key?(key) && !post.key?(key)
    end
    # A re-imported draft keeps its preview URL: the token is engine-side
    # state like the announcement URLs above, and minting a fresh one per
    # re-import would break every shared preview link.
    post['draft_token'] = old['draft_token'] if old && old['draft_token'] && post['state'] == 'draft' && !post['draft_token']
    # ...and its place in the publish queue, for the same reason and with
    # the same condition. `scheduled` is engine-side state no source has a
    # notion of -- only scripts/manage_post.rb writes it -- and it was in
    # neither carry-over list, so a re-import left the post a draft and
    # quietly took it off the queue. Nothing said so, and the failure is
    # invisible until the day the post does not appear: the cron looks for
    # `state == draft && scheduled`, finds nothing due, and exits 0.
    #
    # Only while it is still a draft. If the source now says published,
    # the post has gone out and a leftover queue flag would be a lie about
    # where it stands.
    post['scheduled'] = old['scheduled'] if old && old['scheduled'] && post['state'] == 'draft' && !post['scheduled']
    post = ensure_draft_token(post)

    # unpublished_from is a promise the engine owes the web: "this post
    # used to live at that address, and when it is published again the
    # address must redirect". Publishing.publish keeps that promise and
    # spends the marker. A re-import publishes a post WITHOUT going
    # through it -- the source simply says the post is public -- so the
    # marker survived forever, and after unpublish -> rename -> re-import
    # the old address 404'd while a marker for it sat in the JSON. Spent
    # here for the same reason and in the same way.
    # The sweep runs for every published post, not only for one carrying a
    # marker: a post that went published -> draft -> published through the
    # source can come back holding a redirect from the address it is served
    # at again, and only this call can clear it. Left in, the build
    # complains on every run and nothing the author does makes it stop.
    if post['state'] != 'draft'
      PostAddress.spend_vacated(post, post.delete('unpublished_from'), slug: slug)
    end

    new_dir = File.join(CONTENT_DIR, year)
    new_path = File.join(new_dir, "#{slug}.json")

    # The other way a post's text gets replaced, and the more dangerous
    # one: a re-import overwrites in place across the whole archive at
    # once, and nobody reads a few thousand posts afterwards to see what
    # the source decided to change. Keyed on the OLD location, since that
    # is the copy about to stop existing -- and kept BEFORE the year move
    # below, so the copy travels with the rest of the history instead of
    # stranding in the year the post is leaving.
    # The same guard Publishing.publish and edit_post have, for the same
    # reason: a DIFFERENT post can already own <new_year>/<slug> -- the
    # real archive has the same slug in two years today -- and writing
    # there would replace it wholesale while this post's old file gets
    # deleted, so the build's duplicate check never fires. Raised as a
    # StandardError on purpose: inside an import the per-item rescue
    # counts it and names it, and the rest of the run continues; nothing
    # here has been moved or deleted yet. Hoisted ABOVE the version keep:
    # a re-import about to be refused must refuse with no side effects,
    # and it used to leave one spare version behind on its way out.
    taken = AddressGuard.occupant(post, content_dir: CONTENT_DIR, slug: slug,
                                  except: existing_path, path: new_path)
    if taken
      raise "cannot write '#{slug}' into #{year}: a different post is already served " \
            "at that address (#{taken}) -- resolve the slug clash by hand"
    end

    PostVersions.keep(existing_path, content_dir: CONTENT_DIR)

    # A re-import that moves where a post is served vacates the address it
    # had, and the redirect has to be recorded here exactly as edit_post
    # records it: a source that starts reporting its dates in another
    # timezone is enough to move a post across a New Year, and every link
    # to it died with no stub behind it.
    #
    # Asked of PostAddress on both sides, and asked OUTSIDE the "did the
    # file move" branch, because the file is not what decides this. The old
    # three lines took the year off the FOLDER -- which parts company with
    # the address the moment a date is corrected -- and never asked whether
    # either side was a page, so a source that started marking a post as a
    # page moved it from /posts/2019/slug/ to /slug/ with the file sitting
    # exactly where it was, and nothing was recorded at all.
    #
    # Read from the OLD file: `post` is what the import built, and the
    # state that decides whether there is a public address to keep is the
    # state the post is in now.
    if old.is_a?(Hash) && old['state'] != 'draft'
      was = PostAddress.vacated_marker(old, slug: old['slug'] || slug)
      now = post['state'] == 'draft' ? nil : PostAddress.vacated_marker(post, slug: slug)
      PostAddress.spend_vacated(post, was == now ? nil : was, slug: slug)
    end

    if File.expand_path(new_path) != File.expand_path(existing_path)
      FileUtils.mkdir_p(new_dir)
      move_media_dir(File.join(MEDIA_DIR, old_year, slug), File.join(MEDIA_DIR, year, slug))
      # The edit history is keyed by year/slug exactly like the media, and
      # owes the post the same journey -- left behind, the [v] dialog went
      # silent and the orphaned directory waited to be inherited by a
      # future post under the same year/slug.
      PostVersions.move(slug, old_year, from_content_dir: CONTENT_DIR,
                        to_dir: File.join(PostVersions.versions_root(CONTENT_DIR), year, slug))
    end

    media_files = reconcile_media_names(post, old, year, slug, media_files)
    copy_media(media_files, year, slug)
    sync_media_dimensions(post, year, slug, previous: old)
    # Write first, delete second -- same ordering as Publishing.publish, so
    # a failure in between leaves the post twice (recoverable) rather than
    # not at all.
    AtomicWrite.write_json(new_path, post)
    File.delete(existing_path) if File.expand_path(new_path) != File.expand_path(existing_path)
    index[source_key(post['source'])] = new_path if source_key(post['source'])
    new_path
  end

  # Every draft carries a token, no matter which path wrote it. The
  # authoring CLI always set one, but the importers never did -- so a
  # WordPress draft/pending/private post landed on the live site at
  # /draft//<slug>/, an address anyone could derive from the slug. The
  # whole point of the token is that a preview URL can't be guessed.
  def self.ensure_draft_token(post)
    return post unless post['state'] == 'draft'
    return post unless post['draft_token'].to_s.empty?

    post.merge('draft_token' => SecureRandom.hex(8))
  end

  # mv with two cautions FileUtils.mv alone doesn't have: the target year
  # directory may not exist yet (mkdir_p, or the mv raises ENOENT), and the
  # target slug directory may already exist as an orphan -- mv would then
  # NEST the source inside it (media/<year>/<slug>/<slug>/) and the page
  # would lose its files. Merging file by file keeps both sides' contents.
  def self.move_media_dir(from, to)
    return unless Dir.exist?(from)

    if Dir.exist?(to)
      # A file already sitting under the name we are moving in is NOT a
      # reason to leave ours behind. Skipping it -- which is what this did
      # -- left the post pointing at somebody else's bytes under its own
      # filename (01.jpg is 01.jpg in every post), while its real file
      # stayed in the old year where nothing would ever look for it. The
      # target directory here is an orphan a delete left behind, or the
      # post's own; either way the arriving file is the one the post
      # references. The one in the way is moved aside rather than
      # overwritten, because nothing about a stray file says it is safe
      # to destroy, and named loudly enough to notice.
      Dir.children(from).each do |f|
        dest = File.join(to, f)
        if File.exist?(dest)
          aside = "#{dest}.displaced"
          n = 1
          n += 1 while File.exist?("#{aside}#{n}")
          FileUtils.mv(dest, "#{aside}#{n}")
          warn I18n.t('cli.media_name_taken', name: "#{File.basename(to)}/#{f}",
                                              moved: File.basename("#{aside}#{n}"))
        end
        FileUtils.mv(File.join(from, f), dest)
      end
      FileUtils.rmdir(from) if Dir.empty?(from)
    else
      FileUtils.mkdir_p(File.dirname(to))
      FileUtils.mv(from, to)
    end
  end

  # source id -> path of the post that owns it, across every year. Built
  # once per process (an import re-reading the archive for each of its
  # thousands of items would be quadratic), kept current by write. Only
  # sources with an original_id participate: manual posts all share
  # {platform: manual} and nothing else, and matching them to each other
  # would overwrite one author-written post with another.
  def self.index
    return @index if @index

    # The pass itself settles it -- see each_post.
    each_post { |_path, _post| nil }
    @index
  end

  # Every post in the archive, parsed once: yields [path, post hash].
  #
  # Two maps are built from exactly these bytes -- this one, and the
  # importer's address-to-file index (Import::MediaIndex) -- and an import
  # that ran both globbed and JSON-parsed a few thousand files twice, which
  # on a large archive is a visible wait for nothing. So whichever of them
  # asks first pays for the pass, and it settles `index` on the way past.
  # Order is safe either way round: the media index is built at the first
  # download, which happens while mapping the first item, and `index` at
  # the first write, which happens after it.
  #
  # A post that will not parse is skipped rather than raised on: it is
  # check's business to report, and an index that refused to build over one
  # of them would take the whole import down with it.
  def self.each_post(content_dir: CONTENT_DIR)
    building = @index.nil?
    acc = {}
    PathGlob.under(content_dir, '*', '*.json').each do |file|
      post = JSON.parse(File.read(file, encoding: 'utf-8')) rescue nil
      next unless post.is_a?(Hash)

      if building
        key = source_key(post['source'])
        acc[key] = file if key
      end
      yield file, post
    end
    # Only once the pass finished: a block that raised halfway would
    # otherwise leave a half-built index memoized for the rest of the
    # process, and matching re-imports against it would duplicate posts.
    @index = acc if building && content_dir == CONTENT_DIR
  end

  # Where a post's media lives, derived from the post's own JSON path --
  # the same year/slug pair copy_media builds it from.
  def self.media_dir_for(post_path)
    File.join(MEDIA_DIR, File.basename(File.dirname(post_path)), File.basename(post_path, '.json'))
  end

  # An identity is only an identity when ALL THREE parts exist. Without the
  # account requirement, two different feeds that happen to share bare item
  # ids -- and whose channel carries no readable link, so account came out
  # nil -- collapsed onto the same key and silently overwrote each other,
  # across different slugs. An item without a full identity simply doesn't
  # participate in matching: a re-import may then duplicate it, which is
  # recoverable, where a wrong match destroys a post, which is not.
  def self.source_key(source)
    return nil unless source.is_a?(Hash)

    id = source['original_id']
    account = source['account']
    return nil if id.nil? || id.to_s.empty?
    return nil if account.nil? || account.to_s.empty?

    # Folded, because the operator types this one. Several adapters take
    # the old site's address on the command line -- Ghost's second
    # argument is a required one -- and the host out of it IS half the
    # post's identity, though the docs present it as "where the images
    # live". Typing https://www.cynicky.blog on the second run where the
    # first said https://cynicky.blog made every post a stranger: the
    # archive doubled, every media file was fetched again into a second
    # directory, and the summary said only that it had imported a lot.
    #
    # Here rather than in the adapter, so both sides of the comparison go
    # through it: an archive that already carries the un-folded spelling
    # keeps matching instead of duplicating on the very next run, which is
    # the harm this is meant to prevent. Case folding is safe for every
    # other kind of account too -- a Mastodon acct, a Twitter handle and a
    # Tumblr blog name are all case-insensitive to the platforms that
    # issue them.
    [source['platform'], fold_account(account), id.to_s]
  end

  def self.fold_account(account)
    account.to_s.strip.downcase.sub(%r{\A(?:https?://)?(?:www\.)}, '')
  end

  def self.find_by_source(source)
    key = source_key(source)
    return nil unless key

    path = index[key]
    path if path && File.exist?(path)
  end

  # Settles the name AND takes it, in one step that cannot be interleaved.
  #
  # Returns [post, previous, claimed]: the post carrying its final slug and
  # draft token, whatever stood at that name before (only ever in the
  # same-source case), and whether this run is the one holding a
  # reservation it must clean up if the write goes on to fail.
  def self.claim_slug(post, dir, year)
    base_slug = post.fetch('slug')
    n = 1
    loop do
      candidate = n == 1 ? base_slug : "#{base_slug}-#{n}"
      existing_path = File.join(dir, "#{candidate}.json")
      if File.exist?(existing_path)
        if same_source?(existing_path, post['source'])
          previous = begin
            JSON.parse(File.read(existing_path, encoding: 'utf-8'))
          rescue StandardError
            nil
          end
          # Not claimed: the file is already there and already ours, and
          # deleting it on a later failure would destroy the very post
          # this run came to update.
          return [ensure_draft_token(post.merge('slug' => candidate)), previous, false]
        end
      # A media directory with files in it and no post behind it is what a
      # deleted or half-imported post leaves. Handing a NEW post that name
      # publishes the orphan's pictures as its own: copy_media declines to
      # replace files, so the stranger's 01.jpg becomes this post's first
      # picture, at its stated size, with nothing anywhere to say so.
      # manage_post's `add` has counted an occupied media directory as an
      # occupied slug all along; the importers now agree with it.
      elsif !orphaned_media?(year, candidate) &&
            PostVersions.list(candidate, year, content_dir: CONTENT_DIR).empty?
        # Orphaned versions are refused for the same reason as orphaned
        # media one branch up: a new post on that name would inherit a
        # stranger's history, [v] and all.
        claimed = ensure_draft_token(post.merge('slug' => candidate))
        # O_EXCL is the whole point: of two runs asking at the same
        # instant, the kernel lets exactly one create the file and hands
        # the other EEXIST, which walks on to the next serial rather than
        # writing over a post it never saw.
        #
        # The reservation is written as a FINISHED post rather than left
        # empty, because the build refuses to run at all when a post file
        # will not parse -- and the media copy below can take seconds, a
        # long time for a scheduled build to stumble into. It is the whole
        # post, pictures named and all, for a moment before the pictures
        # are beside it; a run killed inside that moment leaves a draft
        # whose picture `check` reports as missing, and a refusal takes
        # the reservation away again (see the rescue in write).
        begin
          File.open(existing_path, File::CREAT | File::EXCL | File::WRONLY, 0o644) do |f|
            f.write(JSON.pretty_generate(claimed))
          end
          return [claimed, nil, true]
        rescue Errno::EEXIST
          # Somebody took it in the moment between the question and the
          # answer. Nothing is wrong; walk on.
        end
      end

      n += 1
    end
  end

  def self.orphaned_media?(year, slug)
    dir = File.join(MEDIA_DIR, year, slug)
    Dir.exist?(dir) && Dir.children(dir).any? { |f| !f.start_with?('.') }
  end

  # The by-slug fallback behind the index. Requires an original_id for the
  # same reason the index does: two manual posts agree on platform, account
  # and (absent) id, so without the requirement a manual post whose slug
  # collided would silently overwrite the other one.
  def self.same_source?(existing_path, source)
    return false unless source_key(source)

    existing = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    source_key(existing && existing['source']) == source_key(source)
  end
end
