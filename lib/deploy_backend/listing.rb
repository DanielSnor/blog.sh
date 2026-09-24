# frozen_string_literal: true

require 'open3'

module DeployBackend
  # What `doctor --online` asks a deploy target: does it answer, and what
  # stands in its root. Each backend answers with `list_root` -- how to
  # address the target is its business -- and this is the one thing they
  # share: running the tool with a deadline.
  #
  # Only the root, on purpose. It is where an earlier site leaves the files
  # that hurt (index.php is served before index.html, .htaccess rewrites
  # every address), and one request answers it. A whole tree is thousands
  # of requests on Surfer (10 320 directories on sean.cz), and whatever is
  # left deeper inside the site's own folders is what the manifest and
  # --prune already look after.
  module Listing
    class Failed < StandardError; end

    TIMEOUT = 30

    # Output of a command, or Failed with the tool's own first word on it. The
    # command runs in a process group of its own so a deadline takes down
    # the ssh underneath it too, and with nothing on stdin, so nothing can
    # sit waiting for an answer nobody is going to type.
    def self.run(cmd, input: nil, timeout: TIMEOUT)
      Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.write(input) if input
        stdin.close
        out = reader(stdout)
        err = reader(stderr)
        unless wait.join(timeout)
          stop(wait.pid)
          [out, err].each { |t| t.join(2) }
          raise Failed, I18n.t('doctor.deploy_target_timeout', seconds: timeout)
        end
        output = out.value.to_s
        unless wait.value.success?
          raise Failed, first_said(err.value) || first_said(output) || "#{cmd.first} exit #{wait.value.exitstatus}"
        end
        output
      end
    rescue SystemCallError => e
      raise Failed, e.message
    end

    # A pipe read to the end in a thread of its own, quietly: after a
    # deadline the pipe is closed under it, and that is expected.
    def self.reader(io)
      Thread.new do
        Thread.current.report_on_exception = false
        io.read
      rescue IOError
        ''
      end
    end

    # The line that says what went wrong is the FIRST one: ssh's
    # "Permission denied (publickey)", rsync's "change_dir ... failed",
    # git's "does not appear to be a git repository". What follows is
    # each tool's own epilogue -- "rsync error: unexplained error (code
    # 255)", "Please make sure ... and the repository exists." -- true of
    # every failure and so saying nothing about this one. ssh's notes
    # about known hosts are not the failure either, and rclone's log
    # prefix (date, time, level, and the ": " of an unnamed object) is
    # noise in a sentence.
    def self.first_said(text)
      text.to_s.lines.map(&:strip).each do |line|
        next if line.empty? || line.start_with?('Warning:')

        line = line.sub(%r{\A\d{4}/\d\d/\d\d \d\d:\d\d:\d\d }, '').sub(/\A(ERROR|NOTICE|CRITICAL) ?: /, '').sub(/\A:\s*/, '')
        return line.sub(/\.\z/, '')
      end
      nil
    end

    def self.stop(pid)
      Process.kill('TERM', -pid)
      sleep 1
      Process.kill('KILL', -pid)
    rescue SystemCallError
      nil
    end
  end
end
