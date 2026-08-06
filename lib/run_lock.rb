# frozen_string_literal: true

require 'time'

# lib/run_lock.rb -- one writer of public.nosync at a time.
#
# Everything that builds or deploys writes into the same public.nosync and
# reads the same deploy manifest, and two of them run from cron: the
# scheduled publish every 15 minutes, the sidebar refresh every 30. On a
# large archive a build plus a full deploy takes longer than a tick, so
# overlapping runs are an ordinary Tuesday rather than an exotic race --
# and what they do to each other is not subtle. A deploy walks a tree the
# other run is rewriting (ENOENT on a file that was there a moment ago), or
# prunes as an orphan a page the other run has just published, or writes a
# manifest describing a build that no longer exists.
#
# So: an advisory whole-file lock, taken without waiting. A run that finds
# the lock held does NOT queue up behind it -- cron will come back in
# fifteen minutes, and a queue of blocked publishes would all wake up at
# once and do the same work again. It says so and leaves.
#
# The lock is per installation (the file lives in the repo root), and it
# is inherited: `rebuild_and_deploy` shells out to build_blog.rb and
# deploy_web.rb as separate processes, and those must run inside the lock
# their parent already holds rather than deadlock against it.
module RunLock
  ENV_MARKER = 'BLOG_SH_LOCK_HELD'
  BUSY = :busy

  module_function

  def path(root)
    File.join(root, '.blog-sh.lock')
  end

  # Yields with the lock held and returns the block's value. Returns
  # RunLock::BUSY without running the block when another process holds it.
  #
  # A filesystem that cannot do flock (a network mount, mostly) must not
  # stop a site from publishing: the lock degrades to "no lock", which is
  # exactly where every installation was before this file existed.
  def hold(root, label: nil)
    return yield if ENV[ENV_MARKER] == '1'

    file = begin
      File.open(path(root), File::CREAT | File::RDWR, 0o600)
    rescue SystemCallError
      return yield
    end

    begin
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        warn(busy_message(file, label))
        return BUSY
      end
    rescue NotImplementedError, SystemCallError
      file.close
      return yield
    end

    write_holder(file, label)
    ENV[ENV_MARKER] = '1'
    begin
      yield
    ensure
      ENV.delete(ENV_MARKER)
      file.flock(File::LOCK_UN)
      file.close
    end
  end

  # The same lock for a script that runs top to bottom rather than around a
  # block: takes it, holds it for the life of the process, and leaves if
  # somebody else has it.
  #
  # `busy_exit:` is the difference between a cron tick and a person. A
  # skipped tick is not a failure -- cron returns in fifteen minutes and
  # nothing was half-done, so it exits 0 and sends no mail. A run somebody
  # started at a terminal exits non-zero, because its caller (./blog.sh,
  # publishing) must not be told a deploy happened when it did not.
  def acquire!(root, label: nil, busy_exit: 1)
    return true if ENV[ENV_MARKER] == '1'

    file = begin
      File.open(path(root), File::CREAT | File::RDWR, 0o600)
    rescue SystemCallError
      return true
    end

    locked = begin
      file.flock(File::LOCK_EX | File::LOCK_NB)
    rescue NotImplementedError, SystemCallError
      file.close
      return true
    end

    unless locked
      warn(busy_message(file, label))
      exit busy_exit
    end

    write_holder(file, label)
    ENV[ENV_MARKER] = '1'
    # Held by keeping the handle open for the life of the process; the
    # kernel drops it when the process ends, however it ends.
    @handle = file
    true
  end

  # Who holds it and since when -- so the line in cron mail says something
  # an operator can act on, rather than "busy".
  def write_holder(file, label)
    file.truncate(0)
    file.write("#{Process.pid} #{label || 'run'} #{Time.now.iso8601}\n")
    file.flush
  rescue SystemCallError
    nil
  end

  def busy_message(file, label)
    holder = begin
      file.rewind
      file.read.to_s.strip
    rescue SystemCallError
      ''
    end
    detail = holder.empty? ? '' : " (#{holder})"
    "ℹ️  Another #{label ? "#{label} " : ''}run is still going#{detail} -- skipping this one."
  end
end
