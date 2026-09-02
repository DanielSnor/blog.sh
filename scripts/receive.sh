#!/usr/bin/env bash
# Takes ONE file from standard input and puts it in incoming/.
#
#   { printf '%s\n' photo.jpg; base64 < photo.jpg; echo .; } | ./scripts/receive.sh
#
# First line the name, then that file's base64, then a line with a dot --
# which is what says the transfer finished rather than stopped.
# A shortcut on a phone sends the pictures this way, one connection each,
# and the markdown last -- and the markdown arriving is what makes the
# post, because there is no other signal to give and none is needed.
# Everything before it is already staged under the names its text uses.
#
# ⚠️ An earlier version took a ZIP and unpacked it here. Three audits
# found nine, twelve and ten blockers in successive rewrites, nearly all
# of them in the archive handling. There is no archive now: what arrives
# from a network is a filename and a stream of bytes. The client had the
# files separately all along, so this asks it to do less, not more.
set -uo pipefail

cd "$(dirname "$0")/.." || { printf '{"ok":false,"error":"no_cd","message":"Cannot reach the installation directory."}\n'; exit 1; }
INSTALL="${1:-$PWD}"
MAX_MB="${BLOGSH_MAX_MB:-24}"

# ⚠️ A refusal leaves with 0. The answer is the OBJECT -- it says
# "ok":false and names the reason -- so the status is free to answer what
# the object cannot: whether an answer arrived at all. It was exit 1, and
# that cost the caller the reason, because iOS Shortcuts discards the
# output of a remote command that failed: every refusal a phone could
# meet came back as a bare status with the message gone.
# The two characters JSON cannot carry raw. Backslash first, or it would
# escape the backslashes the quote rule has just put in. Everything a
# caller is told carries the sender's own text -- a filename in a refusal,
# a filename in a receipt -- and one quotation mark in it would hand a
# program an answer that is not JSON at all.
json_escape() {
  t=${1//\\/\\\\}
  printf '%s' "${t//\"/\\\"}"
}

# ⚠️ A BARE filename and nothing else. This is the whole of what an
# untrusted sender chooses, so it is the whole of what has to be checked:
# no directory, no traversal, no leading dot (which hides a file from the
# author and from a glob), nothing empty.
check_name() {
  case "$1" in
    ''|.|..)      fail "bad_name" "A file in this delivery has no name." ;;
    */*|*\\*)     fail "bad_name" "A name may not contain a path: $1" ;;
    .*)           fail "bad_name" "A name may not begin with a dot: $1" ;;
  esac
  [ "${#1}" -le 255 ] || fail "bad_name" "A name is longer than a filesystem will take."
  # Control characters, asked BY THE BYTE and in a locale that cannot
  # disagree. A macOS screenshot is named "Screenshot ... 11.59.29 AM.png"
  # with a NARROW NO-BREAK SPACE in it, and both [![:print:]] and
  # [[:cntrl:]] answer differently depending on the locale a shell happens
  # to run under: one and the same delivery was taken by the server and
  # refused on a Mac. A space is a space, whatever width it is.
  if [ "$1" != "$(printf %s "$1" | LC_ALL=C tr -d '\000-\037\177')" ]; then
    fail "bad_name" "A name may not hold control characters."
  fi
}

fail() {  # an answer, so: 0
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(json_escape "$2")"
  exit 0
}

# No answer to give: the machine is not set up, the engine is missing.
unavailable() {
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(json_escape "$2")"
  exit 1
}

[ -d "$INSTALL/incoming" ] || unavailable "no_incoming" "No incoming/ directory in $INSTALL."
[ -x "$INSTALL/blog.sh" ] || unavailable "no_engine" "No executable blog.sh in $INSTALL."

# With a deadline: a caller that opens the connection and says nothing
# held a process for as long as the connection lasted (measured at sixty
# seconds). The name comes first and is short, so half a minute is
# generous; the bytes after it may take as long as a phone on a train.
# -n 1024: without a bound, `read` consumes until a newline, so bytes put
# BEFORE it evaded the ceiling -- 256 MB of them took 266 MB of memory
# with BLOGSH_MAX_MB=24 in force.
IFS= read -r -t 30 -n 1024 FIRST \
  || fail "empty_input" "Nothing arrived on standard input, or nothing was sent for thirty seconds."

WORK=$(mktemp -d) || unavailable "no_tmp" "Cannot create a temporary directory."
# A delivery carries somebody's photographs; they have no business staying
# in /tmp after a failure.
trap 'rm -rf "$WORK"' EXIT

# The deadline belongs to the FIRST line and the ceiling to everything
# after it, which is why they are read apart and put back together here.
# A caller that opens the connection and says nothing held a process for
# as long as the connection lasted; the bytes after the name may take as
# long as a phone on a train needs, and are bounded instead of timed.
# head stops READING at the ceiling, so a hostile sender costs that and
# not whatever they felt like sending.
head -c $(( (MAX_MB * 1048576) + 1 )) > "$WORK/rest"
# ⚠️ Measured on the BYTES AFTER the first line, not on the two glued
# together. Weighing the whole thing let a first line of any length eat
# into the allowance, and worse: head cuts the stream at the ceiling, so
# an over-sized delivery lost its closing dot and was refused as
# `truncated` -- a true sentence about the wrong thing, which would have
# had somebody looking for a dropped connection instead of a big photo.
if [ "$(wc -c < "$WORK/rest")" -gt $(( MAX_MB * 1048576 )) ]; then
  # ⚠️ Drained before the answer, and bounded. Refusing the moment the
  # ceiling was reached left the sender mid-write on a closed channel:
  # a phone with nine megabytes still to send sat on "running" with no
  # timeout to save it, and the answer -- the one line that says WHY --
  # never reached it. The rest is read into nothing, up to four times
  # the ceiling more, so an honest overshoot finishes and hears the
  # reason, while a hostile sender still costs reading and not storage,
  # and still not whatever they felt like sending.
  head -c $(( MAX_MB * 1048576 * 4 )) > /dev/null
  fail "too_large" "The delivery is over the ${MAX_MB} MB limit."
fi
{ printf '%s\n' "$FIRST"; cat "$WORK/rest"; } > "$WORK/stream"

# ⚠️ ONE connection carries the WHOLE post, however many pictures are in
# it: name, base64, a line holding a dot, then the next name. It used to
# be one file per connection, which is simpler and was wrong -- a server
# worth running drops new SSH connections that arrive in a rush, and this
# one allows about four a minute. A post with three photographs sat right
# on that line and a post with nine had no chance: the shortcut reported
# "could not connect to the SSH server" and the pictures that never
# arrived were missed by nobody, because each connection answered for
# itself alone.
#
# Split in one pass by awk rather than by a shell loop. Correctness is the
# same and the speed is not: a single photograph is fourteen thousand
# lines of base64, and `while read` over that costs seconds per picture.
awk -v dir="$WORK" '
  BEGIN { want = 1; n = 0 }
  { sub(/\r$/, "") }
  # ⚠️ A blank line is NOT skipped where a name is due. Skipping it read
  # an empty name as no name at all and took the base64 underneath for
  # one -- so a delivery with nothing on its first line was answered
  # "not valid base64" about a line that was never meant to be a name.
  # An empty name is an error and says so; a client with a stray blank
  # line is a client to fix, not to guess at.
  want { n++; f = sprintf("%s/body-%03d", dir, n); print $0 > (dir "/names"); printf "" > f; want = 0; next }
  $0 == "." { close(f); want = 1; next }
  { print > f }
  END { if (!want) print "1" > (dir "/unfinished") }
' "$WORK/stream"

[ -s "$WORK/names" ] || fail "empty_input" "Nothing arrived that looks like a file."
# ⚠️ A closing '.' line is what says a transfer FINISHED -- nothing else
# can. base64 -d returns 0 on a stream cut short, and a cut landing on a
# four-character boundary is valid base64 by definition: a post cut in
# half produced a real draft with one paragraph of three and its sender
# was told it worked. A dot is not in the base64 alphabet.
[ ! -s "$WORK/unfinished" ] \
  || fail "truncated" "The delivery ended early: the closing '.' line is missing."

# ⚠️ EVERY name before ANY file. A delivery that is refused has to leave
# incoming/ as it found it, and a batch refused on its fifth name used to
# leave the first four lying there. Nothing is written until every name in
# the delivery has been read and allowed.
while IFS= read -r NAME; do
  check_name "$NAME"
done < "$WORK/names"

INDEX=0
while IFS= read -r NAME; do
  INDEX=$((INDEX + 1))
  BODY=$(printf '%s/body-%03d' "$WORK" "$INDEX")

  # ⚠️ The carriage returns go first. Base64 wrapped at 76 characters with
  # CRLF is what RFC 2045 asks for and what an iOS shortcut produces -- but
  # GNU base64 -d treats a \r as a character outside the alphabet and
  # refuses the whole stream. It decoded the first line, met the first \r
  # and stopped: 57 bytes of a 48 kB screenshot, reported as "not valid
  # base64", which sent everybody looking at the sender instead of here.
  tr -d '\r' < "$BODY" | base64 -d > "$WORK/file" 2>/dev/null \
    || fail "bad_base64" "$NAME is not valid base64."

  # ⚠️ The check above asks whether anything ARRIVED; this one asks whether
  # anything is IN it. A sender that framed the transfer correctly but put
  # nothing between the name and the closing dot got a nought-byte file in
  # incoming/ and the word ok -- which is how a shortcut wired to encode
  # the wrong thing looked like it was working.
  [ -s "$WORK/file" ] \
    || fail "empty_file" "$NAME arrived with its name and its closing dot and nothing between them."

  # ⚠️ Only a plain file may be replaced. `mv` onto a DIRECTORY moves the
  # file INSIDE it, and onto a symlink to one it writes through, outside
  # incoming/ altogether -- `ln -s ~/Pictures incoming/fotky` is an
  # arrangement this engine's own comments call ordinary, and a sender who
  # named `fotky` had their bytes land there, answered ok.
  if [ -d "$INSTALL/incoming/$NAME" ] || [ -L "$INSTALL/incoming/$NAME" ]; then
    fail "name_taken" "incoming/$NAME is not a plain file; nothing was replaced."
  fi

  # Into place under its own name, written beside it first so a half-copy
  # is never visible under the name the post will look for.
  cp "$WORK/file" "$INSTALL/incoming/.incoming-$$" 2>/dev/null \
    || fail "write_failed" "Could not write into $INSTALL/incoming/."
  chmod 644 "$INSTALL/incoming/.incoming-$$" 2>/dev/null
  mv -f "$INSTALL/incoming/.incoming-$$" "$INSTALL/incoming/$NAME" 2>/dev/null \
    || fail "write_failed" "Could not write into $INSTALL/incoming/."

  case "$NAME" in
    *.md|*.MD)
      cd "$INSTALL" || unavailable "no_cd" "Cannot enter $INSTALL."
      # The markdown is the last thing the app sends, so its arrival is the
      # signal that the post is whole. --untrusted: it came off a network,
      # so a picture may be named only by a bare filename -- the engine
      # refuses a path, in the method that resolves it.
      ./blog.sh add "$NAME" --json --untrusted 2>/dev/null
      ;;
    *)
      # A picture, stored and waiting for the text that names it.
      printf '{"ok":true,"stored":"%s"}\n' "$(json_escape "$NAME")"
      ;;
  esac
done < "$WORK/names"
