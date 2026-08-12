# frozen_string_literal: true

require 'fileutils'
require 'json'

# The undo the engine did not have. Deleting a post has always been
# reversible -- it goes to trash/ and `restore` brings it back -- but
# EDITING one was not, and editing is the thing that happens every day.
# A paragraph deleted and saved, a round-trip through markdown that could
# not express something, a paste into the wrong place: all of them were
# final.
#
# So the previous state is put aside before a post is overwritten. Not
# configurable, on purpose: a safety net with a switch is off exactly when
# it is needed, because nobody turns it on before the mistake. The engine
# treats its other guards the same way -- trash/, the slug-collision abort
# and the deploy guards are not optional either; only the destructive
# direction (--prune) is.
#
# Deliberately NOT git for content: no branches, no diffing two arbitrary
# points, no history to browse. And not a backup -- it lives beside the
# content, so it dies with it. The backup list in docs/operations.md still
# applies.
module PostVersions
  # Per post, and it drops the OLDEST. The newest copy is the one that
  # answers "what did this say before I broke it", which is the question
  # in nine cases out of ten.
  CAP = 10

  # Only the text is versioned, never the media -- so an old copy can name
  # an image the post no longer has. The cap is what keeps that window
  # short rather than unbounded.
  DIR_NAME = 'versions'

  module_function

  def versions_root(content_dir)
    File.join(File.dirname(content_dir), DIR_NAME)
  end

  # Called immediately before an existing post is overwritten. A path that
  # does not exist yet is a new post and has nothing to keep, so this is a
  # no-op rather than an error -- callers should not have to ask first.
  #
  # Failures are swallowed on purpose: a full disk or a read-only versions
  # directory must not stop somebody saving their writing. The point of
  # this is to lose less, and refusing the save would lose more.
  def keep(path, content_dir:, cap: CAP)
    return false unless File.exist?(path)

    slug = File.basename(path, '.json')
    year = File.basename(File.dirname(path))
    dir = File.join(versions_root(content_dir), year, slug)
    FileUtils.mkdir_p(dir)
    FileUtils.cp(path, File.join(dir, "#{stamp}.json"))
    prune(dir, cap)
    true
  rescue SystemCallError, IOError
    false
  end

  # Sorted newest first, which is the order they are offered in.
  def list(slug, year, content_dir:)
    dir = File.join(versions_root(content_dir), year.to_s, slug.to_s)
    Dir.glob(File.join(dir, '*.json')).sort.reverse
  end

  # Versions travel with the post. Without this, restoring a post from the
  # trash would bring it back with amnesia -- and deleting one would leave
  # its history orphaned in a directory nothing points at.
  def move(slug, year, from_content_dir:, to_dir:)
    src = File.join(versions_root(from_content_dir), year.to_s, slug.to_s)
    return false unless Dir.exist?(src)

    FileUtils.mkdir_p(File.dirname(to_dir))
    FileUtils.rm_rf(to_dir)
    FileUtils.mv(src, to_dir)
    true
  rescue SystemCallError, IOError
    false
  end

  def stamp
    Time.now.strftime('%Y%m%d-%H%M%S-%L')
  end

  # The filename read back as a date. Sorting relies on the stamp being
  # lexicographic, and a person picking from a list relies on it being
  # legible; this is the second half.
  def human_stamp(name)
    m = name.match(/\A(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/)
    return name unless m

    "#{m[3]}.#{m[2]}.#{m[1]} #{m[4]}:#{m[5]}:#{m[6]}"
  end

  def prune(dir, cap)
    files = Dir.glob(File.join(dir, '*.json')).sort
    return if files.size <= cap

    files.first(files.size - cap).each { |f| File.delete(f) }
  end
end
