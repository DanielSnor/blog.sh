# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'atomic_write'
require_relative 'path_glob'

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
  FINGERPRINT_TREES = %w[templates lib build locales assets config].freeze

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

    # The file this build's state will be written to. Exposed for the tests
    # and for doctor, which reports on it.
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

        PathGlob.under(dir, '**', '*').sort.each do |file|
          next unless File.file?(file)

          # Size and mtime rather than contents. Reading every library and
          # template on every build to hash them would spend a slice of
          # what this exists to save, and an engine file whose mtime did
          # not move is an engine file nobody edited. `git checkout` and
          # `git pull` both touch mtime, so a version change is seen.
          stat = File.stat(file)
          parts << "#{file.delete_prefix(@root)}:#{stat.size}:#{stat.mtime.to_i}"
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

    # A file the build COPIED rather than rendered -- media, and the assets
    # carried across beside them. Remembered by name, size and mtime, with
    # no digest: hashing 1.8 GB of photographs on every build to learn
    # something the NAME already answers would cost more than the walk this
    # exists to skip.
    #
    # Without it, media were the one output the record could not see stop
    # being produced. Take a photograph out of a post that keeps its slug
    # and every PAGE is still written, so outputs_dropped? answered "none
    # dropped", prune_public was skipped, and the orphan stayed in
    # public.nosync/ -- and then on the site, because the deploy after a
    # publish mirrors whatever is there.
    #
    # `written?` can never vouch for one of these: it is asked with a real
    # digest, and nil equals none of them.
    def note_copy(path)
      stat = stat_of(path)
      return unless stat

      @outputs[rel(path)] = [nil, stat.size, stat.mtime.to_i]
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

    # --- what prune asks --------------------------------------------------

    # Whether anything the last build produced is missing from this one --
    # the only circumstance in which prune_public has something to delete.
    # When nothing was dropped there is no orphan to find, and walking
    # 16,000 entries to confirm it is a second of every publish spent
    # proving a negative.
    #
    # Unknown state answers true, so a first build, an invalidated cache and
    # a --full run all walk the tree as they always did.
    def outputs_dropped?(written)
      return true unless @reuse
      return true if @previous_outputs.empty?

      @previous_outputs.each_key do |relative|
        return true unless written.key?(File.join(@public_dir, relative))
      end
      false
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
