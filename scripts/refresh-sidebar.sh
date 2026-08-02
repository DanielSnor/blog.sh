#!/usr/bin/env bash
# Regenerates the sidebar widget JSON files (pixelfed.json, toots.json,
# commits.json, bluesky.json) and announced-post stats (stats.json), and
# uploads only those to the deploy target -- without rebuilding the
# whole site. Meant for cron.
#
# Usage:
#   ./scripts/refresh-sidebar.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  exit 1
fi

set -a
source env.sh
set +a
ruby scripts/refresh_sidebar.rb

# Upload whichever widget files this site actually has -- Sidebar.FEEDS
# only writes JSONs for configured widgets, so a hardcoded list makes
# deploy-web.sh abort on any site using a subset of them ("not found in
# public.nosync/"). stats.json always exists; refresh_sidebar.rb just
# wrote it.
#
# Built with a loop rather than `ls <names>`: ls exits non-zero when ANY
# name is missing, and under `set -euo pipefail` that killed the script
# right here -- so every site configuring fewer than all five widgets
# regenerated its JSONs and then silently never uploaded them.
only=""
for f in pixelfed.json toots.json commits.json bluesky.json rss.json stats.json; do
  [ -f "public.nosync/$f" ] || continue
  only="${only:+$only,}$f"
done

if [ -z "$only" ]; then
  echo "No sidebar files to upload (no widgets configured?) -- nothing to do."
  exit 0
fi

exec ./scripts/deploy-web.sh "--only=$only"
