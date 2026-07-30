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
