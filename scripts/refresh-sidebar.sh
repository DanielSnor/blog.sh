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

# The same Ruby floor blog.sh checks at the door -- under cron with a
# minimal PATH, a system Ruby 2.6 would otherwise die mid-run with a
# NoMethodError instead of a sentence.
if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby not found in PATH -- blog.sh needs Ruby 2.7 or newer (cron PATH may lack rbenv/brew)."
  exit 1
fi
if ! ruby -e 'exit((RUBY_VERSION.split(".").map(&:to_i) <=> [2, 7]) >= 0)'; then
  echo "ruby $(ruby -e 'print RUBY_VERSION') is too old -- blog.sh needs Ruby 2.7 or newer (cron PATH may lack rbenv/brew)."
  exit 1
fi

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  exit 1
fi

set -a
source env.sh
set +a
# Exit 3 = another run holds the build lock. That is a quiet skip, not a
# failure: nothing was regenerated, so there is nothing to upload, and
# cron is back in half an hour. Anything else non-zero is real.
# NOT `if ! ruby ...; then code=$?`: inside that branch $? is the status of
# the NEGATED pipeline, which is always 0 -- so the exit-3 test never
# matched and every real failure was reported to cron as success. A
# monitored job (systemd, launchd) then sees a clean run forever while the
# sidebar has not refreshed for weeks.
# `|| code=$?` and not a bare call: `set -e` would end the script at the
# first non-zero status, and not `if ! ruby ...; then code=$?` either --
# inside that branch $? is the status of the NEGATED pipeline, always 0,
# so the exit-3 test never matched and every real failure was reported to
# cron as SUCCESS. A monitored job then sees a clean run forever while
# the sidebar has not refreshed for weeks.
code=0
ruby scripts/refresh_sidebar.rb || code=$?
[ "$code" -eq 3 ] && exit 0
[ "$code" -ne 0 ] && exit "$code"

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

# --busy-ok: if a build or publish took the lock between the refresh and
# here, skipping the upload quietly is right for a cron tick -- the next
# one re-does the whole thing anyway.
exec ./scripts/deploy-web.sh "--only=$only" --busy-ok
