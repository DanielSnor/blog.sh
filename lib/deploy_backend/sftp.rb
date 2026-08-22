# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'shellwords'
require 'digest'

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
      base = dir.empty? ? target : "#{target}:#{dir}"
      # SFTP_ARGS too: a different port, key or ssh-config host is a
      # different server behind the same user@host, and a manifest that
      # describes the other one says everything is already uploaded.
      print = args_fingerprint
      print ? "#{base} ##{print}" : base
    end

    # Switches that cannot move the connection anywhere: how loud it is,
    # whether it compresses, how it copies. A deny-list and not an
    # allow-list on purpose -- a switch nobody here has heard of stays in
    # the identity, so the mistake is made in the direction that costs one
    # re-upload rather than the direction that loses the manifest.
    CHATTER = %w[-v -q -C -a -p -r -4 -6].freeze
    TUNING = %w[-B -R -l -D].freeze
    TAKES_VALUE = %w[-P -i -F -o -J -c -S -b -B -R -l -D].freeze

    # SFTP_ARGS is a LIST of switches, not a string.
    #
    # The same switches in another order are the same server: openssh reads
    # -P/-i/-F/-o/-J whichever way round they come, env.sh is a hand-edited
    # file people reformat, and adding -v to watch a failing deploy is not
    # moving to another host. Compared as a string, every such edit read as
    # a new target -- and a new target throws the manifest away, which is
    # the only record of what stands on the far end. The re-upload is the
    # cheap half of that: the orphans the manifest knew about become
    # unreachable, so a post deleted at home goes on being served forever
    # and no switch exists that would find it again.
    #
    # A digest rather than the switches themselves, because the manifest is
    # a 0644 file the docs call disposable while env.sh -- where -i names a
    # private key and -J names a bastion -- is the file they tell you to
    # keep at 600. Identity is only ever asked whether two of them are
    # equal, so hashing costs nothing.
    def args_fingerprint
      tokens = split_args(ENV['SFTP_ARGS'].to_s.strip)
      kept = []
      until tokens.empty?
        token = tokens.shift
        if TAKES_VALUE.include?(token) && !tokens.empty?
          value = tokens.shift
          kept << "#{token} #{value}" unless TUNING.include?(token)
        elsif !CHATTER.include?(token)
          kept << token
        end
      end
      return nil if kept.empty?

      Digest::SHA256.hexdigest(kept.sort.join(' '))[0, 12]
    end

    # Identity must never be the thing that raises: an unmatched quote is
    # a typo, not a reason to lose the manifest. `problem` is where that
    # typo gets named, before the run touches anything.
    def split_args(raw)
      Shellwords.split(raw)
    rescue ArgumentError
      raw.split
    end

    # Asked once, before the deploy writes its baseline. Without it the
    # same typo surfaced as a raw Shellwords backtrace from the middle of
    # the run -- past every guard, with the baseline already on disk and
    # the run counted as started and never finished.
    def problem
      Shellwords.split(ENV['SFTP_ARGS'].to_s)
      nil
    rescue ArgumentError => e
      "SFTP_ARGS: #{e.message}"
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
