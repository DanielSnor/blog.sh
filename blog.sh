#!/usr/bin/env bash
# Runs scripts/manage_post.rb with the environment from env.sh (SITE_BASE_URL, MASTODON_ACCESS_TOKEN).
# Usage:
#   ./blog.sh add
#   ./blog.sh edit [<slug>]
#   ./blog.sh publish [<slug>]
#   ./blog.sh unpublish [<slug>]
#   ./blog.sh delete [<slug>]
#   ./blog.sh restore [<slug>]
#   ./blog.sh toot [<slug>]
#   ./blog.sh rebuild
#   ./blog.sh list [--type=image] [--tag=foo]
#   ./blog.sh help
#   ./blog.sh                      (no command launches the wizard)
set -euo pipefail
cd "$(dirname "$0")"

# Help needs no environment, so it must not be gated on env.sh existing --
# `./blog.sh help` is the first thing a fresh clone gets asked for, and
# "Missing env.sh" is the wrong first impression. Before the clear too,
# or the usage would scroll away. Same arrangement as import.sh.
case "${1:-}" in
  help | --help | -h)
    exec ruby scripts/manage_post.rb help
    ;;
esac

[ -t 1 ] && clear
mode="${1:-}"
echo "== blog.sh =="
echo "Mode: ${mode:-wizard}"
echo

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  echo "An unedited copy is enough to try things out locally (uploads are skipped)."
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/manage_post.rb "$@"
