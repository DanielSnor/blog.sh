#!/usr/bin/env bash
# Machine-translates a post into another language the site publishes,
# with Claude Code in headless mode (`claude -p`, no tools), and leaves
# the result as a file for `./blog.sh add` to read -- or adds it itself
# with --publish, which on a published post rebuilds and deploys.
#
# The file carries edits:, base: and lang:, so it is the same save
# `translate --json` + `add` makes: a post changed in the meantime is
# refused (`changed`) instead of overwritten.
#
# Usage:
#   ./scripts/auto-translate.sh                    # the newest published post
#   ./scripts/auto-translate.sh <slug>             # that post
#   ./scripts/auto-translate.sh <slug> --lang de   # another language (default: en)
#   ./scripts/auto-translate.sh <slug> --publish   # also add it
#   ./scripts/auto-translate.sh <slug> --force     # translate a written translation again
set -euo pipefail
cd "$(dirname "$0")/.."

lang=en
slug=
publish=0
force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) lang="$2"; shift 2 ;;
    --lang=*) lang="${1#--lang=}"; shift ;;
    --publish) publish=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) slug="$1"; shift ;;
  esac
done

for tool in jq claude; do
  command -v "$tool" >/dev/null || { echo "Missing $tool." >&2; exit 1; }
done

if [ -z "$slug" ]; then
  slug=$(jq -r 'select(.state=="published") | [.date, .slug] | @tsv' content.nosync/posts/*/*.json \
    | sort -r | head -1 | cut -f2)
  [ -n "$slug" ] || { echo "No published post found." >&2; exit 1; }
fi

json=$(./blog.sh translate "$slug" --lang "$lang" --json) || { echo "$json" >&2; exit 1; }
if [ "$(jq -r '.ok' <<<"$json")" != true ]; then
  echo "$json" >&2; exit 1
fi
if [ "$(jq -r '.post.editable' <<<"$json")" != true ]; then
  echo "$slug cannot be translated from a file: $(jq -r '.post.problem' <<<"$json")" >&2; exit 1
fi
if [ "$(jq -r '.post.written' <<<"$json")" = true ] && [ "$force" = 0 ]; then
  echo "$slug already has a translation in '$lang' (--force to replace it)."; exit 0
fi
base=$(jq -r '.post.base' <<<"$json")
original=$(jq -r '.post.original' <<<"$json")

echo "Translating $slug into '$lang'..." >&2
prompt="Translate this blog post into the language with the code '$lang'.

Output ONLY the translated document, with no code fence and no comment before or after it.
- Keep the header between the --- lines: translate the title, leave slug: empty.
- Keep the Markdown exactly: headings, lists, emphasis, links, images, and lines such as //--more--//.
- Translate link texts but never change a URL.
- Keep the author's informal, self-ironic voice; translate idioms by meaning, not word for word.
- Fix obvious typos of the original silently.

$original"
translated=$(claude -p --tools "" <<<"$prompt")

# A model that wrapped the document in a fence anyway: drop the fence.
translated=$(sed -e '1{/^```/d}' -e '${/^```/d}' <<<"$translated")
if [ "$(head -1 <<<"$translated")" != --- ]; then
  echo "The translation does not start with its header; nothing was saved:" >&2
  echo "$translated" >&2
  exit 1
fi

mkdir -p tmp
out="tmp/$slug.$lang.md"
# The keys that make the file a translation go before the header's closing ---.
awk -v slug="$slug" -v base="$base" -v lang="$lang" '
  NR > 1 && !done && /^---$/ {
    print "edits: " slug; print "base: " base; print "lang: " lang; done = 1
  }
  { print }
' <<<"$translated" >"$out"

if [ "$publish" = 1 ]; then
  ./blog.sh add "$out"
else
  echo "Saved: $out"
  echo "Read it, then: ./blog.sh add $out"
fi
