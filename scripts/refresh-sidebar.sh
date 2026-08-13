#!/usr/bin/env bash
# Regenerates the sidebar widget JSON files (pixelfed.json, toots.json,
# commits.json, bluesky.json), announced-post stats (stats.json) and --
# where comments.approval is on -- the approved comments themselves
# (comments.json), then uploads only those to the deploy target, without
# rebuilding the whole site. Meant for cron.
#
# Usage:
#   ./scripts/refresh-sidebar.sh [--full]
#
# --full does this run's fetch over every announced post rather than just
# the recent ones. With moderation on, that is how a comment starred
# under an old post reaches the site without waiting for the weekly pass.
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
ruby scripts/refresh_sidebar.rb "$@" || code=$?
[ "$code" -eq 3 ] && exit 0
[ "$code" -ne 0 ] && exit "$code"

# Every file this refresh answers for, named whether or not it exists on
# disk right now. The absent ones are the point: a name deploy-web.sh
# cannot find locally but does find in its manifest is a request to take
# that file OFF the target, and this is the only run that ever makes it.
# refresh_sidebar.rb deletes comments.json when moderation is switched
# off, precisely so a since-rejected comment stops being readable at a
# public URL -- and while this list held only the files present on disk,
# comments.json simply dropped out of it and stayed live on the site until
# somebody happened to run a full deploy with --prune.
#
# Names that were never built and were never uploaded (the widgets a site
# has not configured) cost nothing: deploy-web.sh passes over them without
# a word. It used to abort on them, which is why this was a loop over
# existing files -- and a loop rather than `ls <names>`, since ls exits
# non-zero when any name is missing and `set -euo pipefail` then killed
# the script here, leaving every site with fewer than all the widgets
# regenerating its JSONs and silently never uploading them.
only="pixelfed.json,toots.json,commits.json,bluesky.json,rss.json,stats.json,comments.json"

# Nothing has ever been built here, so there is nothing to send and nothing
# on the target to take down either -- a site that has not been deployed has
# no manifest for an absent name to be missing from. deploy-web.sh treats
# that as an error, which is right when a person typed the command and
# wrong on a cron tick: a non-zero exit here is a mail every half hour
# saying the same thing about a site nobody has finished setting up yet.
#
# Named as its own case rather than restored as the old "no files to
# upload" guard, which is what this replaced: that one skipped the upload
# whenever public.nosync held none of these files, and skipping is exactly
# what left a deleted comments.json live on the site.
if [ ! -d public.nosync ]; then
  echo "Nothing built yet (no public.nosync/) -- nothing to upload."
  exit 0
fi

# --busy-ok: if a build or publish took the lock between the refresh and
# here, skipping the upload quietly is right for a cron tick -- the next
# one re-does the whole thing anyway.
exec ./scripts/deploy-web.sh "--only=$only" --busy-ok
