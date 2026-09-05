#!/usr/bin/env bash
# Takes a whole post from standard input and puts its files in incoming/.
#
#   { printf '%s\n' photo.jpg; base64 < photo.jpg; echo .;
#     printf '%s\n' post.md;   base64 < post.md;   echo .; } | ./scripts/receive.sh
#
# For each file its name on a line, then its base64, then a line with a
# dot -- which is what says that file finished rather than stopped. One
# connection carries the post however many pictures are in it. The
# markdown goes last, and the markdown arriving is what makes the post,
# because there is no other signal to give and none is needed:
# everything before it is already staged under the names its text uses.
#
# ⚠️ An earlier version took a ZIP and unpacked it here. Three audits
# found nine, twelve and ten blockers in successive rewrites, nearly all
# of them in the archive handling. There is no archive now: what arrives
# from a network is a filename and a stream of bytes. The client had the
# files separately all along, so this asks it to do less, not more.
set -uo pipefail

# CDPATH makes cd PRINT the directory it went to, and a forced command
# written as a relative path would put that line where the answer goes.
# The zero is the rule the whole script follows and unavailable() below
# explains: this line has just printed an answer, so it leaves the way
# every other answer leaves.
CDPATH=
cd "$(dirname "$0")/.." >/dev/null || { printf '{"ok":false,"error":"no_cd","message":"Cannot reach the installation directory."}\n'; exit 0; }
INSTALL="${1:-$PWD}"
MAX_MB="${BLOGSH_MAX_MB:-24}"
# How long the body may take to arrive, in seconds. The first line has
# thirty; the rest had none, and ten bytes bought a process held open
# for as long as the sender cared to hold it.
BODY_SECONDS="${BLOGSH_BODY_SECONDS:-600}"

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
  # Control characters FIRST, and asked BY THE BYTE in a locale that
  # cannot disagree. Every refusal below quotes the name, and a tab
  # quoted raw inside a JSON string is an answer that is not JSON --
  # which is how "a/b<TAB>c" came back unreadable. A macOS screenshot is
  # named "Screenshot ... 11.59.29 AM.png" with a NARROW NO-BREAK SPACE
  # in it, and both [![:print:]] and [[:cntrl:]] answer differently
  # depending on the locale a shell happens to run under: one and the
  # same delivery was taken by the server and refused on a Mac. A space
  # is a space, whatever width it is.
  if [ "$1" != "$(printf %s "$1" | LC_ALL=C tr -d '\000-\037\177')" ]; then
    fail "bad_name" "A name may not hold control characters."
  fi
  case "$1" in
    ''|.|..)      fail "bad_name" "A file in this delivery has no name." ;;
    */*|*\\*)     fail "bad_name" "A name may not contain a path: $1" ;;
    .*)           fail "bad_name" "A name may not begin with a dot: $1" ;;
    # A name that begins with a dash is a flag to the engine, which would
    # refuse it in prose on stderr and leave with 1 -- an answer nobody
    # gets to read.
    -*)           fail "bad_name" "A name may not begin with a dash: $1" ;;
  esac
  [ "${#1}" -le 255 ] || fail "bad_name" "A name is longer than a filesystem will take."
}

fail() {  # an answer, so: 0
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$(json_escape "$2")"
  exit 0
}

# The machine is not set up: no incoming/, no engine, no temporary
# directory, no way into the installation, a mistyped ceiling. A different
# KIND of trouble from a delivery that is wrong -- but the exit status is
# not where that difference can be kept.
#
# ⚠️ These five left with 1, which cost them the one thing they are for.
# They are what a person meets on the FIRST delivery to a new install, and
# a phone discards the output of a remote command that failed -- so each
# arrived as a bare status with its sentence gone, on the delivery where
# the sentence was the whole of the help. /write/ has all five translated
# into three languages and never got to show one. The kind of trouble is
# in the error code, which arrives; the status only said it to nobody.
unavailable() { fail "$1" "$2"; }

[ -d "$INSTALL/incoming" ] || unavailable "no_incoming" "No incoming/ directory in $INSTALL."
[ -x "$INSTALL/blog.sh" ] || unavailable "no_engine" "No executable blog.sh in $INSTALL."
# A ceiling that is not a number went into arithmetic as it was: "64M"
# made every delivery a "dropped connection", "abc" left with no answer
# at all. Checked once, here, where the operator's line is read.
case "$MAX_MB" in
  ''|*[!0-9]*) unavailable "bad_limit" "BLOGSH_MAX_MB is not a whole number of megabytes: $MAX_MB" ;;
esac
case "$BODY_SECONDS" in
  ''|*[!0-9]*|0) unavailable "bad_limit" "BLOGSH_BODY_SECONDS is not a whole number of seconds: $BODY_SECONDS" ;;
esac

# With a deadline: a caller that opens the connection and says nothing
# held a process for as long as the connection lasted (measured at sixty
# seconds). The name comes first and is short, so half a minute is
# generous; the bytes after it may take as long as a phone on a train.
# -n 1024: without a bound, `read` consumes until a newline, so bytes put
# BEFORE it evaded the ceiling -- 256 MB of them took 266 MB of memory
# with BLOGSH_MAX_MB=24 in force.
WORK=$(mktemp -d) || unavailable "no_tmp" "Cannot create a temporary directory."
# A delivery carries somebody's photographs; they have no business staying
# in /tmp after a failure -- nor in incoming/, under the staging name.
# ⚠️ The trap goes on HERE, the line after the directory exists, not once
# the first byte has been read. Installed forty lines further down it sat
# past the refusal for an empty delivery, so a connection that opened and
# sent nothing was answered and left its directory behind -- and a
# receiver on the internet is dialled by whatever is scanning that day.
# TMP is emptied first: the trap reads it, under set -u.
TMP=
cleanup() {
  rm -rf "$WORK"
  [ -n "$TMP" ] && rm -f "$TMP"
}
trap cleanup EXIT
# Read with a deadline. Neither dd nor head has one of its own, so the
# reader runs in the background -- reading the same stdin, writing the
# file -- while this shell watches the clock; a sender that has stalled
# for longer than any phone on a train needs is dropped, and told so.
# Not a watchdog process that sleeps and kills: one of those outlived
# the delivery holding the answer's pipe open, and a sleeping killer that
# wakes ten minutes later may find its PID reused.
# ⚠️ Standard input handed over by number: a background command gets
# /dev/null for its stdin in a shell without job control, and head read
# nothing at all until the pipe was named explicitly.
exec 3<&0
bounded() {  # seconds, file, reader...
  secs=$1; out=$2; shift 2
  "$@" > "$out" <&3 &
  rp=$!
  ticks=0
  while kill -0 "$rp" 2>/dev/null; do
    if [ "$ticks" -ge $(( secs * 5 )) ]; then
      kill "$rp" 2>/dev/null; wait "$rp" 2>/dev/null
      return 2
    fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$rp" 2>/dev/null
  return 0
}

# The first BYTE, with its thirty seconds: a caller that opens the
# connection and says nothing held a process for as long as the
# connection lasted. Read by dd, one byte, into a file -- not by `read`
# into a variable, which drops a NUL byte on the floor: a name carrying
# one was checked and stored as the part before it, and the check for
# NUL bytes below never saw one. And not by head, which reads ahead of
# what it keeps and would have swallowed the start of the body.
bounded 30 "$WORK/first" dd bs=1 count=1 2>/dev/null
[ -s "$WORK/first" ] \
  || fail "empty_input" "Nothing arrived on standard input, or nothing was sent for thirty seconds."

# The rest, bounded and timed: head stops READING at the ceiling, so a
# hostile sender costs that and not whatever they felt like sending --
# and not for longer than BODY_SECONDS either, however slowly it comes.
bounded "$BODY_SECONDS" "$WORK/rest" head -c $(( (MAX_MB * 1048576) + 1025 )) \
  || fail "timeout" "The delivery did not finish within ${BODY_SECONDS} seconds and was dropped."
# ⚠️ Measured on the BYTES AFTER the first line, not on the two glued
# together. Weighing the whole thing let a first line of any length eat
# into the allowance, and worse: head cuts the stream at the ceiling, so
# an over-sized delivery lost its closing dot and was refused as
# `truncated` -- a true sentence about the wrong thing, which would have
# had somebody looking for a dropped connection instead of a big photo.
# The first LINE is outside the ceiling, up to the 1024 bytes a name may
# take; a line longer than that is refused below as a name.
cat "$WORK/first" "$WORK/rest" > "$WORK/stream"
FIRST_LINE=$(head -c 1025 "$WORK/stream" | LC_ALL=C tr -d '\000' | head -1 | wc -c)
if [ $(( $(wc -c < "$WORK/stream") - FIRST_LINE )) -gt $(( MAX_MB * 1048576 )) ]; then
  # ⚠️ Drained before the answer, and bounded. Refusing the moment the
  # ceiling was reached left the sender mid-write on a closed channel:
  # a phone with nine megabytes still to send sat on "running" with no
  # timeout to save it, and the answer -- the one line that says WHY --
  # never reached it. The rest is read into nothing, up to four times
  # the ceiling more, so an honest overshoot finishes and hears the
  # reason, while a hostile sender still costs reading and not storage,
  # and still not whatever they felt like sending.
  # A drain that has already decided to refuse waits far less than a
  # delivery: two minutes of silence and the sender has gone.
  bounded 120 /dev/null head -c $(( MAX_MB * 1048576 * 4 ))
  fail "too_large" "The delivery is over the ${MAX_MB} MB limit."
fi
# A NUL byte ends a shell string and awk's patience alike, so a name
# carrying one was checked and stored as the part before it -- a file
# under a name nobody sent. Nothing in this protocol carries a NUL: names
# are filenames and bodies are base64. Asked of the bytes, once, before
# anything reads them as text.
if [ "$(LC_ALL=C tr -d '\000' < "$WORK/stream" | wc -c)" -ne "$(wc -c < "$WORK/stream")" ]; then
  fail "bad_name" "A delivery may not hold a NUL byte."
fi

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
# A name is recorded when its block CLOSES, so an open block at the end
# is either a delivery cut short -- it had a name, or bytes -- or one
# stray blank line after a complete delivery, which is the most ordinary
# thing a text stream can end with and used to throw the whole post away
# as "truncated". A blank line where a name is due is still not skipped
# INSIDE a delivery: skipping it read an empty name as no name at all and
# took the base64 underneath for one.
awk -v dir="$WORK" '
  BEGIN { want = 1; n = 0; cur = ""; got = 0 }
  { sub(/\r$/, "") }
  want { n++; f = sprintf("%s/body-%03d", dir, n); cur = $0; got = 0; printf "" > f; want = 0; next }
  $0 == "." { close(f); print cur > (dir "/names"); want = 1; next }
  { print > f; got = 1 }
  END { if (!want && (cur != "" && cur != "." || got)) print "1" > (dir "/unfinished") }
' "$WORK/stream"

# ⚠️ A closing '.' line is what says a transfer FINISHED -- nothing else
# can. base64 -d returns 0 on a stream cut short, and a cut landing on a
# four-character boundary is valid base64 by definition: a post cut in
# half produced a real draft with one paragraph of three and its sender
# was told it worked. A dot is not in the base64 alphabet. Asked before
# "nothing arrived": a single block that never closed has no name on
# record, and it is a delivery cut short, not an empty one.
[ ! -s "$WORK/unfinished" ] \
  || fail "truncated" "The delivery ended early: the closing '.' line is missing."
[ -s "$WORK/names" ] || fail "empty_input" "Nothing arrived that looks like a file."

# ⚠️ EVERY name before ANY file. A delivery that is refused has to leave
# incoming/ as it found it, and a batch refused on its fifth name used to
# leave the first four lying there. Nothing is written until every name in
# the delivery has been read and allowed.
while IFS= read -r NAME; do
  check_name "$NAME"
done < "$WORK/names"
# Two files under one name in one delivery: the second replaced the
# first and both were answered ok. iOS hands out IMG_0001 twice a day.
DUP=$(sort "$WORK/names" | uniq -d | head -1)
[ -z "$DUP" ] || fail "bad_name" "Two files in this delivery are called $DUP."

# ⚠️ And every BODY before any file, for the same reason. A delivery that
# failed on its third picture used to leave the first two staged and say
# nothing of the fourth and fifth.
INDEX=0
while IFS= read -r NAME; do
  INDEX=$((INDEX + 1))
  BODY=$(printf '%s/body-%03d' "$WORK" "$INDEX")
  FILE=$(printf '%s/file-%03d' "$WORK" "$INDEX")
  # ⚠️ Whitespace out first. Base64 wrapped at 76 characters with CRLF is
  # what RFC 2045 asks for and what an iOS shortcut produces, and GNU
  # base64 -d treats a \r as a character outside the alphabet and refuses
  # the whole stream -- 57 bytes of a 48 kB screenshot, reported as "not
  # valid base64". Then the count: base64 comes in fours, and a body that
  # is not a whole number of them is a body cut short. BSD base64 decoded
  # such a thing to fewer bytes and returned 0 -- a post made from the
  # wrong bytes with a slug to show for it -- while GNU refused it; asked
  # here, both answer the same.
  LC_ALL=C tr -d '\r\n\t ' < "$BODY" > "$WORK/b64"
  [ $(( $(wc -c < "$WORK/b64") % 4 )) -eq 0 ] || fail "bad_base64" "$NAME is not valid base64."
  base64 -d < "$WORK/b64" > "$FILE" 2>/dev/null \
    || fail "bad_base64" "$NAME is not valid base64."
  # ⚠️ The check above asks whether anything ARRIVED; this one asks whether
  # anything is IN it. A sender that framed the transfer correctly but put
  # nothing between the name and the closing dot got a nought-byte file in
  # incoming/ and the word ok -- which is how a shortcut wired to encode
  # the wrong thing looked like it was working.
  [ -s "$FILE" ] \
    || fail "empty_file" "$NAME arrived with its name and its closing dot and nothing between them."
done < "$WORK/names"

# A delivery of exactly one file called publish.txt is not a post: it is a
# request to publish one that is already here, and its body is the slug.
# The page at /write/ sends it after a draft has gone out and been looked
# at -- which is the one thing that could not be done from a phone at all,
# because publishing needs a terminal and a phone has none.
#
# Nothing is written to incoming/ for it: the slug is a word, not a file,
# and staging it would leave litter nobody consumes.
#
# ⚠️ That word becomes an argument to a command, so it is checked as
# hard as a filename is. A leading dash is a flag to the engine, and the
# rest of the alphabet here is the one slugs are made of -- anything else
# is refused rather than passed on and explained by whatever it hits.
if [ "$(wc -l < "$WORK/names")" -eq 1 ] && [ "$(head -1 "$WORK/names")" = "publish.txt" ]; then
  # Carriage returns out (a phone writes them), trailing newlines dropped
  # by the substitution itself -- but a newline in the MIDDLE stays, and
  # is refused. Deleting it would have glued two lines into one word and
  # published whatever that spelled.
  SLUG=$(LC_ALL=C tr -d '\r' < "$WORK/file-001")
  case "$SLUG" in
    '' | -* | *"
"*) fail "bad_slug" "publish.txt has to hold the slug of a post, and nothing else." ;;
  esac
  if [ "${#SLUG}" -gt 200 ] || [ "$SLUG" != "$(printf %s "$SLUG" | LC_ALL=C tr -cd 'a-z0-9-')" ]; then
    fail "bad_slug" "publish.txt has to hold the slug of a post, and nothing else."
  fi
  cd "$INSTALL" || unavailable "no_cd" "Cannot enter $INSTALL."
  # The same capture as the markdown route below, and for the same reason:
  # an engine that answers in prose gets answered for.
  OUT=$(./blog.sh publish "$SLUG" --yes --json 2>"$WORK/engine-err")
  case "$OUT" in
    \{*) printf '%s\n' "$OUT" ;;
    *)
      REASON=$(printf '%s\n%s' "$OUT" "$(cat "$WORK/engine-err" 2>/dev/null)" | LC_ALL=C tr -d '\000-\011\013-\037\177' | tail -c 600)
      printf '{"ok":false,"error":"engine_failed","message":"%s"}\n' "$(json_escape "$(printf '%s' "$REASON" | tr '\n' ' ')")"
      ;;
  esac
  exit 0
fi

INDEX=0
while IFS= read -r NAME; do
  INDEX=$((INDEX + 1))
  FILE=$(printf '%s/file-%03d' "$WORK" "$INDEX")

  # ⚠️ Only a plain file may be replaced. `mv` onto a DIRECTORY moves the
  # file INSIDE it, and onto a symlink to one it writes through, outside
  # incoming/ altogether -- `ln -s ~/Pictures incoming/fotky` is an
  # arrangement this engine's own comments call ordinary, and a sender who
  # named `fotky` had their bytes land there, answered ok.
  if [ -d "$INSTALL/incoming/$NAME" ] || [ -L "$INSTALL/incoming/$NAME" ]; then
    fail "name_taken" "incoming/$NAME is not a plain file; nothing was replaced."
  fi

  # Into place under its own name, written beside it first so a half-copy
  # is never visible under the name the post will look for. Staged under
  # a name nobody can guess and nobody can plant: mktemp creates it
  # exclusively. The old .incoming-<pid> followed a symlink left under
  # that name, and a delivery landed outside incoming/.
  TMP=$(mktemp "$INSTALL/incoming/.incoming-XXXXXXXX" 2>/dev/null) \
    || fail "write_failed" "Could not write into $INSTALL/incoming/."
  cp "$FILE" "$TMP" 2>/dev/null \
    || fail "write_failed" "Could not write into $INSTALL/incoming/."
  chmod 644 "$TMP" 2>/dev/null
  # Asked again on the very edge of the rename: the check above and the
  # move below are two moments, and a name can be taken between them.
  if [ -d "$INSTALL/incoming/$NAME" ] || [ -L "$INSTALL/incoming/$NAME" ]; then
    fail "name_taken" "incoming/$NAME is not a plain file; nothing was replaced."
  fi
  mv -f "$TMP" "$INSTALL/incoming/$NAME" 2>/dev/null \
    || fail "write_failed" "Could not write into $INSTALL/incoming/."
  TMP=

  case "$NAME" in
    *.[Mm][Dd])
      cd "$INSTALL" || unavailable "no_cd" "Cannot enter $INSTALL."
      # The markdown is the last thing the app sends, so its arrival is the
      # signal that the post is whole. --untrusted: it came off a network,
      # so a picture may be named only by a bare filename -- the engine
      # refuses a path, in the method that resolves it.
      #
      # ⚠️ Captured, not relayed. The engine's answer is relayed when it
      # is one; when it is not -- a missing env.sh, no ruby, a
      # configuration that will not parse, a backtrace -- the prose it
      # printed instead went out as the answer, or nothing did, and its
      # exit status became this script's: a 1 that cost the phone every
      # picture's receipt before it. An answer is an object, always.
      OUT=$(./blog.sh add "$NAME" --json --untrusted 2>"$WORK/engine-err")
      case "$OUT" in
        \{*) printf '%s\n' "$OUT" ;;
        *)
          REASON=$(printf '%s\n%s' "$OUT" "$(cat "$WORK/engine-err" 2>/dev/null)" | LC_ALL=C tr -d '\000-\011\013-\037\177' | tail -c 600)
          printf '{"ok":false,"error":"engine_failed","message":"%s"}\n' "$(json_escape "$(printf '%s' "$REASON" | tr '\n' ' ')")"
          ;;
      esac
      ;;
    *)
      # A picture, stored and waiting for the text that names it.
      printf '{"ok":true,"stored":"%s"}\n' "$(json_escape "$NAME")"
      ;;
  esac
done < "$WORK/names"
# Every answer has been given; the status says so whatever the last
# command said.
exit 0
