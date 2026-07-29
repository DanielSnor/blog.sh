#!/usr/bin/env bash
# Regenerates the sidebar widget JSON files (pixelfed.json, toots.json,
# commits.json) and tooted-post stats (stats.json), and uploads only those
# to Surfer -- without rebuilding the whole site.
# Meant for cron.
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
exec ./scripts/deploy-web.sh --only=pixelfed.json,toots.json,commits.json,stats.json
