# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'i18n'
require_relative 'path_glob'
require_relative 'path_safety'

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
    # A copy of what is already the newest kept version is not a previous
    # state, and ten of them are ten answers to nothing. Re-importing is
    # exactly the thing somebody does over and over while moving a blog in,
    # and every pass overwrites every post whether the source changed a byte
    # or not -- so ten re-runs filled the whole cap with identical copies
    # and pushed out the one version that predated the author's own edit.
    # The question this list exists to answer, "what did it say before I
    # broke it", was then answered with the broken text ten times over.
    newest = PathGlob.under(dir, '*.json').max
    return false if newest && FileUtils.compare_file(path, newest)

    FileUtils.cp(path, File.join(dir, "#{stamp}.json"))
    prune(dir, cap)
    true
  rescue SystemCallError, IOError
    false
  end

  # Sorted newest first, which is the order they are offered in.
  def list(slug, year, content_dir:)
    dir = File.join(versions_root(content_dir), year.to_s, slug.to_s)
    PathGlob.under(dir, '*.json').sort.reverse
  end

  # Versions travel with the post. Without this, restoring a post from the
  # trash would bring it back with amnesia -- and deleting one would leave
  # its history orphaned in a directory nothing points at.
  # True when the destination holds what it should -- including when the
  # post had no history and the answer is "nothing". False is a failure,
  # and callers may say so; it used to mean either, which is why the one
  # caller that cared could not tell them apart and none of the four said
  # anything at all.
  def move(slug, year, from_content_dir:, to_dir:)
    # The year and the slug are joined into a path here and the next
    # thing that happens to that path is a move. They come off a post
    # file, which is a file people edit.
    unless PathSafety.safe_segment?(slug.to_s) && year.to_s.match?(/\A\d{4}\z/)
      raise PathSafety::Escape,
            "versions move refused: #{year.to_s.inspect}/#{slug.to_s.inspect} is not a year and a slug"
    end

    src = File.join(versions_root(from_content_dir), year.to_s, slug.to_s)
    return true if File.expand_path(src) == File.expand_path(to_dir)

    # The archive rather than the versions tree: delete moves a post's
    # history into trash/<year>/<slug>/versions, which is a destination
    # outside it and a legitimate one.
    PathSafety.contained!(File.dirname(File.dirname(from_content_dir)), to_dir, 'versions destination')

    # The destination is cleared even when there is nothing to move. An
    # orphaned history already sitting there is somebody else's past, and
    # a post renamed onto that name inherited it -- [v] offered a
    # stranger's versions and restore would write a stranger's text over
    # the post. The early return used to come first, which preserved
    # exactly that for the one shape of post with no history of its own.
    #
    # Cleared by PARKING it rather than deleting it, because from here a
    # stranger's history and this post's own look exactly alike. A move
    # interrupted after the history had crossed leaves it sitting at the
    # destination, and the re-run that follows -- re-importing is the
    # thing people do over and over -- finds no source, and deleted what
    # the first run had carried over. Parking clears the name either way,
    # and leaves the bytes where `check` reports them.
    park(to_dir)
    return true unless Dir.exist?(src)

    FileUtils.mkdir_p(File.dirname(to_dir))
    FileUtils.mv(src, to_dir)
    true
  rescue SystemCallError, IOError
    false
  end

  # The archive has one parking name for "a move stepped this aside", and
  # `check` looks for exactly that shape -- so this uses it rather than a
  # second one of its own. A parked directory nothing reports is a
  # history nobody will find again.
  def park(dir)
    return nil unless Dir.exist?(dir)

    base = File.basename(dir)
    n = 0
    loop do
      suffix = n.zero? ? '' : "-#{n}"
      candidate = File.join(File.dirname(dir), ".#{base}.queue-move.#{Process.pid}#{suffix}")
      unless File.exist?(candidate)
        FileUtils.mv(dir, candidate)
        return candidate
      end

      n += 1
    end
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

    # Through the locale's own format, like every other date a person
    # reads here. Written out as day.month.year it was the one human date
    # in the engine that did not ask -- so on an English site the list you
    # pick a version to restore from offered "02.01.2026", which reads as
    # the 2nd of January to whoever wrote it and the 1st of February to
    # whoever is looking. Seconds are kept: two saves a minute apart are
    # what this list is usually telling apart.
    at = Time.new(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i)
    "#{at.strftime(I18n.t('date_time_format'))}:#{m[6]}"
  end

  def prune(dir, cap)
    files = PathGlob.under(dir, '*.json').sort
    return if files.size <= cap

    files.first(files.size - cap).each { |f| File.delete(f) }
  end
end
