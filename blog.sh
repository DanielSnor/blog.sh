#!/usr/bin/env bash
# Runs scripts/manage_post.rb with the environment from env.sh (SITE_BASE_URL, MASTODON_ACCESS_TOKEN).
# Usage:
#   ./blog.sh add [<file>] [--json]
#   ./blog.sh edit [<slug>]
#   ./blog.sh props [<slug>]
#   ./blog.sh publish [<slug>] [--yes] [--no-announce] [--json]
#   ./blog.sh unpublish [<slug>]
#   ./blog.sh delete [<slug>]
#   ./blog.sh restore [<slug>]
#   ./blog.sh empty trash|versions
#   ./blog.sh toot [<slug>]
#   ./blog.sh rebuild [--full]
#   ./blog.sh browse [--type=image] [--tag=foo]
#   ./blog.sh list [--type=image] [--tag=foo]
#   ./blog.sh doctor [--online] [--strip-location]
#   ./blog.sh check [--online] [--json] [--repair]
#   ./blog.sh export [<dir>] [--no-drafts] [--dry-run] [--force]
#   ./blog.sh stats [--json]
#   ./blog.sh help
#   ./blog.sh                      (no command launches the wizard)
set -euo pipefail
# Remembered BEFORE the cd, because after it nothing can tell where the
# caller was standing -- and `add sub/clanek.md` from a script means a
# file next to the SCRIPT, not one next to the engine. Exported rather
# than passed so every command gets it without a signature change.
BLOG_SH_PWD="$PWD"
export BLOG_SH_PWD
cd "$(dirname "$0")"

# The one real prerequisite, checked before anything else so a missing or
# ancient Ruby fails as a sentence with the fix in it -- not as
# "exec: ruby: not found" or a NoMethodError mid-post. macOS ships Ruby
# 2.6 as /usr/bin/ruby on every current version, hence the brew hint.
if ! command -v ruby >/dev/null 2>&1; then
  echo "❌ Ruby not found -- blog.sh needs Ruby 2.7 or newer."
  echo "   macOS:         brew install ruby   (then add it to PATH as brew instructs)"
  echo "   Debian/Ubuntu: sudo apt install ruby-full"
  echo "   Windows:       use WSL2 and follow the Debian/Ubuntu line"
  exit 1
fi
if ! ruby -e 'exit((RUBY_VERSION.split(".").map(&:to_i) <=> [2, 7]) >= 0)'; then
  echo "❌ Ruby $(ruby -e 'print RUBY_VERSION') is too old -- blog.sh needs Ruby 2.7 or newer."
  echo "   macOS: the system /usr/bin/ruby stays at 2.6; brew install ruby and put it first in PATH."
  exit 1
fi

# Help needs no environment, so it must not be gated on env.sh existing --
# `./blog.sh help` is the first thing a fresh clone gets asked for, and
# "Missing env.sh" is the wrong first impression. Before the clear too,
# or the usage would scroll away. Same arrangement as import.sh.
case "${1:-}" in
  help | --help | -h)
    exec ruby scripts/info.rb help
    ;;
  # Same reasoning as help, plus one of its own: "which version is this
  # install running?" is a question asked of a machine that is already
  # misbehaving -- it must not depend on env.sh or config being right.
  # Both go to scripts/info.rb rather than manage_post.rb, for the reason
  # its header gives: requiring manage_post.rb reads config/site.yml at
  # load time through half a dozen libraries, so on a config that will not
  # parse these two died before they could answer -- exactly the install
  # whose owner is asking.
  version | --version | -v)
    exec ruby scripts/info.rb version
    ;;
  # Doctor takes that furthest: it exists to explain an install with no
  # env.sh, no config, or a config that won't parse, so the "Missing
  # env.sh" guard below would turn away the one command that could say
  # what to do about it. It still reads env.sh when there IS one --
  # half of what it checks (the access token, the deploy target) lives
  # there -- and goes to its own script for the reasons in its header.
  doctor)
    shift
    if [ -f env.sh ]; then
      set -a
      # shellcheck source=/dev/null
      . ./env.sh
      set +a
    fi
    exec ruby scripts/doctor.rb "$@"
    ;;
  # Reads the archive rather than the configuration, so it needs no env.sh
  # at all -- everything it looks at is on disk in content.nosync and
  # media.nosync. Its own script for the same reason doctor has one.
  check)
    shift
    exec ruby scripts/check.rb "$@"
    ;;
  # Same door as check, for the same reason and one more: leaving with
  # your posts has to work on the installation you are leaving. A config
  # that no longer parses, a token that expired, a deploy target that is
  # gone -- none of that is a reason to be unable to take the archive out.
  export)
    shift
    exec ruby scripts/export.rb "$@"
    ;;
  # Counts the archive on disk, so it needs no env.sh either -- and it is
  # the command most likely to be piped somewhere (--json), which is
  # another reason not to make it depend on a configuration being right.
  stats)
    shift
    exec ruby scripts/stats.rb "$@"
    ;;
esac

# No banner here: the identity block (which engine, which site, which
# mode) is printed by the Ruby side via SiteHeader, which knows the
# version and the site's name -- this wrapper knows neither.
# `clear` fails on a TERM this machine has no terminfo entry for --
# ghostty, kitty, wezterm and friends ship theirs into ~/.terminfo, which
# a fresh account or an SSH target does not have. As the last command of
# an AND-list it is what `set -e` sees, so the whole tool died before
# printing a word. A screen that cannot be cleared is not a reason to
# refuse to run.
{ [ -t 1 ] && clear 2>/dev/null; } || true

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  echo "An unedited copy is enough to try things out locally (uploads are skipped)."
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/manage_post.rb "$@"
