# frozen_string_literal: true

# lib/version.rb -- the one place the engine's version is written down.
#
# It used to be written down twice, both times as a literal inside a
# User-Agent string, so every request this engine made to a third-party
# feed and every upload to the deploy target announced "1.0" no matter
# what was actually running. A version nobody can read back from a running
# installation is not much use either -- `./blog.sh version` answers the
# "what's on the server?" question without SSH archaeology.
#
# Bumped by hand in the release commit, with the git tag right behind it.
# Deriving it from `git describe` at runtime was considered and dropped:
# an install from a tarball (or any copy without .git, which is how the
# engine gets vendored) would then report nothing at all.
module BlogSh
  VERSION = '1.5'

  # For the User-Agent headers: "blog-sh-<role>/<version>", with the role in
  # the name so a server log can tell a feed fetch from an upload. The
  # example stays version-less on purpose -- written out, it goes stale one
  # release later and nobody notices, which is what happened to "/1.1".
  def self.user_agent(role = nil)
    "blog-sh#{role ? "-#{role}" : ''}/#{VERSION}"
  end
end
