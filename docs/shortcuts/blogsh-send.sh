#!/data/data/com.termux/files/usr/bin/bash
# blogsh-send -- takes the newest bundle the writing page saved and hands
# the files inside it to the blog, one connection, pictures first.
#
# The page at /write/ is the same page on iOS and on Android. What differs
# is only the last step: on iOS two Shortcuts carry the files, and here a
# script does. Everything the blog needs to know is in the delivery
# itself, so this file is twenty lines and no configuration.
set -euo pipefail

HOST=${BLOGSH_HOST:?set BLOGSH_HOST=user@host}
KEY=${BLOGSH_KEY:-$HOME/.ssh/blogsh}
PORT=${BLOGSH_PORT:-22}
DOWNLOADS=${BLOGSH_DOWNLOADS:-$HOME/storage/downloads}

zip=$(ls -t "$DOWNLOADS"/post*.zip 2>/dev/null | head -1) || true
[ -n "${zip:-}" ] || { echo "No post*.zip in $DOWNLOADS -- press Send on the page first."; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$zip" -d "$work"

# The page packs the pictures first and the markdown last, and the
# markdown arriving is what makes the post -- so the archive's own order
# is the order to send in. `ls` would sort it alphabetically and put the
# text in the middle of the pictures it names.
answer=$(unzip -Z1 "$zip" | while IFS= read -r name; do
  printf '%s\n' "$name"
  # Fed on standard input, not named as an argument: coreutils takes both,
  # the base64 on a Mac takes only this one, and a line that works in both
  # places is a line somebody can try before they trust it.
  base64 < "$work/$name"
  printf '.\n'
done | ssh -i "$KEY" -p "$PORT" -o BatchMode=yes "$HOST")

printf '%s\n' "$answer"
# The page finds out on its own -- it asks the blog for the receipt it
# sent with the post -- so this is for the person holding the phone.
command -v termux-notification >/dev/null &&
  termux-notification --title "blog.sh" --content "$(printf '%s' "$answer" | tail -1)"
