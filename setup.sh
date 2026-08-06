#!/usr/bin/env bash
# Runs scripts/setup.rb: the core setup wizard.
#
# Usage:
#   ./setup.sh                     (the wizard: answer, review the diff, confirm)
#
# Its own door rather than a line in ./blog.sh, for a reason that is
# visible the moment somebody unpacks a fresh clone and types `ls`:
# setup.sh is self-evidently where you start. blog.sh, by contrast,
# stops with "Missing env.sh" until this has run at least once -- and
# "the thing to run first" should not be reachable only through the
# thing that refuses to run.
#
# Nothing is written until the end: the wizard collects every answer,
# shows both files' diffs, and asks once. Ctrl-C leaves the install
# exactly as it was. Re-running it is safe and is how you change any of
# these later -- every question arrives with the current value, and Enter
# keeps it.
#
# It covers the core: who the site is, what language it speaks, where it
# lives, which network carries its comments, and where it deploys.
# Appearance -- palette, header image, fonts, sidebar widgets, the
# footer -- has its own wizard in ./style.sh.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  help | --help | -h)
    cat <<'USAGE'
usage: ./setup.sh

Asks for the settings a site needs to work, checks the answers as it
goes, and writes them into config/site.yml and env.sh -- leaving every
comment in both files exactly where it was, so they stay readable and
hand-editable afterwards.

What it asks about:

  language          which of locales/*.yml the site (and this wizard) speaks
  identity          title, short name, description, author
  timezone          checked against this machine's zone database -- a typo
                    here would silently date every post wrong
  address           the canonical URL, in both files, since env.sh's copy
                    overrides config/site.yml's and shipping them out of
                    step is a trap
  comments network  Mastodon or Bluesky (never both -- the build refuses
                    that), with the access token verified against the
                    instance on the spot; the numeric account id for the
                    toots sidebar widget is read back out of that same
                    check, so nobody has to go and find it
  deploy target     one of the six backends, each asking only for its own
                    values, or "not yet" for a site that has nowhere to go

Every question can be skipped with Enter, which keeps the current value.
Nothing is written until you have seen the diff and confirmed it; the
result is verified by reading it back, and restored from a backup if it
does not read back the way it was asked for.

Related:
  ./style.sh          appearance: palette, header image, fonts, widgets, footer
  ./blog.sh doctor    reads the configuration and says what is wrong with it
USAGE
    exit 0
    ;;
esac

# Same prerequisite check as blog.sh and import.sh -- see the comment
# there. Help above needs no Ruby, so this sits after it.
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

[ -t 1 ] && clear

# env.sh is read when it exists and is NOT required when it doesn't --
# the opposite of blog.sh's guard, and the whole point: this is the
# command that creates it. Sourcing an existing one means every question
# about a token or a deploy target arrives with the current answer in it.
if [ -f env.sh ]; then
  set -a
  # shellcheck source=/dev/null
  . ./env.sh
  set +a
fi

exec ruby scripts/setup.rb "$@"
