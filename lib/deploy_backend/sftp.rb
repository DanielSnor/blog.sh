# frozen_string_literal: true

require 'open3'
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

    # Where to connect. This value is also the last argument handed to
    # `sftp`, and openssh reads "user@host:path" as "start in path" -- so
    # putting the remote directory in here made the batch's own `cd` land a
    # second time and the whole site went to public_html/public_html.
    def target
      ENV['SFTP_TARGET'].to_s
    end

    # WHICH target this is, for the deploy manifest only. The same server
    # with two directories on it is two targets, and a manifest describing
    # the other one says everything is already uploaded -- so the new
    # directory stays empty while the run reports success. Kept apart from
    # `target` because one is an identity and the other is an address.
    def identity
      dir = ENV['SFTP_REMOTE_DIR'].to_s.gsub(%r{/+\z}, '')
      # SFTP_ARGS too: a different port, key or ssh-config host is a
      # different server behind the same user@host, and a manifest that
      # describes the other one says everything is already uploaded.
      args = ENV['SFTP_ARGS'].to_s.strip
      [dir.empty? ? target : "#{target}:#{dir}", args.empty? ? nil : args].compact.join(' ')
    end

    def manifest_suffix
      '.sftp'
    end

    # only: and force: are unused on purpose -- files: already reflects
    # them (deploy_web.rb narrows to --only and a --force run arrives
    # with every file listed), so the batch just executes the list.
    def sync(public_dir:, files:, orphans:, only: nil, prune: false, force: false, logger: nil)
      @failed_orphans = []
      return true if files.empty? && !(prune && orphans.any?)

      Tempfile.create('blog-sh-sftp') do |f|
        f.puts(batch_commands(public_dir, files, orphans, prune))
        f.flush
        full = ['sftp', '-b', f.path, *Shellwords.split(ENV['SFTP_ARGS'].to_s), target]
        logger&.call("  #{full.join(' ')} (#{files.size} put(s)#{prune ? ", #{orphans.size} rm(s)" : ''})")
        output, status = Open3.capture2e(*full)
        print output
        ok = status.success?
        @failed_orphans = failed_deletes(output, orphans) if prune
        logger&.call(ok ? '  ✅ sftp finished' : '  ❌ sftp failed')
        ok
      end
    end

    # Orphans whose remote delete did NOT go through. A `-rm` may fail
    # without aborting the batch, and deploy_web.rb used to drop every
    # orphan from the manifest regardless -- so a file a permission
    # change made undeletable stayed live on the target forever, with
    # nothing left that knew about it. Matched by ORDER, not by parsing
    # paths out of the echo: sftp -b echoes each command as "sftp> <cmd>",
    # the batch is generated here, so the Nth "-rm" segment IS the Nth
    # orphan; a segment with any output after the echoed command is a
    # failure -- a successful rm prints nothing -- except "No such file",
    # which means the file is already gone, i.e. exactly what a prune
    # wanted.
    def failed_deletes(output, orphans)
      rm_segments = output.split(/^sftp> /).select { |seg| seg.start_with?('-rm ') }
      rm_segments.each_with_index.filter_map do |seg, i|
        error = seg.lines.drop(1).map(&:strip).reject(&:empty?)
        next if error.empty?
        next if error.any? { |l| l.match?(/no such file/i) }

        orphans[i]
      end
    end

    def failed_orphans
      Array(@failed_orphans)
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
