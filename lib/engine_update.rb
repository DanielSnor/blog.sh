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
  TIMEOUT = 20

  # [:not_a_clone] | [:unanswered, message] | [:no_tags] |
  # [:current, current] | [:newer, newest, current, place]
  # place: :main, :tag, or the name of another branch.
  module_function

  def status(root)
    return [:not_a_clone] unless File.exist?(File.join(root, '.git'))

    out, err, ok = git(root, 'ls-remote', '--tags', '--refs', 'origin', 'v*')
    return [:unanswered, err.to_s.lines.first.to_s.strip] unless ok

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

  def place(root)
    branch, _, ok = git(root, 'symbolic-ref', '-q', '--short', 'HEAD')
    return :tag unless ok

    branch.strip == 'main' ? :main : branch.strip
  end

  # git with no prompt for a password and a deadline: a remote that asks
  # for credentials or does not answer must not hold doctor up.
  def git(root, *args)
    env = { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_ASKPASS' => 'true', 'LC_ALL' => 'C' }
    Open3.popen3(env, 'git', '-C', root, *args) do |stdin, stdout, stderr, wait|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      unless wait.join(TIMEOUT)
        Process.kill('TERM', wait.pid)
        return ['', "no answer in #{TIMEOUT} s", false]
      end
      [out.value, err.value, wait.value.success?]
    end
  rescue SystemCallError => e
    ['', e.message, false]
  end
end
