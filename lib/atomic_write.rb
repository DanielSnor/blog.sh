# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'securerandom'

# lib/atomic_write.rb -- replace a file's contents, or leave the file
# exactly as it was.
#
# File.write opens with "w": it truncates the target FIRST and only then
# finds out it can't write (a full volume, a vanished mount, a killed
# container). What was a perfectly good post then sits on disk as 0 bytes
# -- the previous version destroyed, the new one never written, and after
# an `edit` the author's text has already left the editor's temp file.
# Nothing restores that: content.nosync/ isn't in git and nothing moved
# the post to trash/.
#
# Writing a sibling temp file and renaming it over the target makes the
# replacement all-or-nothing. The temp file has to live in the SAME
# directory as its target -- rename(2) is only atomic within one
# filesystem, so a temp in /tmp would silently degrade to a copy.
module AtomicWrite
  module_function

  # permissions: the mode the finished file must end up with. A rename
  # REPLACES the target, mode and all, so without saying so a file that
  # was 0644 comes back as whatever the umask allowed the temp -- and
  # under a strict umask (0077) that is a page the web server can no
  # longer read. Left unsaid, the target's own mode is kept, and a file
  # that did not exist yet gets the umask's answer, exactly as a plain
  # File.write would have given it.
  # durable: whether to wait for the disk before calling the write done.
  #
  # Two different promises live in this method and they are worth telling
  # apart. ATOMICITY -- a sibling temp renamed into place -- costs almost
  # nothing and protects against the common disaster: a process killed
  # mid-write, a full volume, a container stopped. DURABILITY, the two
  # fsyncs, protects against a much rarer one: the machine losing power
  # between the write and the disk actually taking it. It is not free.
  # Measured over a thousand-post archive, the fsyncs made a cold build
  # 25% slower -- every page, feed and index waiting twice for a disk.
  #
  # So the archive pays and the output does not. A post is the only copy
  # of something somebody wrote; if the power goes during a save, nothing
  # brings it back. public.nosync is derived: if the power goes during a
  # build, the next build writes it again, which is a thing that happens
  # anyway. Buying insurance against losing what can be regenerated in two
  # seconds is how a build ends up slower for no one's benefit.
  #
  # Atomicity stays on both paths, because a half-written page is served
  # to readers and a rename is what makes that impossible.
  def write(path, content, permissions: nil, binary: false, durable: true)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = temp_name(path, dir)
    mode = permissions || current_mode(path)

    begin
      # EXCL so this can never write THROUGH a name something else made:
      # the temp file is ours or the write does not happen at all.
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL) do |f|
        f.binmode if binary
        f.write(content)
        f.flush
        # Without fsync the rename can land before the data does, so a
        # power cut or a hard container stop can leave the new name
        # pointing at an empty file -- the very outcome this exists to
        # prevent.
        f.fsync if durable
      end
      File.chmod(mode, tmp) if mode
      File.rename(tmp, path)
      sync_dir(dir) if durable
    rescue StandardError
      File.delete(tmp) if File.exist?(tmp)
      raise
    end

    path
  end

  # What File.binwrite was for, without its truncate-first bargain: the
  # bytes go down untranslated, and a failure leaves the previous file
  # whole. The build's pages, feeds and indexes are written through here.
  # durable: false by default, and this is the one caller that wants it
  # that way -- see write. Everything written through here is the build's
  # own output, which the next build produces again from the archive.
  def binwrite(path, content, permissions: nil, durable: false)
    write(path, content, permissions: permissions, binary: true, durable: durable)
  end

  def write_json(path, data, permissions: nil)
    write(path, JSON.pretty_generate(data), permissions: permissions)
  end

  # A name nothing else can be holding. ".<name>.tmp<pid>" was not one:
  # two writers inside a single process share the pid, and a pid is
  # handed out again after the run that left a temp behind is gone.
  def temp_name(path, dir)
    File.join(dir, ".#{File.basename(path)}.tmp#{Process.pid}.#{SecureRandom.hex(6)}")
  end

  def current_mode(path)
    File.stat(path).mode & 0o7777
  rescue SystemCallError
    nil
  end

  # The fsync above makes the file's CONTENT durable; the rename that
  # gives it its name is a change to the DIRECTORY, and a hard stop can
  # lose the name while the bytes sit safely on the disk. Not every
  # platform implements it, and a directory that cannot be synced is not
  # worth failing an otherwise finished write over.
  def sync_dir(dir)
    Dir.open(dir, &:fsync)
  rescue NotImplementedError, StandardError
    nil
  end
end
