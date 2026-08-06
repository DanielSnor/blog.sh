#!/usr/bin/env bash
# Runs scripts/import.rb with the environment from env.sh, the same way
# blog.sh does for authoring. Separate from blog.sh on purpose: importing is
# a rare bulk operation that writes thousands of posts at once, so it gets
# its own door rather than a line in the authoring menu.
#
# Usage:
#   ./import.sh                    (the wizard: pick a source, preview, confirm)
#
# Every import previews in dry-run first and asks before writing anything.
# Re-running an import is safe -- posts are matched on their source id and
# overwritten in place rather than duplicated.
set -euo pipefail
cd "$(dirname "$0")"

# Before the clear below, or help would scroll away the moment it printed.
case "${1:-}" in
  help | --help | -h)
    cat <<'USAGE'
usage: ./import.sh

Opens the import wizard: pick a source, see a dry-run preview of what would
be written -- posts, media files, the first few slugs, and how many items
were skipped and why -- then confirm before anything is written. Confirming
means typing the number of posts, not pressing y: it's the one answer you
can't give without having read the preview.

Sources: Bluesky (public API, no credentials), Tumblr (needs TUMBLR_API_KEY
in env.sh), and seven things you already have on disk -- a Ghost JSON
export (plus the still-running site's URL, its images only exist there),
an unpacked Substack export, a Twitter/X archive, a Mastodon account
archive, a Pixelfed statuses export, an Instagram export (HTML or JSON,
whichever you asked Instagram for), and WordPress or any RSS/Atom feed
(one option, since a WXR export is RSS with extra elements and the file
itself says which it is).

Each source is also a script, for cron or a scripted migration. These write
immediately, with no preview pass:

  ruby scripts/migrate_bluesky.rb <handle>
  ruby scripts/migrate_ghost.rb <export.json> <https://old-site.example>
  ruby scripts/migrate_instagram.rb <path-to-unpacked-export>
  ruby scripts/migrate_mastodon.rb <path-to-unpacked-archive>
  ruby scripts/migrate_pixelfed.rb <path-to-statuses.json>
  ruby scripts/migrate_substack.rb <path-to-unpacked-export>
  ruby scripts/migrate_tumblr.rb <blog-name>.tumblr.com
  ruby scripts/migrate_twitter.rb <path-to-extracted-export>
  ruby scripts/migrate_feed.rb <export.xml | feed-url>

LIMIT=n works on all of them and imports only the first n posts -- the way to
sample a large archive before committing hours to it.

When the new site keeps the old blog's domain, imports from sources that
know their original URLs (WordPress or a feed, Tumblr) can keep the old
addresses alive: the wizard asks, the scripts take KEEP_PERMALINKS=1, and
every published post then redirects from the path it used to live at.

Re-running any import is safe: posts are matched on their source id and
overwritten in place, never duplicated. Nothing is deployed either way --
the wizard offers a rebuild at the end, the scripts leave that to you.
USAGE
    exit 0
    ;;
esac

# Same prerequisite check as blog.sh -- see the comment there. Help above
# needs no Ruby, so this sits after it.
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
echo "== blog.sh import =="
echo

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  echo "An unedited copy is enough for imports that only read a public API."
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/import.rb "$@"
