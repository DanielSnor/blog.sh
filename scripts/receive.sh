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
fail() {  # an answer, so: 0
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$2"
  exit 0
}

# No answer to give: the machine is not set up, the engine is missing.
unavailable() {
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$2"
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
IFS= read -r -t 30 -n 1024 NAME \
  || fail "empty_input" "Nothing arrived on standard input, or nothing was sent for thirty seconds."
NAME=${NAME%$'\r'}   # a shortcut may end its lines the Windows way

# ⚠️ A BARE filename and nothing else. This is the whole of what an
# untrusted sender chooses, so it is the whole of what has to be checked:
# no directory, no traversal, no leading dot (which hides a file from the
# author and from a glob), nothing empty. `case` rather than a regular
# expression because a shell's [[ ]] is not everywhere.
case "$NAME" in
  ''|.|..)          fail "bad_name" "The first line must be a filename." ;;
  */*|*\\*)         fail "bad_name" "A name may not contain a path: $NAME" ;;
  .*)               fail "bad_name" "A name may not begin with a dot: $NAME" ;;
  *[![:print:]]*)   fail "bad_name" "A name may not hold control characters." ;;
esac

WORK=$(mktemp -d) || unavailable "no_tmp" "Cannot create a temporary directory."
# A bundle carries somebody's photographs; they have no business staying
# in /tmp after a failure.
trap 'rm -rf "$WORK"' EXIT

# Bounded before it lands: head stops READING at the ceiling, so a
# hostile sender costs that and not whatever they felt like sending.
head -c $(( (MAX_MB * 1048576) + 1 )) > "$WORK/encoded"
[ -s "$WORK/encoded" ] || fail "empty_input" "The file is empty."
[ "$(wc -c < "$WORK/encoded")" -le $(( MAX_MB * 1048576 )) ] \
  || fail "too_large" "The file is over the ${MAX_MB} MB limit."

# ⚠️ A closing '.' line is what says the transfer FINISHED -- nothing else
# can. base64 -d returns 0 on a stream cut short, and a cut landing on a
# four-character boundary is valid base64 by definition: a post cut in
# half produced a real draft with one paragraph of three and its sender
# was told it worked. A dot is not in the base64 alphabet.
LAST=$(tail -n 1 "$WORK/encoded")
[ "${LAST%$'\r'}" = "." ] \
  || fail "truncated" "The transfer ended early: the closing '.' line is missing."
sed '$d' "$WORK/encoded" > "$WORK/body"

base64 -d < "$WORK/body" > "$WORK/file" 2>/dev/null \
  || fail "bad_base64" "The file is not valid base64."

# ⚠️ The check above this one asks whether anything ARRIVED; this one asks
# whether anything is IN it. A sender that framed the transfer correctly
# but put nothing between the name and the closing dot got a nought-byte
# file in incoming/ and the word ok -- which is how a shortcut wired to
# encode the wrong thing looked like it was working. An empty photograph
# is not a photograph, and an empty markdown makes no post.
[ -s "$WORK/file" ] \
  || fail "empty_file" "The name and the closing dot arrived, but nothing between them."

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
    # The markdown is the last thing sent, so its arrival is the signal.
    # --untrusted: it came off a network, so a picture may be named only
    # by a bare filename -- the engine refuses a path, in the method that
    # resolves it.
    ./blog.sh add "$NAME" --json --untrusted 2>/dev/null
    ;;
  *)
    # A picture, stored and waiting for the text that names it.
    printf '{"ok":true,"stored":"%s"}\n' "$NAME"
    ;;
esac
