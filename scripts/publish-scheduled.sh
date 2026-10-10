#!/usr/bin/env bash
# Publishes scheduled drafts whose date has arrived (marked via
# ./blog.sh schedule), then rebuilds and deploys the site once.
# Meant for cron; does nothing (and touches nothing) when no post is due.
#
# Usage:
#   ./scripts/publish-scheduled.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Every refusal below is written to stderr: the line the wizard hands to
# cron sends stdout to /dev/null, and cron mails what is left. Said on
# stdout, "ruby not found" went nowhere -- the queue simply never ran.
#
# The same Ruby floor blog.sh checks at the door -- under cron with a
# minimal PATH, a system Ruby 2.6 would otherwise die mid-run with a
# NoMethodError instead of a sentence.
if ! command -v ruby >/dev/null 2>&1; then
  echo "ruby not found in PATH -- blog.sh needs Ruby 2.7 or newer (cron PATH may lack rbenv/brew)." >&2
  exit 1
fi
if ! ruby -e 'exit((RUBY_VERSION.split(".").map(&:to_i) <=> [2, 7]) >= 0)'; then
  echo "ruby $(ruby -e 'print RUBY_VERSION') is too old -- blog.sh needs Ruby 2.7 or newer (cron PATH may lack rbenv/brew)." >&2
  exit 1
fi

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:" >&2
  echo "  cp env.sh.example env.sh && chmod 600 env.sh" >&2
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/publish_scheduled.rb
