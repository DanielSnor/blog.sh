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

    # only:  restricts the transfer to the listed files (--files-from) --
    #        how deploy-web.sh --only=... maps onto a batch backend.
    # prune: mirrors deletions (--delete); never combined with only:,
    #        matching deploy_web.rb, which skips orphans under --only.
    # force: retransfers regardless of size/mtime (-I).
    # files:/orphans: unused -- rsync delta-diffs against the target itself.
    def sync(public_dir:, files: nil, orphans: nil, only: nil, prune: false, force: false, logger: nil)
      args = ['rsync', '-az']
      args << '-I' if force
      args << '--delete' if prune && !only
      args += ['-e', ENV['RSYNC_SSH']] unless ENV['RSYNC_SSH'].to_s.empty?

      run = lambda do |extra|
        full = args + extra + ["#{public_dir}/", target]
        logger&.call("  #{full.join(' ')}")
        system(*full)
      end

      ok = if only
             Tempfile.create('blog-sh-rsync') do |f|
               f.puts(only)
               f.flush
               run.call(['--files-from', f.path])
             end
           else
             run.call([])
           end
      logger&.call(ok ? '  ✅ rsync finished' : '  ❌ rsync failed')
      !!ok
    end
  end
end
