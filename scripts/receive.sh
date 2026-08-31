#!/usr/bin/env bash
# Carries a bundle from standard input to the engine. Nothing else.
#
# Usage:
#   base64 < post.zip | ./scripts/receive.sh          # this installation
#   base64 < post.zip | ./scripts/receive.sh /other   # another one
#
# The bundle is a ZIP holding one .md file and the pictures its text
# refers to; the engine unpacks it, checks it and writes a draft. The
# answer is one JSON object, on success and on failure alike, because the
# caller is a program.
#
# ⚠️ This script used to do the unpacking and the checking itself, and it
# was two hundred and forty lines of them. Two adversarial audits found
# nine and then twelve blocking faults in it -- and not one was a mistake
# about security. They were all mistakes about the shell: a `mkdir -p`
# that adopts an existing name and follows a symlink through it, an awk
# whose field rebuild pads a record so two identical names compare
# differently, a `ulimit -f` that bounds each file rather than the total,
# a glob that cannot see a name beginning with a dot. Every one of them a
# line that does not do what it looks like it does.
#
# So the checking moved into lib/bundle.rb, where `File.lstat` means
# `File.lstat`, and where it sits under the same test suite as the rest of
# the engine. What is left here is the part a shell is actually good at:
# finding the installation and handing over a stream.
set -uo pipefail

cd "$(dirname "$0")/.." || { printf '{"ok":false,"error":"no_cd","message":"Cannot reach the installation directory."}\n'; exit 1; }
INSTALL="${1:-$PWD}"

fail() {  # code, message
  printf '{"ok":false,"error":"%s","message":"%s"}\n' "$1" "$2"
  exit 1
}

[ -x "$INSTALL/blog.sh" ] || fail "no_engine" "No executable blog.sh in $INSTALL."
# An older installation has `add` but not the bundle route, and would
# answer "unknown option" -- true, and no use to a phone. Named instead.
grep -q "def add_from_bundle" "$INSTALL/scripts/manage_post.rb" 2>/dev/null \
  || fail "engine_too_old" "This installation does not take a bundle yet."

cd "$INSTALL" || fail "no_cd" "Cannot enter $INSTALL."
# stdin goes straight through; the engine answers on stdout in the shape
# this script promises, so there is nothing here to translate. Its human
# narration goes to stderr and is dropped: a caller reading the answer
# should not have to pick it out of a log.
./blog.sh add --bundle --json 2>/dev/null
