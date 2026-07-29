#!/usr/bin/env bash
# Uploads public.nosync/ to Surfer, using the environment from env.sh
# (SURFER_URL, SURFER_TOKEN, SURFER_REMOTE_DIR).
# Run this on the server (inside the Docker container that has Ruby).
#
# Smart sync: uploads only new/changed files (by SHA256 in
# .deploy_manifest.json), not the whole public.nosync/ every time.
#
# Usage:
#   ./scripts/deploy-web.sh             # only new/changed files
#   ./scripts/deploy-web.sh --force     # ignores the manifest, uploads everything
#   ./scripts/deploy-web.sh --only=X    # just one specific file
#   ./scripts/deploy-web.sh --prune     # also deletes orphaned files on Surfer
#   ./scripts/deploy-web.sh --dry-run   # preview of what would be uploaded
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== deploy-web.sh =="
case "$*" in
  *--dry-run*) echo "Mode: preview (dry-run) -- nothing is actually uploaded." ;;
  *--only=*)   echo "Mode: single file ($*)." ;;
  *--force*)   echo "Mode: forced upload of everything (--force)." ;;
  *)           echo "Mode: smart sync -- uploading only new/changed files." ;;
esac
echo "Uploading to Surfer..."
echo

if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/deploy_web.rb "$@"
