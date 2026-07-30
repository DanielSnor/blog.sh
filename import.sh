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
in env.sh), and four things you already have on disk -- a Twitter/X archive,
a Mastodon account archive, a Pixelfed statuses export, and WordPress or any
RSS/Atom feed (one option, since a WXR export is RSS with extra elements and
the file itself says which it is).

Each source is also a script, for cron or a scripted migration. These write
immediately, with no preview pass:

  ruby scripts/migrate_bluesky.rb <handle>
  ruby scripts/migrate_tumblr.rb <blog-name>.tumblr.com
  ruby scripts/migrate_twitter.rb <path-to-extracted-export>
  ruby scripts/migrate_mastodon.rb <path-to-unpacked-archive>
  ruby scripts/migrate_pixelfed.rb <path-to-statuses.json>
  ruby scripts/migrate_feed.rb <export.xml | feed-url>

LIMIT=n works on all of them and imports only the first n posts -- the way to
sample a large archive before committing hours to it.

Re-running any import is safe: posts are matched on their source id and
overwritten in place, never duplicated. Nothing is deployed either way --
the wizard offers a rebuild at the end, the scripts leave that to you.
USAGE
    exit 0
    ;;
esac

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
