# Design decisions

Why the engine is shaped the way it is -- the trade-offs behind what
[architecture.md](architecture.md) describes. Format: what was decided,
why, and what it costs.

## Content

**Typed JSON blocks, parsed once -- not markdown rendered at build
time.** Markdown is parsed exactly once, when the author saves; the
build only ever assembles already-structured blocks, and every importer
targets the same schema, so imported and hand-written posts are
indistinguishable downstream. *Cost:* editing needs the inverse
renderer (`markdown_writer.rb`), and content markdown can't express is
guarded by a loss check instead of just surviving a round-trip.

**Inline formatting as offsets into plain text, not nested HTML.** The
NPF-style shape Tumblr's API already uses -- imports keep their
formatting without HTML parsing, stored content contains no markup to
sanitize, and escaping stays entirely the renderer's job. *Cost:*
overlapping-span rendering is genuinely fiddly (see `apply_formatting`
and `render_markdown_range`).

**Media always lives next to its post; nothing is hotlinked.** Imported
posts survive their source platform dying (the Twitter/Tumblr archives
this engine was born from are full of dead CDN links). *Cost:* disk
space, and migrations must download everything up front.

## Publishing and comments

**Comments are Mastodon replies to an auto-toot.** No comment database,
no moderation queue, no GDPR surface, no spam plugin -- replies live
where people already are, and the visitor's browser reads the public
thread API directly. *Cost:* comments require a Mastodon presence, and
deleting the toot deletes the discussion (which `unpublish` does
deliberately, to never leave a toot pointing at a dead URL).

**Everything starts as a draft, and drafts live on the public site
behind a `SecureRandom` token with `noindex`.** The whole point is
previewing from a phone or sending the link to a reviewer before
publishing -- a localhost-only preview can't do either. *Cost:* the
draft text physically exists on the host; the token (and staying out of
every listing and index) is the fence.

**Deleting is moving to `trash/`; two posts can never share a URL.**
There's no database transaction log to lean on, so the engine refuses
the two silent data-loss paths: `delete` is reversible via `restore`,
and the build aborts on a year+slug collision instead of letting one
post overwrite the other.

## Build and deploy

**Static output, rebuilt incrementally -- only changed bytes are ever
written or uploaded.** `emit` compares before writing, the deploy
manifest diffs by hash (with a size+mtime fast path), and RSS avoids
embedding "now". A one-character edit deploys a handful of files, which
also keeps cloud-synced and content-hashed targets calm.

**Pagination is anchored to the oldest post.** Slicing from the newest
end -- the obvious way -- shifts every page boundary each time a post
is published, rewriting the whole archive on every deploy. Anchoring to
the oldest makes old pages immutable; the landing page absorbs new
posts and splits only when full. Same reason there's no "page X of Y"
label: the total would put a changing byte on every page.

**Deploys are paranoid by default.** A >20% swing in file count against
the last deploy aborts (a broken build must never be mirrored),
deletion is opt-in (`--prune`), manifests are per-backend so switching
targets can't inherit foreign state, and every manifest is disposable --
deleting one costs one full re-upload, never correctness.

**Six deploy backends behind one small contract.** The manifest logic
is target-independent; backends only move bytes. Self-diffing targets
(rsync, rclone, git) get a single batch call; dumb ones (sftp) execute
the manifest's precomputed lists; git is a forced single-commit
snapshot because site history already lives in the source repo.

## Dependencies and security

**Ruby stdlib only -- no gems, no Bundler; external *binaries* are
fine.** `git clone` + system Ruby is the entire installation, and
nothing can bit-rot in a dependency tree. Where stdlib can't reach
(rsync, git, rclone, sftp, `$EDITOR`), the engine shells out to system
binaries the user already understands. *Cost:* some things are
hand-rolled that a gem would provide -- multipart uploads, JPEG/MP4
header parsing, YAML-adjacent frontmatter.

**No third-party requests from the visitor's browser.** Widgets are
fetched server-side on cron into same-origin JSON: visitors' IPs leak
nowhere, GitHub's rate limit can't kill the sidebar, and a slow third
party can't slow the page. The one exception is deliberate: the
Mastodon comments thread, fetched client-side because it's the actual
live discussion. Fonts are self-hosted for the same reason.

**CSP without `unsafe-inline`, delivered as a meta tag.** The single
inline script (client i18n strings) is allowlisted by its SHA-256
content hash, so injected markup still can't execute. A meta tag
instead of an HTTP header because several supported hosts (Surfer,
Pages) can't set custom headers -- this way the policy travels with the
pages to any host.

**Everything from the Fediverse is escaped.** Display names, avatars
and URLs are attacker-controlled by definition (anyone can reply to a
toot); only Mastodon's own sanitized status HTML is inserted as HTML,
and that decision is documented where it happens.

## Configuration

**`config/site.yml` (identity, versioned) vs `env.sh` (secrets, mode
600, never in git).** Split by sensitivity, not by topic: the site
config is meant to sync across environments so local and production
render identically; tokens are meant to exist only where they're used.

**Colors are 7 keys per mode; everything else is derived.** Across
every palette this engine actually shipped, the other custom properties
never varied independently -- so they're computed in one function
instead of being twenty more config keys. *Cost:* a future palette
needing an independent value (a too-light accent, say) means promoting
it to a config key then, not configuring it today.

**i18n falls back per key, not per file.** A partial translation
degrades into English word by word instead of breaking pages -- which
is what makes shipping a community locale a low-stakes contribution.
The `/markdown/` cheat sheet localizes the same way: per-language
source files, English fallback.
