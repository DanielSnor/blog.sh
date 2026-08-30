# frozen_string_literal: true

require 'fileutils'
require_relative 'i18n'

# lib/public_file.rb -- a file on its way to a web server.
#
# Everything under public/ is read by a process that is somebody else, so it
# has to be readable by somebody else. Nothing said so until 1.5 and the
# permissions were whatever the author's umask happened to be: an install
# running umask 077 wrote its imported pictures 600 and served holes.
#
# The rule lives here rather than in build_blog.rb because the build is not
# the only writer, and it got this wrong for exactly as long as it was
# written down somewhere the other writers could not see it. Sidebar and
# scripts/refresh_sidebar.rb write straight into public/ from cron: their
# files were born 0600 under a strict umask, and since File.write on an
# EXISTING file leaves its mode alone, every later rebuild -- at any umask
# -- rewrote the contents and left the 0600 in place forever.
#
# That failure was silent by construction. assets/js/sidebar.js catches the
# 403 and hides the card, so a widget the author configured simply never
# appeared: no console message, no gap on the page, no clue. On a moderated
# site the same omission took every approved comment off every page.
module PublicFile
  READABLE = 0o444
  TRAVERSABLE = 0o555

  module_function

  def readable?(path, stat = nil)
    ((stat || File.stat(path)).mode & READABLE) == READABLE
  end

  # Adds the read bits without taking anything away, so an author who keeps
  # their public tree group-writable keeps it.
  def make_readable(path)
    mode = File.stat(path).mode & 0o7777
    File.chmod(mode | READABLE, path)
  rescue SystemCallError
    # A file somebody else owns cannot be chmod'ed by us, and refusing to
    # carry on would be worse than leaving it as it is: whatever had to be
    # written has already been written.
    nil
  end

  # Is this name OURS to write? A file wearing more than one name is not:
  # the other name is somebody else's file, and an in-place write reaches
  # it.
  #
  # Since 1.6 a published picture IS the archive's own file under a second
  # name (emit_copy hardlinks instead of copying), so this is no longer
  # hypothetical. A post with an attachment named index.html put a media
  # file at exactly the path its own page is written to; the page was then
  # written in place, straight through into media.nosync/, and the
  # attachment the archive was keeping was gone -- 300 bytes replaced by
  # 12 kB of HTML, with no build able to bring it back.
  #
  # Dropping OUR name and writing a new file leaves the other name holding
  # the old contents, which is what every other name-holder is entitled to
  # expect. Costs one stat on the writing path only, and nothing at all on
  # the ordinary one where the file has a single name.
  # Answering with a BOOLEAN is the whole point. This used to drop the name
  # and say nothing, and the caller wrote either way -- but unlinking a
  # name needs permission on the DIRECTORY and writing a file needs it on
  # the FILE, and those are different permissions. In a public directory
  # somebody had set read-only, the unlink failed, the write succeeded, and
  # the page went straight through the link into media.nosync: the
  # attachment the archive was keeping came back as rendered HTML.
  #
  # lstat, not stat: a SYMLINK at a public path is the same question
  # wearing different clothes, and stat answers about the far end of it.
  def claim(path)
    info = File.lstat(path)
    return true unless info.symlink? || info.nlink > 1

    File.unlink(path)
    true
  rescue Errno::ENOENT
    # Nothing there at all, which is the easiest kind of ours.
    true
  rescue SystemCallError
    false
  end

  # File.write, then the mode -- in that order, because the mode of a file
  # that does not exist yet is not a thing that can be set.
  def write(path, content)
    unless claim(path)
      warn I18n.t('build.name_not_ours', path: path)
      return path
    end

    File.write(path, content)
    make_readable(path)
    path
  end
end
