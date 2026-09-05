# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'atomic_write'

# lib/build_cache.rb -- what the last build wrote, so this one can skip
# producing the same bytes a second time.
#
# The build has always been "render everything, compare, write what
# differs". That is correct and it is why public.nosync/ is not wiped and
# rewritten -- but it means the cost of publishing is the cost of the whole
# archive, every time, however little changed. Measured on a 4,394-post
# copy of one real archive: adding a post dated today changes 12 files out
# of 7,995, and the build still rendered 7,995 pages and read 7,995 files
# back off disk to find that out. Two thirds of a publish was work whose
# only result was the discovery that there was no work.
#
# So this records two things per build:
#
#   outputs -- the digest, size and mtime of every file emit() wrote. Next
#              build, a page whose freshly rendered bytes hash to the same
#              digest is already on disk: one stat instead of reading the
#              whole file back. (2.81 s of the 11.2 s steady-state build
#              was that read-back alone.)
#
#   pages   -- a key describing the INPUTS of each generated page. When the
#              key matches, the page is not rendered at all -- not rendered
#              and then found identical, simply not rendered. This is the
#              half that saves the render, and it is why a post page costs
#              nothing on a build that did not touch that post.
#
# Both are keyed to a FINGERPRINT of the engine itself -- every template,
# every library file, the locales, the config, the menu, the page size.
# Change any of it and the whole cache is thrown away, because any of it
# can change every page. That makes the first build after an upgrade a full
# one, which is the honest answer: an engine that tried to work out which
# pages a template edit reaches would be wrong about it eventually, and
# being wrong here means a site that serves stale HTML with nothing saying
# so.
#
# The cache is an OPTIMISATION and never an authority. Anything it cannot
# vouch for falls through to the old path -- render it, read the file back,
# compare bytes. A missing cache file, a fingerprint mismatch, a file whose
# size or mtime moved under us: all of them mean "do the work", never "trust
# the record". Deleting the cache file is always safe and always correct.
#
# `--full` (or BLOG_SH_FULL_BUILD=1) switches it off for one run, which is
# both the escape hatch and the test: a full build and a cached build over
# the same content must produce byte-identical output, and tests/ checks
# exactly that.
module BuildCache
  # Bumped when the shape of the file changes. An older shape is discarded
  # rather than migrated -- it describes work that is cheap to redo.
  FORMAT = 1

  # What the fingerprint is taken over: everything that can change the
  # bytes of a rendered page. Deliberately whole directories rather than a
  # list of files, so a template or a helper added later is covered without
  # anybody remembering to add it here.
  #
  # ⚠️ assets/ is deliberately NOT among them, and the reason is the rule
  # above rather than an exception to it: a page LINKS a stylesheet, a
  # script and a favicon, it never carries their bytes. There is no ?v=
  # cache-buster on any of those links -- that is a decision of its own,
  # written down where the links are made -- so no edit under assets/ can
  # change the bytes of a rendered page. What assets/ needs instead, it
  # already has: emit_copy compares every file byte for byte on every
  # build, before this cache is even opened, and registers it against the
  # sweep. Including the tree here bought nothing and cost a full rebuild
  # of every page for a one-line change of colour.
  #
  # The one thing under assets/ that DOES reach a page is colors.css, and
  # it is generated from config/site.yml rather than read from the tree,
  # so config -- which is in the list -- covers it. If a template is ever
  # written that inlines the CONTENT of a file under assets/, that content
  # has to come back into this fingerprint with it.
  FINGERPRINT_TREES = %w[templates lib build locales config].freeze

  class << self
    attr_reader :root, :public_dir

    # Whether this build trusts the previous record. Off until setup! says
    # otherwise, so a caller that never opens a cache behaves exactly like
    # the engine did before this file existed.
    #
    # Distinct from whether a record is KEPT, and the difference is what
    # `--full` means: render and compare everything, believing nothing --
    # but still write down what was written, so reaching for the escape
    # hatch costs one slow build rather than two.
    def reusing?
      @reuse == true
    end

    # Where this build's state lives, and whether to keep any at all.
    # Nothing is read yet: the fingerprint cannot be taken until the build
    # knows its own menu, and the menu is not known until the archive has
    # been read. seal! does the reading.
    #
    # A build writing somewhere other than the site's own public.nosync/
    # (the palette preview, a measurement run) gets its own cache file
    # rather than sharing -- same reason the deploy manifest is per-backend:
    # a record of what is on disk somewhere else is worse than no record.
    def setup!(root:, public_dir:, reuse: true)
      @root = root
      @public_dir = public_dir
      @path = File.join(root, ".build_cache#{suffix_for(root, public_dir)}.json")
      @outputs = {}
      @pages = {}
      @previous_outputs = {}
      @previous_pages = {}
      @reuse = reuse
    end

    # The file this build's state will be written to. Read by the build
    # itself, in load_previous and save!; nothing outside this file asks
    # for it today -- the comment here used to name doctor and the tests
    # as consumers, and neither has ever called it.
    attr_reader :path

    # Takes the fingerprint and loads the previous state if it matches.
    # Returns true when a usable one was found, false when this build will
    # be a full one.
    #
    # `facts` are the things the fingerprint cannot read off disk: values
    # the build works out from the archive that every page then depends on
    # -- the menu, the content types present, the page size. A site that
    # published its first video grows a menu item on every page, and that
    # has to invalidate the cache exactly the way a template edit does.
    def seal!(*facts)
      parts = []
      FINGERPRINT_TREES.each do |tree|
        dir = File.join(@root, tree)
        next unless File.directory?(dir)

        engine_files(dir).each do |file|
          parts << "#{file.delete_prefix(@root)}:#{file_digest(file)}"
        end
      end
      @fingerprint = Digest::SHA256.hexdigest((parts + facts.map(&:to_s)).join("\n"))
      # A --full run takes the fingerprint (save! has to record it) and
      # then declines to read what the last build left.
      return false unless @reuse

      load_previous
    end

    # --- what emit() asks ------------------------------------------------

    # True when `bytes` are already the contents of `path`. The digest says
    # what we last wrote there; size and mtime say nobody has written since.
    # Any doubt at all answers false, and false only ever costs a read.
    def written?(path, digest)
      return false unless @reuse

      relative = rel(path)
      record = @previous_outputs[relative]
      return false unless record && record[0] == digest

      stat = stat_of(path)
      return false unless stat
      return false unless stat.size == record[1] && stat.mtime.to_i == record[2]

      # Carried over rather than re-stat'ed: nothing was written, so what
      # the last build knew about this file is still true. Without this the
      # record would be dropped from THIS build's state and the next build
      # would have to read the file back after all -- the saving would last
      # exactly one build.
      @outputs[relative] = record
      true
    end

    # Remember what is on disk at `path` now. Called after a write, and
    # after a skipped write -- both mean "these bytes are there".
    def record(path, digest)
      stat = stat_of(path)
      return unless stat

      @outputs[rel(path)] = [digest, stat.size, stat.mtime.to_i]
    end

    # --- what a page renderer asks ---------------------------------------

    # True when the page at `dest` was last built from exactly these inputs
    # AND the file we wrote then is still there untouched. Both halves
    # matter: the key alone would happily vouch for a page somebody deleted
    # out of public.nosync/ by hand.
    def page_fresh?(dest, key)
      return false unless @reuse

      relative = rel(dest)
      return false unless @previous_pages[relative] == key

      record = @previous_outputs[relative]
      return false unless record

      stat = stat_of(dest)
      return false unless stat

      return false unless stat.size == record[1] && stat.mtime.to_i == record[2]

      # Carried straight over: the file was not rewritten, so what we knew
      # about it last time is still what is true about it.
      @outputs[relative] = record
      @pages[relative] = key
      @skipped = @skipped.to_i + 1
      true
    end

    # How many pages this build did not have to render. Reported in the
    # summary, because a number nobody can see is a promise nobody can
    # check -- and the first thing to look at when a build is slower than
    # it should be is whether the cache is being used at all.
    def skipped
      @skipped.to_i
    end

    # Record the inputs a page was built from, after building it.
    def remember_page(dest, key)
      @pages[rel(dest)] = key
    end

    # --- saving ------------------------------------------------------------

    # Written at the END of a successful build, never from an at_exit hook:
    # a build that died halfway has written some of the site and none of the
    # rest, and a record claiming otherwise would make the NEXT build skip
    # the half that never got written.
    def save!
      AtomicWrite.write(@path, {
        'format' => FORMAT,
        'fingerprint' => @fingerprint,
        'public_dir' => @public_dir,
        'outputs' => @outputs,
        'pages' => @pages
      }.to_json)
    rescue SystemCallError, IOError => e
      # A cache that cannot be saved is a slow build, not a broken one.
      warn "build cache: #{e.message}"
    end

    private

    # What the engine is MADE of, hashed. This used to be size and mtime,
    # on the reasoning that reading every template and library to hash them
    # would spend a slice of what the cache exists to save. Measured on the
    # engine itself: 136 files, 3.3 MB, 9 ms -- against the seven seconds a
    # publish saves. And the build reads all of it anyway; Ruby loads lib/
    # and build/ at startup, the renderer reads templates/ and locales/,
    # and emit_copy compares assets/ byte for byte.
    #
    # Contents cut both ways and both ways are the right one. Stricter
    # where mtime lied: rsync -a, tar -p and a restore from backup all
    # carry mtime across, so an engine that changed underneath kept its
    # cache and the site went on serving the old markup with nothing
    # saying so. More forgiving where mtime moved for nothing: a git pull
    # bringing back what was already there no longer throws the cache away
    # and buys a full build for no change at all.
    def file_digest(path)
      Digest::SHA256.file(path).hexdigest
    rescue SystemCallError
      # Unreadable is a fact about the file, and a steady one -- recording
      # it keeps the fingerprint still rather than making the cache the
      # thing that kills a build over a file it was only looking at.
      'unreadable'
    end

    # Walked by hand rather than globbed, for two reasons.
    #
    # Dir.glob's "**" does not descend into a SYMLINKED directory, and then
    # drops the link itself for not being a file -- so everything behind
    # one was in no fingerprint at all. templates/partials is the reachable
    # case: edit a partial through such a link and every page kept its old
    # bytes, while each newly published post got the new ones, so the site
    # served two different footers with nothing saying which was which.
    # File.directory? and File.file? both follow a link, which is the
    # point; realpath remembers where we have been, so a link pointing at
    # its own ancestor ends the walk instead of the process.
    #
    # And a walk carries no pattern, so an installation whose own path
    # holds a glob metacharacter -- "blog [1]", "blog {old}" -- cannot be
    # misread. That is the whole reason PathGlob exists, answered here by
    # not having a pattern in the first place.
    def engine_files(dir, seen = {})
      real = File.realpath(dir)
      return [] if seen[real]

      seen[real] = true
      Dir.children(dir).sort.flat_map do |name|
        # Dot-names are not the engine. The glob this replaced skipped them
        # by default and nothing in six trees has ever been called one --
        # but a Finder window opened over assets/images/ leaves a .DS_Store
        # behind, and counting it threw the whole cache away on a machine
        # whose owner had merely LOOKED at their own artwork.
        next [] if name.start_with?('.')

        path = File.join(dir, name)
        if File.directory?(path) then engine_files(path, seen)
        elsif File.file?(path) then [path]
        else []
        end
      end
    rescue SystemCallError
      []
    end

    def suffix_for(root, public_dir)
      default = File.join(root, 'public.nosync')
      return '' if public_dir == default

      "-#{Digest::SHA256.hexdigest(public_dir)[0, 12]}"
    end

    def rel(path)
      path.delete_prefix("#{@public_dir}/")
    end

    def stat_of(path)
      File.stat(path)
    rescue SystemCallError
      nil
    end

    def load_previous
      raw = File.read(@path, encoding: 'utf-8')
      data = JSON.parse(raw)
      return false unless data.is_a?(Hash) && data['format'] == FORMAT
      # A cache describing a different output directory is not this build's
      # business, whatever the filename says.
      return false unless data['public_dir'] == @public_dir

      return false unless data['fingerprint'] == @fingerprint

      outputs = data['outputs']
      pages = data['pages']
      return false unless outputs.is_a?(Hash) && pages.is_a?(Hash)

      @previous_outputs = outputs
      @previous_pages = pages
      true
    rescue JSON::ParserError, SystemCallError
      # Unreadable or half-written: the same answer as absent. Nothing is
      # lost, the build simply does all of its work.
      @previous_outputs = {}
      @previous_pages = {}
      false
    end
  end

  # Started empty so the accessors above never meet a nil.
  @reuse = false
  @outputs = {}
  @pages = {}
  @previous_outputs = {}
  @previous_pages = {}
end
