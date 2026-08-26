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
  # When a LIVE holder has been going longer than this, the busy message
  # stops promising "in a minute" and says since when it has held the
  # lock. flock has no timeout, so a hung publish holds every queue
  # write hostage while the message keeps sounding routine. Thirty
  # minutes is two cron intervals and far above a full build-plus-deploy
  # on a large archive -- a false alarm takes deliberate effort. A DEAD
  # holder needs none of this: the kernel released its flock the moment
  # it ended, whatever the lock file still says.
  STUCK_AFTER = 30 * 60

  # The exit code build_blog.rb and deploy_web.rb use for "another run
  # holds the lock". Distinct from 1, because "come back in a minute" and
  # "your site is broken" want different words and different advice -- and
  # because only one of them is a fault. It lives here, with the lock that
  # gives it its meaning: it is this file's contract with the four scripts
  # that take the lock and with everyone who shells out to them, and a
  # caller that had to reach into the publishing library for it either
  # dragged that library along or compared against a literal 3.
  BUSY_EXIT = 3

  module_function

  # Whether a finished child process left because the lock was held, told
  # apart from every other way it could have failed. Callers that shell out
  # to a build or a deploy ask this rather than reading the number, so the
  # meaning of the code stays in one place.
  def busy_exit?(status)
    status.respond_to?(:exitstatus) && status.exitstatus == BUSY_EXIT
  end

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

    file = open_lock(root)
    return yield if file.nil?

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
  # `quiet_when_busy:` is what makes the paragraph above true. Cron mails
  # on OUTPUT, not on the exit code, and the busy message went to stderr
  # unconditionally -- so the documented crontab (a publish every 15
  # minutes, a sidebar refresh every 30) mailed on every collision at :00
  # and :30, which is most of them: roughly forty-eight notes a day saying
  # nothing is wrong. A holder that looks STUCK is still said out loud,
  # because that one is not routine and the mail is the point.
  def acquire!(root, label: nil, busy_exit: 1, quiet_when_busy: false)
    return true if ENV[ENV_MARKER] == '1'

    file = open_lock(root)
    return true if file.nil?

    locked = begin
      file.flock(File::LOCK_EX | File::LOCK_NB)
    rescue NotImplementedError, SystemCallError
      file.close
      return true
    end

    unless locked
      warn(busy_message(file, label)) unless quiet_when_busy && !stuck?(file)
      exit busy_exit
    end

    write_holder(file, label)
    ENV[ENV_MARKER] = '1'
    # Held by keeping the handle open for the life of the process; the
    # kernel drops it when the process ends, however it ends.
    @handle = file
    true
  end

  # The lock file belongs to whoever ran first, and on a real
  # installation that is usually not the person at the keyboard: the
  # publishing cron runs as root while a hand-run build may not, and a
  # root-owned 0600 file would hand every human run an EACCES -- which,
  # degrading to "no lock", would leave exactly the collision this file
  # exists to prevent, on the one machine where it matters.
  #
  # So the file is created group- and world-writable (the umask still has
  # the last word) and, when it already exists and belongs to somebody
  # else, it is opened read-only: flock works just as well on a read-only
  # handle. All that is lost is the line saying who holds it.
  def open_lock(root)
    File.open(path(root), File::CREAT | File::RDWR, 0o666)
  rescue Errno::EACCES, Errno::EPERM, Errno::EROFS
    begin
      File.open(path(root), File::RDONLY)
    rescue SystemCallError => e
      unlocked_warning(root, e)
    end
  rescue SystemCallError => e
    # A directory sitting at the lock path, a vanished root -- running
    # unlocked is the compatible floor, but doing it SILENTLY is how two
    # publishes end up interleaved with nobody told why.
    unlocked_warning(root, e)
  end

  def unlocked_warning(root, error)
    warn("⚠️  Cannot use the run lock at #{path(root)} (#{error.class}) -- running without it.")
    nil
  end

  # Who holds it and since when -- so the line in cron mail says something
  # an operator can act on, rather than "busy".
  def write_holder(file, label)
    file.truncate(0)
    file.write("#{Process.pid} #{label || 'run'} #{Time.now.iso8601}\n")
    file.flush
  rescue SystemCallError, IOError
    # Read-only handle (see open_lock) -- the lock still holds, it just
    # can't say whose it is.
    nil
  end

  # Whether the run holding the lock has been holding it long enough to be
  # worth waking somebody for. A routine collision is not; this is the one
  # case where a cron tick still speaks.
  def stuck?(file)
    holder = begin
      file.rewind
      file.read.to_s.strip
    rescue SystemCallError
      ''
    end
    return false unless holder_alive?(holder)

    !stuck_hint(holder).empty?
  end

  def busy_message(file, label)
    holder = begin
      file.rewind
      file.read.to_s.strip
    rescue SystemCallError
      ''
    end
    # Only quoted when the process it names is actually alive. The line is
    # written by whoever holds the lock -- but a run that got only a
    # read-only handle cannot write it, which is the normal case where
    # cron runs as root and a person runs as themselves (sean.cz does
    # exactly this). The line then still describes the run BEFORE, and
    # naming a pid and a timestamp from an hour ago as "still going" sends
    # somebody hunting a process that ended long ago. The lock itself is
    # held either way; that part of the message was never in doubt.
    holder = '' unless holder_alive?(holder)
    detail = holder.empty? ? '' : " (#{holder})"
    stuck = stuck_hint(holder)
    # The KIND named is the holder's, read out of its own line, not the
    # blocked run's. `label` here is this process's -- so a `queue` run
    # waiting on the publishing cron announced "another queue run is still
    # going", pointing at the wrong culprit. The holder line is
    # "pid label... iso8601"; the middle is its label. Falls back to this
    # run's label only when the holder could not say who it is (a
    # read-only handle, the cron-as-root case).
    holder_label = holder_label(holder) || label
    "ℹ️  Another #{holder_label ? "#{holder_label} " : ''}run is still going#{detail} -- " \
      "skipping this one. Nothing is broken; try again in a minute.#{stuck}"
  end

  # The holder's own label, pulled from its line "pid label... iso8601":
  # everything between the pid and the timestamp. nil when the line is
  # empty or unshaped, so the caller falls back to its own label.
  def holder_label(holder)
    return nil if holder.to_s.strip.empty?

    parts = holder.split(/\s+/)
    return nil if parts.size < 3

    middle = parts[1..-2].join(' ')
    middle.empty? || middle == 'run' ? nil : middle
  end

  # The holder line is "pid label iso8601-start". Empty when the holder is
  # dead or unknown (see busy_message), so a hint here always describes a
  # process that is alive right now and has been holding the lock for
  # longer than any legitimate run takes.
  def stuck_hint(holder)
    started = holder.split(' ')[2]
    return '' unless started

    begin
      age = Time.now - Time.parse(started)
    rescue ArgumentError
      return ''
    end
    return '' unless age > STUCK_AFTER

    " It has been holding it since #{started}, which is longer than these runs take -- " \
      'if that process is stuck, ending it releases the lock (a dead one releases it by itself).'
  end

  # The holder line starts with the pid that wrote it. Signal 0 asks the
  # kernel whether that process exists without touching it; EPERM means it
  # exists and belongs to somebody else, which is a yes.
  def holder_alive?(holder)
    pid = holder.to_s[/\A\d+/]
    return false unless pid

    begin
      Process.kill(0, pid.to_i)
      true
    rescue Errno::EPERM
      true
    rescue StandardError
      false
    end
  end
end
