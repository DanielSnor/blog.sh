# frozen_string_literal: true

require 'tempfile'
require 'shellwords'

module DeployBackend
  # rclone covers the long tail of targets in one integration: S3, R2, B2,
  # WebDAV, Azure, GCS, SFTP and dozens more. RCLONE_TARGET is a
  # remote:path the user has set up with `rclone config` -- credentials
  # live in rclone's own config, never in env.sh. RCLONE_ARGS optionally
  # appends extra flags (e.g. provider-specific ACLs).
  #
  # `rclone copy` (never deletes) on a normal deploy, `rclone sync`
  # (mirrors deletions) under --prune -- both delta-diff by size+modtime
  # against the target, so unchanged files aren't retransferred. Shells
  # out to the system rclone binary, same no-gems principle as rsync.
  module Rclone
    module_function

    def label
      'rclone'
    end

    def configured?
      !target.empty?
    end

    def target
      ENV['RCLONE_TARGET'].to_s
    end

    # Same question sftp answers, for the same reason: an unmatched quote
    # in RCLONE_ARGS is a typo in a hand-edited env.sh, and it belongs in a
    # sentence before the run starts, not in a backtrace from the middle
    # of one.
    def problem
      Shellwords.split(ENV['RCLONE_ARGS'].to_s)
      nil
    rescue ArgumentError => e
      "RCLONE_ARGS: #{e.message}"
    end

    def manifest_suffix
      '.rclone'
    end

    # Named deletions rather than a mirror: `rclone delete --files-from`
    # removes these paths and looks at nothing else on the target.
    def prune_orphans(orphans, logger)
      names = Array(orphans)
      return true if names.empty?

      Tempfile.create('blog-sh-rclone-prune') do |f|
        f.puts(names)
        f.flush
        full = ['rclone', 'delete', target, '--files-from', f.path]
        full += Shellwords.split(ENV['RCLONE_ARGS'].to_s) unless ENV['RCLONE_ARGS'].to_s.empty?
        logger&.call("  #{full.join(' ')} (#{names.size} orphan(s))")
        system(*full)
      end
    end

    # only:  restricts the transfer to the listed files (--files-from).
    # prune: deletes exactly the orphans deploy_web.rb named; never
    #        combined with only:, matching deploy_web.rb, which skips
    #        orphans under --only.
    # force: retransfers regardless of size/modtime (--ignore-times).
    # files: unused -- rclone delta-diffs against the target itself.
    #
    # `sync` used to do the pruning, and `sync` does not prune, it MIRRORS:
    # anything on the far end this build did not produce is deleted, the
    # engine's or not. On a real bucket that is somebody else's prefix, a
    # hand-written robots.txt, a certificate challenge -- gone, while the
    # run reports the two deletions the manifest knew about. The engine is
    # a guest on that target, not its owner.
    def sync(public_dir:, files: nil, orphans: nil, only: nil, prune: false, force: false, logger: nil)
      args = ['rclone', 'copy', "#{public_dir}/", target]
      args << '--ignore-times' if force
      args += Shellwords.split(ENV['RCLONE_ARGS'].to_s) unless ENV['RCLONE_ARGS'].to_s.empty?

      run = lambda do |extra|
        full = args + extra
        logger&.call("  #{full.join(' ')}")
        system(*full)
      end

      ok = if only
             Tempfile.create('blog-sh-rclone') do |f|
               f.puts(only)
               f.flush
               run.call(['--files-from', f.path])
             end
           else
             run.call([])
           end
      ok = prune_orphans(orphans, logger) if ok && prune && !only
      logger&.call(ok ? '  ✅ rclone finished' : '  ❌ rclone failed')
      !!ok
    end
  end
end
