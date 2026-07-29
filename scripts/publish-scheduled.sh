#!/usr/bin/env bash
# Publishes scheduled drafts whose date has arrived (marked via
# ./blog.sh schedule), then rebuilds and deploys the site once.
# Meant for cron; does nothing (and touches nothing) when no post is due.
#
# Usage:
#   ./scripts/publish-scheduled.sh
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
exec ruby scripts/publish_scheduled.rb
