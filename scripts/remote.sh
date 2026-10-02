#!/usr/bin/env bash
# scripts/remote.sh -- the forced command for a program's key: an app on a
# phone, a script on another machine. Two words are allowed as the SSH
# command, and nothing else:
#
#   run      one engine command; its argv arrives on standard input as one
#            line of JSON, {"args": ["props", "slug", "--set", "tags=a, b"]}, and
#            scripts/remote.rb checks every word against a whitelist before
#            ./blog.sh sees it (see there for what is refused);
#   receive  a delivery of files, the shape scripts/receive.sh takes;
#   deliver  the same delivery, ended by a line saying `end` instead of by
#            the end of the stream -- for a sender that cannot close its
#            side (the app's SSH library); scripts/remote.rb reads it up to
#            that line and hands it to receive.sh whole.
#
#   restrict,command="/path/to/blog/scripts/remote.sh" ssh-ed25519 AAAA... app
#
# Everything answers as one JSON object and leaves with 0, for the reason
# receive.sh gives: the status says whether an answer arrived, the object
# says what it was. The command word is never echoed back -- it is the
# one thing a stranger chooses here, and an answer must stay JSON.
set -uo pipefail
CDPATH=
cd "$(dirname "$0")/.." >/dev/null || { printf '{"ok":false,"error":"no_cd","message":"Cannot reach the installation directory."}\n'; exit 0; }

case "${SSH_ORIGINAL_COMMAND:-${1:-}}" in
  run)
    if ! command -v ruby >/dev/null 2>&1; then
      printf '{"ok":false,"error":"no_ruby","message":"Ruby is not on the PATH the forced command runs with."}\n'
      exit 0
    fi
    exec ruby scripts/remote.rb
    ;;
  receive)
    exec scripts/receive.sh
    ;;
  deliver)
    if ! command -v ruby >/dev/null 2>&1; then
      printf '{"ok":false,"error":"no_ruby","message":"Ruby is not on the PATH the forced command runs with."}\n'
      exit 0
    fi
    exec ruby scripts/remote.rb --deliver
    ;;
  '')
    printf '{"ok":false,"error":"no_command","message":"Say run, receive or deliver."}\n'
    exit 0
    ;;
  *)
    printf '{"ok":false,"error":"unknown_command","message":"Only run, receive and deliver are allowed on this key."}\n'
    exit 0
    ;;
esac
