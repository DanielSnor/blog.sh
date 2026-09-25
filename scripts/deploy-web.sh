#!/usr/bin/env bash
# Uploads public.nosync/ to the deploy backend configured in env.sh
# (DEPLOY_BACKEND: surfer | local | rsync | git | rclone | sftp; unset
# falls back to Surfer). Run wherever the build runs.
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

# The header and the mode line are printed by deploy_web.rb, in the
# site's language -- a shell echo could only ever say them in English. Only
# for a run started here: the engine's own callers (rebuild, the palette
# preview) run deploy_web.rb directly and never printed them.
export BLOG_SH_DEPLOY_HEADER=1
if [ ! -f env.sh ]; then
  echo "Missing env.sh -- copy the documented template first:"
  echo "  cp env.sh.example env.sh && chmod 600 env.sh"
  exit 1
fi

set -a
source env.sh
set +a
exec ruby scripts/deploy_web.rb "$@"
