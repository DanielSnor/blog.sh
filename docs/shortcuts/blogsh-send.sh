#!/data/data/com.termux/files/usr/bin/bash
# blogsh-send -- takes the newest delivery the writing page saved and hands
# it to the blog, one connection, pictures first.
#
# The page at /write/ is the same page on iOS and on Android. What differs
# is only the last step: on iOS two Shortcuts carry the files, and here a
# script does. Everything the blog needs to know is in the delivery itself,
# so this file takes no configuration beyond where to send.
set -euo pipefail

HOST=${BLOGSH_HOST:?set BLOGSH_HOST=user@host}
KEY=${BLOGSH_KEY:-$HOME/.ssh/blogsh}
PORT=${BLOGSH_PORT:-22}
DOWNLOADS=${BLOGSH_DOWNLOADS:-$HOME/storage/downloads}

# The page saves two kinds of delivery: a bundle, which is a post, and
# publish.txt, which is "send the post that is already up there". Newest
# wins, because that is the one whose button was just pressed -- looking
# only for the bundle meant a Publish press re-sent the previous post.
delivery=$(ls -t "$DOWNLOADS"/post*.zip "$DOWNLOADS"/publish.txt 2>/dev/null | head -1) || true
[ -n "${delivery:-}" ] || {
  echo "No post*.zip or publish.txt in $DOWNLOADS -- press Send or Publish on the page first."
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
if [ "${delivery##*/}" = "publish.txt" ]; then
  cp "$delivery" "$work/publish.txt"
  names=publish.txt
else
  unzip -q "$delivery" -d "$work"
  # The page packs the pictures first and the markdown last, and the
  # markdown arriving is what makes the post -- so the archive's own order
  # is the order to send in. `ls` would sort it alphabetically and put the
  # text in the middle of the pictures it names.
  names=$(unzip -Z1 "$delivery")
fi

# A regular file or nothing at all. unzip restores a symlink entry as a
# symlink and base64 follows it, so an archive from anywhere other than the
# page -- a browser download, a messaging app -- could have this script read
# any file the phone can read and publish it as media on the blog.
#
# The status is caught rather than fatal: receive.sh answers a refusal with
# a sentence and keeps a non-zero exit for the cases where it has something
# to say and no post to show, and dying at the assignment threw exactly
# those messages away, leaving the phone with a bare exit code.
status=0
answer=$(printf '%s\n' "$names" | while IFS= read -r name; do
  [ -f "$work/$name" ] && [ ! -L "$work/$name" ] ||
    { echo "refusing $name -- not a regular file" >&2; exit 3; }
  # Fed on standard input, not named as an argument: coreutils takes both,
  # the base64 on a Mac takes only this one, and a line that works in both
  # places is a line somebody can try before they trust it.
  printf '%s\n' "$name"
  base64 < "$work/$name"
  printf '.\n'
done | ssh -i "$KEY" -p "$PORT" -o BatchMode=yes "$HOST") || status=$?

printf '%s\n' "$answer"
# Set aside rather than left lying: nothing else marks a delivery as sent,
# so a second tap of the widget sent the same post again -- and since a
# broken connection used to look like silence, tapping again is exactly
# what somebody does.
if [ "$status" -eq 0 ]; then
  mv "$delivery" "$delivery.sent"
fi

# The page finds out on its own -- it asks the blog for the receipt it sent
# with the post -- so this is for the person holding the phone. The answer
# is pretty-printed JSON, so its last line is a closing brace: the lines
# worth reading are the ones naming the post or the refusal.
summary=$(printf '%s\n' "$answer" | grep -E '"(slug|state|error)"' | tr -d ' "' | tr '\n' ' ')
[ -n "$summary" ] || summary="no answer from the blog (exit $status)"
if command -v termux-notification >/dev/null; then
  termux-notification --title "blog.sh" --content "$summary" || true
fi
exit "$status"
