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

**A post's type is derived from its blocks; media claim it only
caption-deep.** The `/type/` listings need every post filed exactly
once, and asking the author to pick a type on every post would be one
more prompt that's usually inferable -- so the type is derived, with an
explicit `type:` in the frontmatter as the override for the post that
disagrees. The rules, measured against a 3281-post archive before
choosing: media (video > audio > image) win only while the post's text
stays under 500 characters -- past that it's an article and the media
are illustrations; a quote post is one that *opens* with a quote, so a
quote cited mid-text doesn't reclassify an essay; any chat block makes
a chat post, since a transcript is always a deliberate choice. The
rejected alternatives misfiled real posts: first-block-wins turns a
photo tweet into text (the text arrives first), a block-count majority
turns a greeting card with two caption sentences into text. *Cost:*
any heuristic misfiles some edge case -- that's what the explicit
override is for.

**The nav lists what a reader browses; the feed isn't that.** RSS left
the menu: subscribers find the feed through the autodiscovery `<link>`
every page carries (and the URL never changed), while a nav slot is
paid for by every visitor on every page. With quote and chat arriving,
seven items was the budget.

**The menu lists only types the site actually has.** Nav items, `/type/`
listings and their sitemap entries exist only for content types with at
least one published post -- a young site's menu grows with its content
instead of offering six links into empty listings, and a type the
engine gains later stays invisible on every site until its first such
post. A type emptied by unpublishing disappears again on the next
build; the deploy prunes its listing pages as orphans. *Cost:* an
external link to a type's listing dies if the type empties -- it
pointed at an empty page anyway.

**The bar is a filter, so the first item says All and the current one
shows.** Every item but the first narrows the listing to one content
type; the first clears the filter, which is what "All" names and what
"Home" did not -- in a row of filters it read as a destination that had
wandered in. The item matching the page carries `aria-current="page"`
and is filled with the accent colour, so a reader can see which listing
they are in without reading the heading. Only listings light up: a post
deliberately doesn't highlight its own type, since the menu filters
listings and a video post is not the video listing. The banner still
links home, as it always did. *Cost:* the label lives on every page, so
changing it rewrites the whole archive -- which is why the rename
happened before 1.0 rather than after, along with its locale key
(`nav.home` -> `nav.all`), which would otherwise have broken every
translation written in the meantime.

**Media always lives next to its post; nothing is hotlinked.** Imported
posts survive their source platform dying (the Twitter/Tumblr archives
this engine was born from are full of dead CDN links). *Cost:* disk
space, and migrations must download everything up front.

## Publishing and comments

**Comments are replies to an announcement post -- on exactly one
network.** No comment database, no moderation queue, no GDPR surface,
no spam plugin -- replies live where people already are (Mastodon or
Bluesky, both with public unauthenticated thread APIs the visitor's
browser reads directly). The two networks are deliberately exclusive:
configuring both would split every post's discussion into two
half-threads, so the build refuses it. *Cost:* comments require a
presence on the chosen network, and deleting the announcement deletes
the discussion (which `unpublish` does deliberately, to never leave an
announcement pointing at a dead URL).

**Everything starts as a draft, and drafts live on the public site
behind a `SecureRandom` token with `noindex`.** The whole point is
previewing from a phone or sending the link to a reviewer before
publishing -- a localhost-only preview can't do either. *Cost:* the
draft text physically exists on the host; the token (and staying out of
every listing and index) is the fence.

**The publish date comes from publishing, not from a field.** Publishing
means "now", scheduling asks for a date -- so the frontmatter template
offers no `date:` line, which would be a third path to the same decision
and the only one whose effect isn't visible where you make it. The
parser still honors a hand-typed `date:` (that's how imports keep their
original dates). *Cost:* backdating is no longer discoverable from the
editor; it's a documented escape hatch rather than a suggested field.

**The site declares its timezone; `TZ` and the system zoneinfo do the
work.** A server clock is usually UTC, which silently made "schedule
10:30" mean 12:30 locally and could date a post written after midnight to
the previous day. `site.timezone` belongs to the site the same way
`site.lang` does, so it lives in `config/site.yml` rather than in the
unversioned `env.sh`, and every entry point applies it at startup by
setting `TZ` -- Ruby then reads the OS zone database, DST included, with
no gem and no timezone table of ours. An unknown zone name aborts,
because Ruby's own fallback for one is a silent UTC.

Dates a reader sees are rendered in that zone too, via `post_display_time`
and a `getlocal` in each sidebar fetcher -- otherwise a post imported as
UTC, or a toot posted late in the evening, shows the previous day.
`post_time` itself deliberately stays on the stored offset, because
`post_path` derives the year from it: shifting that would move a post
published near midnight on December 31 into another year, changing a live
URL. Feeds and the sitemap stay on it for the same reason in reverse --
they carry absolute instants for machines, where the offset is noise.
*Cost:* stored dates aren't rewritten, so a site adopting this re-renders
only the posts whose local day actually differs (73 of sean.cz's 3281,
none of them changing year).

**Importing gets its own wizard, and always previews before it writes.**
`./import.sh` is separate from `./blog.sh` because the two have opposite
shapes: authoring is a daily loop over one post, importing is a rare bulk
operation that drops thousands of files into `content.nosync/` at once. The
authoring menu stays about authoring, and the irreversible thing needs its
own door opened deliberately. Every import runs the adapter in dry-run first
and reports what *would* be written -- counts, the first slugs, and why
items were skipped -- because discovering afterwards that 2000 posts got the
wrong slugs has no cheap fix. Confirming means typing the post count back,
not pressing a key: deleting a single post already makes you type its slug,
so a bulk write had the bigger consequence behind the weaker gate. *Cost:* two entry points to learn, and one
shared `lib/site_header.rb` so their identity blocks can't drift.

**A long import narrates itself.** Every phase that runs for more than a few
seconds prints progress: what is about to be read and how big it is, how
many items were found and filtered, then a `12/847` counter per post.
Silence during a multi-hour media download is indistinguishable from a hung
process, which is the worst thing to hand someone waiting on a tool that
writes into their archive. The counting lives in `lib/import/`, behind
callbacks; the escape codes live in the wizard. *Cost:* importers print more
than a script strictly needs, and a piped run throttles to one line per
hundred items so logs stay readable.

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

**Attributes live in the frontmatter, actions live in a dialog.** A
post's type and tags are edited where the text is -- prefilled in the
header of `edit`, so the current state is visible before it's changed.
Operations with consequences (publish, unpublish, rename, delete, the
announcement) each get a guarded prompt in the `props` dialog instead.
The wizard menu then lists activities, not operations: five entries,
with everything post-shaped reached through the post. The CLI commands
all remain -- scripts don't navigate menus.

The pin is the deliberate exception, and it moved on first contact with
reality: it started as an attribute, and the very first person to unpin
a post read "pinned: yes" in the dialog and found no way to act on it --
the dialog sent them into an editor session to flip one boolean. Type
and tags are *values you write*; the pin is a *switch*, its consequence
lives on the front page, and a switch behind an editor round-trip is
exactly the friction the dialog exists to remove. So `[c]` toggles it in
place, and the frontmatter keeps accepting `pinned:` as before -- two
doors, one state.

**A slug rename is an action with a permanent redirect, not an
attribute.** A published slug is an address other people hold; editing it
like a tag would break every copy of that address silently. So renaming
is a guarded action that records the old address in the post
(`former_slugs`) and the build keeps a one-page redirect standing there
-- for as long as the post itself is published. The address book lives in
the post's own JSON rather than a separate registry, so it moves,
backs up and restores with the post and can never orphan.

**Deploys are paranoid by default.** A large swing in file count or total
bytes aborts (a broken build must never be mirrored), deletion is opt-in
(`--prune`), manifests are per-backend so switching targets can't inherit
foreign state, and every manifest is disposable -- deleting one costs one
full re-upload, never correctness.

**The guards measure the build against the build.** They used to compare
it against the manifest, which is the state of the *target* -- so any
failed upload knocked their reference out of true, and the patch for that
was a marker that stood them down until a clean run came along. When the
failure was permanent, that was never. The reference is now the shape of
the last build the guards themselves accepted, written before the first
byte moves, so there is nothing left to switch off. The manifest is still
allowed to serve as a *floor* for the drop direction, because a partial
manifest can only ever understate the site: as a floor it can hide a
drop, never invent one. It is never a reference for growth, which is
precisely the reading that caused the original defect. Percentages carry
absolute floors as well, asymmetric on purpose -- a missed increase costs
transferred bytes that the next `--prune` reclaims, a missed drop deletes
live pages.

**One file-size limit for every backend, and no key to loosen it.** The
hosts differ wildly -- GitHub Pages refuses a single file over 100 MiB, a
plain rsync target refuses nothing -- but a per-backend limit would mean a
post that saves today becomes undeployable the day the site moves. The
strictest supported target therefore sets the rule for all of them, and
the number is decimal (100 MB, ~4.7% under GitHub's limit) so the engine
refuses before the host does. Refusal happens at save time, where the
author can still act, as well as at deploy time; a config key would only
restate the question every installation would then answer differently,
the same reasoning as the fixed JPEG quality in the HEIC converter.

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
header parsing, YAML-adjacent frontmatter, and a static file server
for `./blog.sh preview` (`lib/preview_server.rb`, plain `TCPServer`)
instead of the `webrick`-dependent `ruby -run -e httpd` one-liner.

**HEIC is refused with instructions by default; converting it is an
opt-in (`media.convert_heic`), never automatic.** The iPhone's default
photo format displays only in Safari, so silently attaching one puts a
broken image in front of most readers -- but converting silently would
mean the site serves a different file than the author handed over, and
would make an image tool a de-facto dependency of the engine. So the
default is the same honesty the engine uses elsewhere: stop before
anything is copied or deleted, name the file, print the exact command.
The opt-in conversion shells out to whatever the machine already has
(sips is part of macOS; heif-convert, ImageMagick and vips are probed
for an actual HEIC delegate first), and a missing or failing tool
degrades back to the refusal. Detection is by content -- the ftyp box
-- not extension, so a HEIC named `.jpg` is caught, and AVIF, which
shares the container but which browsers render natively, is recognized
and deliberately left alone. A converted staging file in `incoming/`
counts as consumed by a successful save, exactly like a directly copied
photo. Pure-Ruby conversion was not an option to reject politely: HEIC
decoding is HEVC decompression, and a native gem for it would break the
no-gems promise for real. *Cost:* one more config key, and the
conversion quality (JPEG, fixed 90) is not configurable -- a knob
nobody asked for would outlive the question.

**A phone video is mentioned, not refused -- the opposite of HEIC, and
for a measurable reason.** A HEIC photo displays in Safari and nowhere
else; HEVC video plays in the large majority of browsers, so refusing it
would take away a video most readers could watch. The genuinely
undeployable files are already stopped by the per-file size limit, and on
real footage the two almost coincide: of twelve clips straight off a
phone, exactly one was HEVC -- and it was also the only one over 100 MB.
What was missing was a sentence at the moment the author can still act,
so `lib/video_probe.rb` reads the video track's codec out of the file's
own boxes (no ffprobe, the same box walk `MediaDimensions` already does)
and the save says one line about it. The `.mov` container gets the same
treatment for a different reason: the video inside is usually ordinary
H.264, but not every browser accepts the container, and repacking it to
`.mp4` copies the video across untouched. Neither message blocks the
save, and the suggested command names the real file -- ffmpeg is not
installed on a Mac by default, so the message says where to get it.
*Cost:* the engine now knows about codecs, which it did not before; a
new codec that browsers disagree about would need a line here.

**`rexml` is required lazily, inside the two fetchers that need it, not
at load time.** `rexml` ships as a Ruby *default gem* -- present in a
normal install, but some distros split their Ruby package and leave
default gems out of the minimal one (Debian/Ubuntu's bare `ruby` vs.
`ruby-full`). A build with no `widgets.pixelfed`/`widgets.rss`
configured never touches `require 'rexml/document'` at all, so it
can't fail over a dependency the site doesn't use; a `LoadError` when
the widget *is* configured says exactly what to install rather than
crashing the whole build. *Cost:* the require call moved from the top
of two files to inside their `fetch_items`, a small deviation from
every other file's load-time-requires convention.

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

## Terminal UI

**Interactive niceties, but the plain path stays authoritative.** Arrow
menus, single-key answers and colors appear only on a real TTY;
everything the CLI does must still work identically when piped, and no
escape code may ever reach a log. *Cost:* two code paths in the
dialogs -- worth it, since cron and scripts drive the same commands
humans do.

**No curses, no fullscreen, no dependencies.** `io/console` plus VT100
sequences cover what a conversational CLI needs, and staying inline
keeps the whole session in the scrollback where a user can scroll back
through it. *Cost:* no complex layouts -- deliberately not the goal.

**The menu scrolls; the lists aren't capped to fit a screen.** Pickers
used to offer only the 10 most recent posts because the menu printed
every item it was handed, so anything longer than the terminal broke its
cursor-up repaint. Scrolling a window moves that limit into the UI where
it belongs -- on a blog with thousands of posts, a cap that small is a
functional restriction, not tidiness. *Cost:* window arithmetic (and
digits selecting within the visible window, not the whole list).

**Site icons come from one PNG.** Pages link `assets/images/favicon.png`
directly, `apple-touch-icon` points at the same file (iOS scales it), and
`/favicon.ico` is generated at build time by wrapping that PNG in an ICO
container. One image to maintain instead of three, and the `.ico` exists only
because a set of clients -- bots, feed readers, link-preview services, older
browsers -- request the root path blindly and never read a `<link>`; without
it each of those was a 404. Writing the 22-byte container ourselves keeps the
no-gems rule intact, the same trade as the QR encoder below. *Cost:* an
oversized source can't state its true size in ICO's one-byte dimension
fields, so browsers report 256 -- invisible at the sizes a favicon renders.

**Per-install graphics live outside git.** The banner and favicon are
per-site artwork, like `config/site.yml` is per-site identity -- so their
live names (`assets/images/header.png`, `favicon.png`) are gitignored and
the repo tracks only `assets/images/defaults/`, which the build copies to
any live name that's missing. Before this split, a deployment that pulled
the repo had its own artwork sitting on tracked paths: every `git pull`
either refused ("would be overwritten") or silently reverted the site's
face to the project's. *Cost:* replacing the shipped default requires
deleting the live file, not just committing a new default -- an existing
live file always wins.

**A QR encoder in the repo rather than a gem or a web service.** The
draft-preview-on-a-phone workflow is the reason this engine looks the
way it does, and a scannable code closes its last manual step. Sending
the URL to an external QR service would leak an unlisted preview
address; a gem would break "no gems". *Cost:* ~200 lines of spec
implementation, kept honest by verifying every module against a
reference encoder.

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

**`banner.claim` is a separate field from `site.description`, not the
same value reused.** `site.description` feeds `<meta name="description">`
and the RSS `<description>` too, so it has to stay plain text -- a
literal `<br>` there would leak broken markup into a feed reader or a
search result snippet. `banner.claim` exists purely so the banner
overlay can have a manual line break (or any other markup) without
touching those other, stricter consumers; it's optional and raw HTML,
same trust level as `about.html`/`footer.note_html` (site.yml is
owner-edited config, not visitor input). *Cost:* one more field to
know about, and the two can drift out of sync if a site changes its
description without updating the claim override to match.
