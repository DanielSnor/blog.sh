# frozen_string_literal: true

# lib/engine_update.rb -- whether a newer release of the engine is out, for
# `doctor --online` (Pavel, #87).
#
# Compared by version, not by commit. HEAD against origin/main would be
# wrong in the two setups docs/install.md describes besides main: a clone
# put on a release tag is always another commit than main, and a clone on a
# branch of its own (sean.cz runs on one) is always "behind" it. So the
# release tags are read with `git ls-remote`, which writes nothing -- a
# `git fetch` from doctor would write into .git, and doctor is run by the
# paired apps too, as whichever user they come in as -- and the newest is
# compared with BlogSh::VERSION, the number the engine says it is.
#
# What to do about it depends on where the clone stands: on main it is
# `git pull`, on a tag `git checkout` of the newer one (pull refuses on no
# branch), on any other branch only the numbers, since what to merge into
# a branch of one's own is its owner's business.
require 'open3'
require_relative 'version'

module EngineUpdate
  # How long git may take. BLOG_SH_GIT_TIMEOUT is for the tests, which
  # cannot wait twenty seconds to see what happens after them.
  TIMEOUT = Float(ENV['BLOG_SH_GIT_TIMEOUT'] || 20)

  # [:not_a_clone] | [:unreadable, message] | [:unanswered, message] |
  # [:no_tags] | [:current, current] | [:newer, newest, current, place]
  # place: :main, :tag, :detached, or the name of another branch.
  module_function

  def status(root)
    return [:not_a_clone] unless File.exist?(File.join(root, '.git'))

    # Asked first, because ls-remote does not say it: a clone owned by
    # another user is one git will not read ("dubious ownership"), and
    # ls-remote then answered that origin "does not appear to be a git
    # repository" -- a warning that blamed the remote for the clone (fleet
    # over 1.12.1, D4).
    _, err, ok = git(root, 'rev-parse', '--git-dir')
    return [:unreadable, first_line(err)] unless ok

    out, err, ok = git(root, 'ls-remote', '--tags', '--refs', 'origin', 'v*')
    return [:unanswered, first_line(err)] unless ok

    newest = newest_release(out)
    return [:no_tags] unless newest

    current = BlogSh::VERSION
    return [:current, current] if Gem::Version.new(newest) <= Gem::Version.new(current)

    [:newer, newest, current, place(root)]
  end

  # The highest vX.Y[.Z] among the tags; a tag with anything after the
  # numbers (v1.13-rc1) is not a release.
  def newest_release(ls_remote)
    ls_remote.to_s.scan(%r{refs/tags/v(\d+(?:\.\d+)*)$}).flatten.max_by { |v| Gem::Version.new(v) }
  end

  # On no branch is not the same as on a release tag: a commit checked out
  # by hand, a bisect, a rebase half done are on no branch too, and were
  # told to `git checkout` the new tag -- out from under whatever was under
  # way (D3). Only a HEAD that IS a tag gets that advice.
  def place(root)
    branch, _, ok = git(root, 'symbolic-ref', '-q', '--short', 'HEAD')
    unless ok
      _, _, tagged = git(root, 'describe', '--exact-match', '--tags', 'HEAD')
      return tagged ? :tag : :detached
    end

    branch.strip == 'main' ? :main : branch.strip
  end

  def first_line(text)
    text.to_s.lines.first.to_s.strip
  end

  # git with no prompt and a deadline: a remote that asks for anything or
  # does not answer must not hold doctor up.
  #
  # GIT_TERMINAL_PROMPT covers git's own questions only. Over ssh it is ssh
  # that asks -- a key's passphrase with no agent, a host key not seen
  # before -- on the terminal doctor runs in, and doctor stood still until
  # the deadline (D2). BatchMode makes ssh refuse instead, unless whoever
  # runs this has said how ssh is to be run, in the environment or in
  # core.sshCommand: that is theirs and is left alone.
  #
  # The deadline kills git's whole process group, ssh with it, and the two
  # readers end quietly when their pipe closes under them -- they used to
  # print two backtraces into the middle of doctor's output (D1).
  def git(root, *args)
    env = { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_ASKPASS' => 'true', 'LC_ALL' => 'C' }
    env['GIT_SSH_COMMAND'] = 'ssh -o BatchMode=yes' if args.first == 'ls-remote' && ssh_unset?(root)
    Open3.popen3(env, 'git', '-C', root, *args, pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      out = reader(stdout)
      err = reader(stderr)
      unless wait.join(TIMEOUT)
        begin
          Process.kill('TERM', -wait.pid)
        rescue SystemCallError
          nil
        end
        return ['', "no answer in #{TIMEOUT.round} s", false]
      end
      [out.value, err.value, wait.value.success?]
    end
  rescue SystemCallError => e
    ['', e.message, false]
  end

  def reader(io)
    thread = Thread.new do
      io.read
    rescue IOError
      ''
    end
    thread.report_on_exception = false
    thread
  end

  def ssh_unset?(root)
    return false unless ENV['GIT_SSH_COMMAND'].to_s.empty? && ENV['GIT_SSH'].to_s.empty?

    out, = git(root, 'config', '--get', 'core.sshCommand')
    out.to_s.strip.empty?
  end
end
