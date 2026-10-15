#!/usr/bin/env bash
# scripts/enroll.sh -- the forced command of a pairing code's key, and
# the only thing that key can do: hand in the public key of the app that
# read the code (lib/pairing.rb says the whole of it).
#
#   restrict,expiry-time="...",command="/path/to/blog/scripts/enroll.sh <id>" ssh-ed25519 AAAA... blog.sh-pair:<id>
#
# The line is written by `./blog.sh pair` and lives ten minutes. One word
# is allowed as the SSH command, `enroll`, and standard input is one line
# of JSON: {"key": "ssh-ed25519 AAAA...", "name": "the device's name"}.
#
# Like remote.sh: the answer is one JSON object and the status is 0,
# whatever the answer, and the word a stranger sent is never echoed back.
set -uo pipefail
CDPATH=
cd "$(dirname "$0")/.." >/dev/null || { printf '{"ok":false,"error":"no_cd","message":"Cannot reach the installation directory."}\n'; exit 0; }

case "${SSH_ORIGINAL_COMMAND:-}" in
  enroll)
    if ! command -v ruby >/dev/null 2>&1; then
      printf '{"ok":false,"error":"no_ruby","message":"Ruby is not on the PATH the forced command runs with."}\n'
      exit 0
    fi
    exec ruby scripts/enroll.rb "${1:-}"
    ;;
  *)
    printf '{"ok":false,"error":"unknown_command","message":"Only enroll is allowed on this key."}\n'
    exit 0
    ;;
esac
