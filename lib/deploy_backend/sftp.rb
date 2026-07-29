# frozen_string_literal: true

require 'tempfile'
require 'shellwords'

module DeployBackend
  # Plain SFTP for hosts that offer neither rsync nor git -- openssh's
  # `sftp -b` batch mode: one connection executes the whole generated
  # batch file (mkdirs, puts, deletes), instead of a connection per file.
  # SFTP_TARGET is user@host; SFTP_REMOTE_DIR optionally changes into a
  # remote directory first (create nested paths beforehand -- only one
  # level is auto-created); SFTP_ARGS appends extra flags (e.g. "-P 2022").
  #
  # Unlike rsync/git/rclone this target can't diff itself -- but that's
  # exactly what deploy_web.rb's manifest is for: `files:` and `orphans:`
  # arrive precomputed, and the batch mirrors them one to one. Commands
  # prefixed with "-" may fail without aborting the batch (an existing
  # directory on -mkdir, a non-empty one on -rmdir); a failed `put` or
  # `cd` aborts, which is what fails the deploy.
  module Sftp
    module_function

    def label
      'SFTP'
    end

    def configured?
      !target.empty?
    end

    def target
      ENV['SFTP_TARGET'].to_s
    end

    def manifest_suffix
      '.sftp'
    end

    # only: and force: are unused on purpose -- files: already reflects
    # them (deploy_web.rb narrows to --only and a --force run arrives
    # with every file listed), so the batch just executes the list.
    def sync(public_dir:, files:, orphans:, only: nil, prune: false, force: false, logger: nil)
      return true if files.empty? && !(prune && orphans.any?)

      Tempfile.create('blog-sh-sftp') do |f|
        f.puts(batch_commands(public_dir, files, orphans, prune))
        f.flush
        full = ['sftp', '-b', f.path, *Shellwords.split(ENV['SFTP_ARGS'].to_s), target]
        logger&.call("  #{full.join(' ')} (#{files.size} put(s)#{prune ? ", #{orphans.size} rm(s)" : ''})")
        ok = system(*full)
        logger&.call(ok ? '  ✅ sftp finished' : '  ❌ sftp failed')
        !!ok
      end
    end

    def batch_commands(public_dir, files, orphans, prune)
      cmds = []
      dir = ENV['SFTP_REMOTE_DIR'].to_s.gsub(%r{/+\z}, '')
      unless dir.empty?
        cmds << "-mkdir #{quote(dir)}"
        cmds << "cd #{quote(dir)}"
      end

      # Parents before children, each -mkdir tolerant of already existing.
      files.flat_map { |f| ancestors(File.dirname(f)) }.uniq.sort.each do |d|
        cmds << "-mkdir #{quote(d)}"
      end
      files.each { |f| cmds << "put #{quote(File.join(public_dir, f))} #{quote(f)}" }

      if prune
        orphans.each { |f| cmds << "-rm #{quote(f)}" }
        # Deepest first, so emptied trees collapse -- -rmdir quietly skips
        # any directory that still has files in it.
        orphans.flat_map { |f| ancestors(File.dirname(f)) }.uniq
               .sort_by { |d| -d.count('/') }.each { |d| cmds << "-rmdir #{quote(d)}" }
      end
      cmds
    end

    def ancestors(dir)
      return [] if dir == '.'

      parts = dir.split('/')
      (1..parts.length).map { |i| parts.first(i).join('/') }
    end

    def quote(path)
      %("#{path.gsub('"', '\"')}")
    end
  end
end
