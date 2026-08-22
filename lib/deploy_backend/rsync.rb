# frozen_string_literal: true

require 'tempfile'

module DeployBackend
  # One rsync run instead of per-file uploads -- rsync does its own
  # delta-diffing against the target, so this backend syncs the whole
  # public.nosync/ in a single batch (the `sync` half of the backend
  # contract). RSYNC_TARGET is anything rsync accepts as a destination
  # (user@host:/path over SSH, or a plain local path); RSYNC_SSH
  # optionally overrides the remote shell (e.g. "ssh -p 202").
  #
  # Shells out to the system rsync binary -- same principle as $EDITOR in
  # the CLI: external binaries are fine, gems are not.
  module Rsync
    module_function

    def label
      'rsync'
    end

    def configured?
      !target.empty?
    end

    def target
      ENV['RSYNC_TARGET'].to_s
    end

    def manifest_suffix
      '.rsync'
    end

    # Deletion here is by NAME, one orphan at a time, so it composes with
    # --only: asking for two files and taking one down is a coherent run.
    # Backends that could only mirror had to refuse that combination.
    def deletes_by_name?
      true
    end

    # only:  restricts the transfer to the listed files (--files-from) --
    #        how deploy-web.sh --only=... maps onto a batch backend.
    # prune: deletes exactly the orphans deploy_web.rb named, and nothing
    #        else; never combined with only:, matching deploy_web.rb, which
    #        skips orphans under --only.
    # force: retransfers regardless of size/mtime (-I).
    # files: unused -- rsync delta-diffs against the target itself.
    #
    # --delete used to do the pruning, and --delete does not prune, it
    # MIRRORS: everything on the far end that this build did not produce
    # goes, whether the engine ever put it there or not. On a real server
    # that is the ACME challenge webroot a certificate renewal is standing
    # in, the old blog somebody kept at /old-blog/, a hand-written
    # robots.txt -- all deleted by a deploy that then reported "deleted 2",
    # because two is what the manifest knew about. A static site generator
    # is a guest on that directory, not its owner.
    def sync(public_dir:, files: nil, orphans: nil, only: nil, prune: false, force: false, logger: nil)
      args = ['rsync', '-az']
      args << '-I' if force
      args += ['-e', ENV['RSYNC_SSH']] unless ENV['RSYNC_SSH'].to_s.empty?

      run = lambda do |extra|
        full = args + extra + ["#{public_dir}/", target]
        logger&.call("  #{full.join(' ')}")
        system(*full)
      end

      # The list of names is OURS, not rsync's. deploy_web has already
      # decided what changed -- by content hash -- and then wrote those
      # decisions into the manifest; letting rsync decide again by size
      # and timestamp meant a file rewritten within the same second, at
      # the same length, was skipped while the manifest recorded the new
      # bytes as delivered. The target then served the old text forever
      # and every later run agreed there was nothing to do. Handing rsync
      # the names with -I makes what arrives and what is written down the
      # same list.
      wanted = only || Array(files)
      ok = if wanted.empty?
             true
           else
             Tempfile.create('blog-sh-rsync') do |f|
               f.puts(wanted)
               f.flush
               run.call(['-I', '--files-from', f.path])
             end
           end
      ok = prune_orphans(run, orphans, logger) if ok && prune
      logger&.call(ok ? '  ✅ rsync finished' : '  ❌ rsync failed')
      !!ok
    end

    # Named deletions, the way sftp and the local backend do them.
    #
    # --delete is still what does the deleting, but it is fenced in: only
    # the orphans (and the directories leading to them) are included, and
    # --exclude='*' protects everything else on the target from it. Files
    # the engine never uploaded are excluded, and rsync does not delete
    # what it was told to ignore.
    #
    # Not --delete-missing-args, which says this in one flag: macOS ships
    # openrsync ("2.6.9 compatible") and does not have it, and a deploy
    # that only prunes correctly on some machines is worse than one that
    # prunes correctly on all of them.
    def prune_orphans(run, orphans, logger)
      names = Array(orphans)
      return true if names.empty?

      logger&.call("  rsync --delete, fenced to #{names.size} orphan(s)")
      Tempfile.create('blog-sh-rsync-prune') do |f|
        f.puts(names.flat_map { |name| include_lines(name) }.uniq)
        f.flush
        run.call(['--delete', '--include-from', f.path, '--exclude', '*'])
      end
    end

    # Every directory on the way to the file, then the file: rsync will not
    # descend into a directory its filters exclude, so the path has to be
    # opened one level at a time. Wildcards in a name are neutralised --
    # rsync reads *, ? and [ as patterns, and a picture called "sazba[1].jpg"
    # would otherwise stand for more than itself.
    def include_lines(name)
      parts = name.to_s.split('/')
      file = parts.pop
      lines = []
      parts.each_index { |i| lines << "#{literal(parts[0..i].join('/'))}/" }
      lines << literal([*parts, file].join('/'))
      lines
    end

    def literal(pattern)
      pattern.gsub(/[*?\[]/) { |char| "[#{char}]" }
    end
  end
end
