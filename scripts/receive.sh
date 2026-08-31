#!/usr/bin/env bash
# Takes ONE file from standard input and puts it in incoming/.
#
#   printf '%s\n' "photo.jpg" | cat - <(base64 < photo.jpg) | ./scripts/receive.sh
#
# The first line is the name; everything after it is that file's base64.
# A shortcut on a phone sends the pictures this way, one connection each,
# and the markdown last -- and the markdown arriving is what makes the
# post, because there is no other signal to give and none is needed.
# Everything before it is already staged under the names its text uses.
#
# ⚠️ There was a version of this that took a ZIP of the whole post and
# unpacked it here. Three adversarial audits found nine, twelve and ten
# blocking faults in successive rewrites of it, and nearly every one lived
# in the archive handling: entries that were symlinks, names that
# flattened onto each other, a bomb that wrote two gigabytes from three
# megabytes, an extraction that half-failed and was never checked. None of
# that exists here, because there is no archive. The whole of what arrives
# from a network is a filename and a stream of bytes.
#
# The client had the files separately all along -- it packed them at the
# last moment -- so this asks it to do less, not more.
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

# ⚠️ With a deadline. A caller that opens the connection and then says
# nothing -- a client that never closes its end, a network that dropped
# without telling anybody -- left `read` waiting for as long as the
# connection lasted, holding a process for nothing. Measured at sixty
# seconds against a writer that simply sat there. The name is the FIRST
# thing sent and it is short, so half a minute is generous; the bytes
# after it have a ceiling of their own and may take as long as a phone on
# a train needs.
IFS= read -r -t 30 NAME \
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

# ⚠️ Bounded BEFORE it lands, not weighed afterwards. The version that
# checked the size after writing let three megabytes of input put two
# gigabytes on the disk. head stops reading at the ceiling, so the cost of
# a hostile sender is the ceiling and not whatever they felt like sending.
head -c $(( (MAX_MB * 1048576) + 1 )) > "$WORK/encoded"
[ -s "$WORK/encoded" ] || fail "empty_input" "The file is empty."
[ "$(wc -c < "$WORK/encoded")" -le $(( MAX_MB * 1048576 )) ] \
  || fail "too_large" "The file is over the ${MAX_MB} MB limit."

base64 -d < "$WORK/encoded" > "$WORK/file" 2>/dev/null \
  || fail "bad_base64" "The file is not valid base64."

# Into place under its own name. Not `cp` onto a name that may already be
# a dangling symlink -- write to a fresh name and move it over, so nothing
# is ever followed.
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
