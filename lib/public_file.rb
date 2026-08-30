# frozen_string_literal: true

require 'fileutils'

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

  # File.write, then the mode -- in that order, because the mode of a file
  # that does not exist yet is not a thing that can be set.
  def write(path, content)
    File.write(path, content)
    make_readable(path)
    path
  end
end
