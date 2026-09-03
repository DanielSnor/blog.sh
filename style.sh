#!/usr/bin/env bash
# Runs scripts/style.rb: the appearance wizard.
#
# Usage:
#   ./style.sh                     (a menu: pick a section, as often as you like)
#
# Separate from ./setup.sh by lifecycle rather than by file -- both write
# config/site.yml. Setup asks the few things you answer once and never
# revisit (timezone, address, which network carries the comments); this
# is everything you will come back and change: the palette, the header
# image, your own bio, the footer, the sidebar widgets.
#
# So setup runs top to bottom and this is a menu you dip into. Same
# guarantees either way: every question can be skipped, nothing is
# written until you have seen the diff and confirmed it, and the file
# keeps every comment it had.
set -euo pipefail
BLOG_SH_PWD="$PWD"
export BLOG_SH_PWD
cd "$(dirname "$0")"

case "${1:-}" in
  help | --help | -h)
    # The same identity block the wizard opens with, so "which install's
    # help am I reading" has an answer. Ruby may be missing or ancient
    # here (its check comes later) -- then the banner is skipped and the
    # help still prints.
    ruby -r./lib/site_header -e "puts SiteHeader.render(tool: './style.sh')" 2>/dev/null && echo || true
    cat <<'USAGE'
usage: ./style.sh

A menu of the settings that decide how the site LOOKS and what it says
about itself. Pick a section, answer what you want to change, pick
another; the changes are written once at the end, after you have seen
them as a diff.

  palette     the seven colours per mode, as a whole palette rather than
              fourteen prompts -- pick one of the palettes the engine ships
              in config/palettes.yml, add your own, or enter the values by hand
  banner      point it at an image file: it is copied into place and
              MEASURED, so banner.width/height match the file and pages
              stop jumping as it loads
  about       the heading and the bio, the bio through your $EDITOR since
              it is prose and may contain HTML
  footer      the headings, the copyright line, the note, and the links
  social      the row of icons, including the rel="me" that earns the
              verification tick on a Mastodon profile
  widgets     the sidebar: recent toots, Pixelfed posts, commits, Bluesky
              posts, or any RSS feed
  fonts       the banner title's and claim's font stack and size
  analytics   the script, if you run one

Nothing here is required: a site with none of it configured is a working
site. The run ends by offering a rebuild, because appearance is the one
thing a diff cannot show you.

Related:
  ./setup.sh          identity, address, comments network, deploy target
  ./blog.sh doctor    reads the configuration and says what is wrong with it
USAGE
    exit 0
    ;;
esac

# Same prerequisite check as the other wrappers -- see blog.sh.
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

# `clear` fails on a TERM this machine has no terminfo entry for --
# ghostty, kitty, wezterm and friends ship theirs into ~/.terminfo, which
# a fresh account or an SSH target does not have. As the last command of
# an AND-list it is what `set -e` sees, so the whole tool died before
# printing a word. A screen that cannot be cleared is not a reason to
# refuse to run.
{ [ -t 1 ] && clear 2>/dev/null; } || true

# Read when present, not required: this wizard writes only site.yml, but
# the rebuild it offers at the end deploys nothing without env.sh's
# values and should say so accurately.
if [ -f env.sh ]; then
  set -a
  # shellcheck source=/dev/null
  . ./env.sh
  set +a
fi

exec ruby scripts/style.rb "$@"
