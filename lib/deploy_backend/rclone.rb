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

    # only:  restricts the transfer to the listed files (--files-from).
    # prune: switches copy -> sync; never combined with only:, matching
    #        deploy_web.rb, which skips orphans under --only.
    # force: retransfers regardless of size/modtime (--ignore-times).
    # files:/orphans: unused -- rclone delta-diffs against the target itself.
    def sync(public_dir:, files: nil, orphans: nil, only: nil, prune: false, force: false, logger: nil)
      args = ['rclone', prune && !only ? 'sync' : 'copy', "#{public_dir}/", target]
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
      logger&.call(ok ? '  ✅ rclone finished' : '  ❌ rclone failed')
      !!ok
    end
  end
end
