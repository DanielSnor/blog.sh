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
disagrees. The rules, measured against a real archive before
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

**The bar sizes itself instead of being sized for a label set.** That
"budget" was a count, and a count is the wrong unit: the `document` type
made it nine items, and a site that uses all of them ran its longest
label under the search field -- measured, one locale overflowed at the
full width and the other two had almost no slack, and anywhere between
the mobile breakpoint and the full width every locale did. Three rules
replace the budget: the menu may wrap to a second row, the search box
never shrinks or is overlapped, and the gap between items is tighter --
across eight gaps that recovers more than the whole overflow without
shortening a single label. A tenth type, a longer translation or a
different font now costs a taller bar rather than a hidden item.
*Cost:* a denser menu, and a two-row bar in the narrow band where the
longest locale still doesn't fit on one.

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

**Every card in a listing says how long its post takes to read, including
the ones that take under a minute.** Stars, boosts and comments come from
an announcement, which on a real archive almost no post has -- so a meta
row fed by those appeared on a handful of cards and read as a break in the
listing, while a reading time is the one thing every post can report,
which is what keeps the row (and the column of cards) constant. *Cost:* on
an archive of short posts most cards carry the same three words -- a
column that keeps its shape was judged worth more than a field that earns
its place on every row.

## Publishing and comments

**Comments are replies to an announcement post -- on exactly one
network.** No comment database, no moderation queue, no GDPR surface,
no spam plugin -- replies live where people already are (Mastodon or
Bluesky, whose thread APIs a visitor's browser can read directly -- when
the server allows it. GoToSocial does not: reading a thread there needs a
token on every request, with nothing to configure, and a Mastodon in
secure mode behaves the same. On such a server the live mode cannot work
at all, and `comments.approval: fav` -- where a cron reads the thread WITH
a token and only starred replies reach the page -- is the whole of what is
available. `doctor --online` asks the question and says which one you have). The two networks are deliberately exclusive:
configuring both would split every post's discussion into two
half-threads, so the build refuses it. *Cost:* comments require a
presence on the chosen network, and deleting the announcement deletes
the discussion (which `unpublish` does deliberately, to never leave an
announcement pointing at a dead URL).

**Moderation, where there is any, is a star on the reply -- and it is
off by default.** The engine had no answer to a reply written to wound:
the thread was published whole, and the only recourse was on the
network. `comments.approval: fav` inverts it -- a reply appears under
the article once the author favourites it, from whatever client they
already have on their phone. No queue, no dashboard, no second identity
system: the moderation interface is the social app the comments already
live in, and the approval is one tap in the place you were reading
anyway. Two rules keep the result readable rather than merely filtered:
the author's own replies need no star (nobody stars themselves, and
without it half of every exchange would vanish), and a reply is only
shown if everything between it and the announcement is shown too (an
approved answer to a rejected comment answers nothing).

*Costs, and they are real:*
- **A favourite is public**, on both networks. Approving is also
  endorsing in the eyes of anyone who looks, and every star handed out
  over the years is retroactively an approval. A private signal
  (Mastodon bookmarks, Bluesky's saved posts) would not carry that, and
  is the obvious second mode if this one chafes.
- **Comments stop being live.** The live thread was the justification
  for the one client-side exception to *no third-party requests from
  the visitor's browser* (below), and a moderated thread is no longer
  live -- the page shows a curated subset either way -- so the exception
  lapses with it: cron writes `comments.json` and the page reads it
  from its own origin. What that changes, and what avatars still do, is
  said once, there.
- **The engine now stores other people's words.** Modestly: only what
  was approved, rewritten from the source on every cron run, with no
  interface that can edit it -- a cache, not a database. But the claim
  above, that there is nothing to moderate or migrate, holds only while
  this is off, and a deletion at the source follows at the refresh
  cron's cadence rather than immediately -- under an old post, somebody's
  deleted reply can outlive its deletion here by up to a week. That lag
  is part of this decision's price, not a tunable; the cadences behind
  it, and how to settle a deletion on the spot, are in
  [operations.md](operations.md#cron-sidebar-widgets-and-post-stats).
- **Turning it on hides every existing comment** until the author goes
  and stars the ones worth keeping. Which is why the default is off and
  why it stays a per-site decision.
- **It is not a defence, it is a filter.** The reply still stands on the
  network, under an announcement this site links to. Block, mute and
  report are still the only things that touch it there.

**Everything starts as a draft, and drafts live on the public site
behind a `SecureRandom` token with `noindex`.** The whole point is
previewing from a phone or sending the link to a reviewer before
publishing -- a localhost-only preview can't do either. *Cost:* the
draft text physically exists on the host; the token (and staying out of
every listing and index) is the fence.

**A published post can be unlisted, and unlisted is as far as it goes.**
`unlisted: true` is the draft's hidden-address idea generalised to a
post that is finished -- what it reaches is in
[operations.md](operations.md#properties-and-actions). It stops short of
being a password deliberately: a static host serves whatever it is asked
for, so the only honest way to gate a page would be encrypting it in the
browser, and that is a promise this engine will not make (the key would
sit in the same page). *Cost:* anyone holding the link can read it and
pass it on. The truth test is the loose one, unlike `pinned`'s strict
one, because the two typos are not worth the same: a mistyped pin costs
a post its place at the top, a mistyped `unlisted` would put something
into every listing its author meant to keep out of them.

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
only the posts whose local day actually differs -- a handful on a real
archive, none of them changing year.

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

Since 1.6 there is a layer above that: the build records what went into
each page and does not render the ones whose inputs have not moved,
because comparing bytes still costs rendering them first. The record is
never an authority -- anything it cannot vouch for is rendered and
compared as before -- and it is thrown away whole whenever a template, a
locale, the configuration or the engine changes, since any of those can
reach every page.

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
full re-upload, never correctness. The guards themselves -- what trips
them and how to prove them by hand -- are in
[operations.md](operations.md#deploying).

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
hosts differ wildly -- a git pages host refuses large files outright, a
plain rsync target refuses nothing -- but a per-backend limit would mean a
post that saves today becomes undeployable the day the site moves. The
strictest supported target therefore sets the rule for all of them, with
the engine's line drawn just under that host's so it refuses before the
host does (the limit itself is in
[operations.md](operations.md#deploying)). Refusal happens at save time,
where the author can still act, as well as at deploy time; a config key
would only restate the question every installation would then answer
differently, the same reasoning as the fixed JPEG quality in the HEIC
converter.

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

**Platform players are built from the address, not from the platform's
embed code -- and only for platforms whose address says enough.** YouTube
worked this way from the start; Vimeo, PeerTube, archive.org, Spotify,
SoundCloud and Mixcloud now follow it (`lib/embed.rb`). The engine stores a
provider and an id, never foreign HTML, so a post carries no third party's
markup or tracking, and a platform changing its embed path is one edit here
rather than a re-import of every post. It also costs no network call at any
point: writing a post stays an offline operation.
*Cost:* six patterns that a platform can invalidate, each of which fails
visibly (an empty player) rather than silently. The rules came from the
live services, not their docs, which is where the corrections came from --
an unlisted Vimeo link needs its hash or the player answers 403, a Spotify
URL copied from a browser carries an `intl-xx` segment the embed path
rejects, SoundCloud has no id to extract so the whole watch URL is handed
to the widget (which is also how a private track's secret_token gets
through), and Mixcloud's widget redirects to a second hostname that the
page's CSP has to allow as well.

**Two platforms are asked once, when the post is saved -- the only network
call in the authoring path.** Funkwhale and Bandcamp cannot be handled by
the string transform the other platforms use, and both were established
against the live services rather than their docs: Funkwhale's obvious embed
path builds a player that looks right and stays a permanently black
rectangle on a current instance, while its oEmbed endpoint answers
correctly; Bandcamp's page address contains no id at all, only a slug, and
it has no oEmbed endpoint to ask, so the id comes from the page's own
twitter:player metadata. The answer is stored in the post as an address, so
an edit never asks again and the build stays offline -- and it is an
address, not the HTML those services returned, because "a post carries no
third party's markup" does not stop applying because a lookup was involved.
A failed lookup (offline, a timeout, a service with no player for that
address) is a sentence and a saved post with a link in it, never a refused
save: writing on a train has to end with a written post. *Cost:* saving a
post can now block on a slow service for as long as the shared HTTP
deadline allows, and the CLI says which address it is waiting on.

**A page's frame-src is computed from the players it actually carries.**
PeerTube is federated, so the host is a property of the post rather than of
the engine: a fixed policy could not name it in advance, and widening
frame-src for every site to cover every supported platform would hand every
page permissions it does not use. Post pages and listings therefore compute
their own frame origins from their blocks. The PeerTube host is taken with
`URI.parse` and an explicit hostname shape, never pattern-matched out of the
raw string -- `https://good.example@evil.test/w/x` reads as the good host to
a careless regex and as the evil one to the browser. *Cost:* a page's CSP is
no longer a constant, and a new provider has to say which origins it needs.

**A phone video is mentioned, not refused -- the opposite of HEIC, and
for a measurable reason.** A HEIC photo displays in Safari and nowhere
else; HEVC video plays in the large majority of browsers, so refusing it
would take away a video most readers could watch. The genuinely
undeployable files are already stopped by the per-file size limit, and on
real footage the two almost coincide -- the clip that is HEVC tends to be
the one over the limit anyway.
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

**`rexml` is required lazily, inside each file that needs it, not at
load time.** `rexml` ships as a Ruby *default gem* -- present in a
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
party can't slow the page. Two exceptions are deliberate, and naming
both matters -- an unlisted one reads later like an oversight somebody
should "fix". The first is the comments thread, fetched client-side
because it is the actual live discussion -- and that one lapses the
moment `comments.approval` is on, since a moderated thread is no longer
live and cron has read it already (see *Publishing and comments*).
Avatars in comments remain hotlinked either way. The second is an
analytics script, for a site that asks for one: `analytics:` is absent
by default, nothing is added to any page without it, and the policy
names that origin only while the section exists. Fonts are self-hosted
for the same reason as the rest.

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

**No curses, no dependencies.** `io/console` plus VT100 sequences cover
what this needs. *Cost:* no complex layouts -- deliberately not the goal.

**A screen that repaints, but not the alternate screen.** Every keypress
in a dialog used to leave another full copy of it behind: walking three
rows down the queue, opening the actions and moving a post three slots
scrolled the view by dozens of lines and buried the terminal in identical
screens. Frames are painted from the top of the viewport instead, so the
same sequence scrolls it by none. The alternate screen (`\e[?1049h`) would
have been the obvious way and is deliberately not used: it discards its
plane on exit, and this CLI prints things worth keeping -- a draft's
address, what a deploy uploaded, what refused. Painting in place keeps
both properties, the screen holding still *and* the scrollback intact.
*Cost:* a full frame per keypress is about a third more bytes over the
wire than the old partial repaint; repainting only changed rows is the
obvious answer if that ever matters.

**Action rows fold; navigation keys are trimmed.** The keys under a post
run to 137 characters in German, so on 80 columns -- or a phone over SSH
-- something has to give. `browse`'s navigation line drops items from the
middle, which is right for ways to move around: a reader can guess them.
The rows under a post are the actions themselves, so they break between
items instead and keep every one. Hiding `[x] delete` would hide it from
exactly the reader least able to guess it is there. *Cost:* on a narrow
terminal the keys take four lines instead of one.

**Confirmations are graded by what disappears.** Deleting a post and
unpublishing one ask for the slug to be typed out. Restoring an earlier
version asks for one key, because it loses nothing -- the current text is
kept as a version of its own first, which is what the sentence above the
prompt says. A prompt explaining that a move is reversible and then
demanding a word be written out argues with itself. It stays a
confirmation rather than becoming none: Enter in the list is a single
keystroke and a restore overwrites the text being worked on.

**The menu scrolls; the lists aren't capped to fit a screen.** Pickers
used to offer only the 10 most recent posts, because back when the menu
printed every item it was handed, anything longer than the terminal broke
the repaint. Scrolling a window moves that limit into the UI where it
belongs -- on a blog with thousands of posts, a cap that small is a
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

**Config written by the engine is edited as text, never dumped from a
parsed hash.** Loading `config/site.yml`, changing a key and writing it
back is one line of Ruby and would have destroyed the thing that makes
the file usable: most of its lines are comments and commented-out
blocks, only a fraction are keys. The
rest is the documentation for every setting the engine has, plus the
commented-out blocks you uncomment when you want a widget or a custom
font -- and real sites hand-edit around it (sean.cz keeps an `<img>`
inside `about.html`'s folded scalar). So `lib/config_writer.rb`
substitutes values line by line and leaves every other byte identical,
and a config that doesn't exist yet is seeded from the example verbatim
so every key it will ever set is already present to be substituted into.
*Cost:* a text editor for a structured format, which is only safe
because it is anchored (key name plus the exact indentation its parent
implies, searched only inside that parent) and verified afterwards by
reparsing the file and comparing the values back. Prose comments in the
template parse as keys otherwise -- `# Optional: posts per listing page`
would index as `Optional:`.

**`./setup.sh` asks for credentials; `./import.sh` deliberately does
not.** The import wizard reads `TUMBLR_API_KEY` from the environment
because a bulk import is not the place to be handling a token, and there
is a documented file for it. Setup is that file's other end -- it exists
to create `env.sh` -- so refusing to ask would leave the one job it
cannot delegate undone. The token is read without echo, masked in the
diff it shows back, written into a file created mode 600, and verified
against the instance before it is kept. *Cost:* one dialog in this
engine handles a secret, so that is one place to be careful about
rather than none.

**A site is customized by its configuration, not by editing the
engine.** There is one release, and it either runs as shipped or runs
the way a site asked for in `config/site.yml` -- so switching off the
sidebar, naming your own menu, loading your own stylesheet or turning on
the hero are all settings, and none of them is a reason to hold a
modified copy of a template. That matters because a modified template
is not a private matter: `git pull` either refuses it or silently
reverts it, and the site's own look is what gets lost.

Two layers carry it. Configuration switches whole structural regions on
and off (`layout.sidebar`, `layout.hero`, `nav:`),
and a stylesheet of the site's own (`site.extra_css`) does everything
about how those regions look. Neither can rot: the engine knows about
the first, and a CSS rule that stops matching simply stops applying.

*Cost, and it is a real one:* the engine has to anticipate. Every future
"I want it different" is either a new key or an answer of no, and the
line between them has to hold -- keys name **regions and modes**, never
individual visual properties, or this file becomes a stylesheet written
in YAML. The palette made the same trade first (7 keys, everything else
derived, promote one only when reality demands it).

*The rejected alternative:* letting a site override whole templates from
a directory of its own. It would answer every wish at once, which is
exactly why it is the wrong shape here -- it is not "a setting", it is a
fork with better manners, and a forked template is frozen in time. The
site quietly stops receiving whatever the engine adds to that template
later, and nothing says so.

**Editing a post is undoable, and not because a setting says so.**
Deleting a post has always gone to `trash/`; editing one was final, and
editing is what happens every day. The previous text is now kept before
an overwrite -- by an edit, and by a re-import, which is the more
dangerous of the two because it replaces the whole archive at once and
nobody reads a few thousand posts afterwards. There is no key to turn it
off: a safety net with a switch is off exactly when it is needed, since
nobody turns it on before the mistake, and none of the engine's other
guards (the trash, the slug-collision abort, the deploy guards) are
optional either -- only the destructive direction ever is. Field-only
writes make no version, or a history of pin toggles would bury the one
entry anybody wants. *Cost:* ten copies of the text per edited post, and
media is not versioned -- so a version old enough can name an image the
post no longer has, which is what the cap is for.

**A series is not a tag.** Tags are many per post and unordered; a series
is one and has an order, which is the whole of the difference and enough
of it. Ordering is by date with `series_part:` as the override, the same
shape `type:` uses -- publishing out of order is rare enough that the
date is the right default and common enough that there has to be a way to
say otherwise. Previous and next are offered only *within* a series and
never across the archive: on a site assembled from many imported
platforms the chronological neighbour of an essay is a tweet from
fifteen years earlier, and calling that "next" is noise wearing the
clothes of navigation. *Cost:* one more field, and a series of one is
silently not a series (it is a post).

**A feed per tag, only for the tags the menu names.** Generating one for
every tag means thousands of files on a real archive, rebuilt and re-diffed on
every build, that nobody will ever fetch -- the exact inverse of "nothing
renders that wasn't asked for". A tag in `nav:` is the site saying this
is a subject it publishes on, which is the same statement as "somebody
might want to follow just this". *Cost:* a site with the derived type
menu gets no tag feeds at all, which is the intended answer rather than
an oversight -- it has not named a subject yet.

**robots.txt can say no to AI crawlers, and the engine does not decide
which way.** `seo.block_ai_crawlers` writes out a maintained list;
`seo.robots_extra` is appended verbatim for the ones no list will be
current about. Off by default, because wanting to be findable in a
machine-generated answer is a legitimate position and not the engine's to
take for a site. And it is documented as a *request*: some of these
crawlers honour robots.txt and some do not, so anything here that said
"blocks" would be a lie. *Cost:* a list in the engine goes stale, and
updating it is a release note.

**A listing's heading marks what it is; it doesn't say it twice.** Tag
and search headings used to be sentences with a colon ("Tag: archive").
The word is now its own element beside the value, hidden from sight by
the stylesheet -- clipped rather than `display: none`, since that would
take it out of the accessibility tree as well, and a screen reader on a
tag page would then announce a bare name with no hint of where it is.
The value carries the marker instead: a tag wears the pill shape tags
wear everywhere else, a query sits behind the magnifier from the nav.
Content-type listings get no marker at all, and never had one --
**a marker belongs where the value is arbitrary text**, which a tag name
and a search query are and a closed set of eight labels is not. The
window title keeps the word: a browser tab and a search result have
neither stylesheet nor pill, so there it is the only thing telling two
pages apart. *Cost:* one more element in the markup, and a site that
wants the word back has to undo one rule rather than translate a string.

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
touching those other, stricter consumers; it's optional, and Markdown
or raw HTML, same trust level as `about.html`/`footer.note_html`
(site.yml is owner-edited config, not visitor input). *Cost:* one more
field to know about, and the two can drift out of sync if a site
changes its description without updating the claim override to match.

**The site's own chrome speaks Markdown, and keeps accepting HTML.**
`about.html`, `footer.note_html`, `footer.copyright` and `banner.claim`
are the only texts on the site written outside a post, and until 1.2.1
they were also the only ones that had to be written in HTML -- a
Markdown blog asking for a hand-typed `<a href>` in the one field that
introduces its author. They go through `lib/markdown_parser.rb` now,
the same parser the posts use. Raw HTML still passes through untouched
(`apply_formatting(..., escape: false)`), which is why nothing has to
be migrated: existing configs keep rendering byte for byte, and an
`<img>` stays the way to put a photo in a bio. *Cost:* two renderers
for one syntax -- the chrome's block vocabulary is deliberately smaller
than a post's (no images, video, audio, attachments or tables, all of
which resolve against a post's media directory or need more width than
a 260px sidebar has), so a table pasted into a bio renders as a
paragraph of pipes rather than a table. And the passthrough means a
typo in hand-written HTML still reaches the page, exactly as before.

**Keyboard focus is one ring for the whole site, not a design per
control.** The alternative was to give each control its own indicator,
matched to the ground it sits on. One ring is easier to recognise -- a
reader learns what "you are here" looks like once -- and it is one rule
to keep in step instead of a dozen. Where the ring has to move inside
the control it is because the ground outside it is not something the
stylesheet can vouch for (a banner photograph, the lightbox's black) or
is the accent the ring is drawn in (the active menu item, the date
badge), not because those controls wanted a look of their own. *Cost:*
the ring is the accent, and it is not derived from what is behind it --
a palette whose accent sits close to its card background gets a quiet
ring on the page body, and a skin that repaints a control's ground has
to look at the ring itself rather than getting a new one for free.

**The phone's search field is ordered ahead of the menu it is written
after.** In the markup the bar reads button, menu, search -- which is the
order a desktop wants. On a phone the menu is 100% wide and wraps to its
own line, so left alone the field would land on a third line and move
down the screen every time the menu opened; `order` puts it back beside
the button. *Cost:* the usual price of ordering, that Tab follows the
markup and not the eye -- with the menu open, Tab goes from the button
down to the menu items and only then back up to the field. Closed, the
items are `display: none` and there is nothing to disagree about, which
is the state the bar is in almost always.

**The images a lightbox can open are made into buttons by the script, not
by the build.** `tabindex` and `role="button"` are added at runtime rather
than written into the HTML, so a page served without its JavaScript --
blocked, failed, still loading -- shows pictures rather than things that
announce themselves as pressable and then do nothing when pressed. *Cost:*
the tab order of a photo-heavy post is only correct once the script has
run, and a reader tabbing in the first few hundred milliseconds walks past
images that are about to become buttons.

**Once the top bar became sticky, the menu repeated under the content
went.** The bar answers the question the bottom menu existed for -- how a
reader who has just finished an article gets anywhere -- for the whole
page, search field included, and keeping both put two identical menus on
one phone screen. There is no key to bring it back: a repeat of a bar
that is always on screen is not a preference somebody might hold, and a
key nobody would ever set is a key that rots. The line the bottom menu
drew between content and footer is drawn by the stylesheet now. *Cost:*
an appearance change that arrives unasked and has no way back short of a
site carrying its own template.

**The sticky rule is scoped to the page's own bar, not to `nav`.** A post
carries a second `<nav>` inside `<main>` for its pagination, and there is
nothing sticky about "older posts". `.wrap > nav` says which one is the
menu bar. *Cost:* a structural selector rather than a class -- move the
bar out of `.wrap` and the stickiness follows the markup instead of the
intent.

**Search ranks with four numbers, and draws fifty.** A post whose title
is the query is a better answer than one that mentioned the word once,
whatever their dates -- so the hits are scored (title above text, whole
word above part of a word) and date decides only the ties, which is
where the archive-is-a-diary argument for chronological results was
right. The scale is four constants rather than a term-frequency
model, because the whole of it has to be explainable in one sentence to
be maintainable in a 150-line script. *Cost:* no BM25, no term
frequency -- forty mentions do not beat one, and the index's single
folded blob cannot tell a tag from a paragraph, so a post *tagged* with
the query ranks no higher than one that says it in passing. Both are
fixable by putting more fields in the index, and both would cost every
visitor the bytes.

**The search address is replaced, not pushed.** Typing rewrites `?q=` on
the current history entry rather than adding one. Pushing would give
every keystroke its own entry, and Back would then walk the query
backwards a letter at a time without ever leaving the page -- the
behaviour people mean when they complain a site "traps" the back button.
*Cost:* Back does not undo a search; it leaves /search/ altogether, and
there is no way to return to the query you had two words ago. Which is
the trade: the address is worth having so a search can be sent to
somebody and come back to, and it is not worth having at the price of the
back button.

**A result list has a ceiling, and the count above it does not.** Fifty
cards, with the true total still printed above them. Showing everything
cost a real archive visible time and tens of thousands of page elements;
showing fifty and lying about the total would be worse than either.
There is no "show more" and
no pagination: a reader who has not found it in fifty ranked answers is
better served by narrowing the query, and every extra control here is one
more thing to translate and maintain. *Cost:* the 51st answer is
unreachable except by asking a better question -- which is only fair
because the list is ranked, and would have been indefensible while it was
in date order.

**The front page's h1 is there and not visible.** Every listing heading
became an h1 (it was an h2, a sibling of the post titles it introduces),
which left the front page as the only listing with no heading to promote
-- it announces nothing, being the site itself. A visible one would put a
word on every front page built with this engine that nobody asked for, so
it carries the site's title clipped out of sight, the same way the
"Tag"/"Search" labels are. *Cost:* text in the page that nobody sees --
which means it can go stale without anyone noticing, and a tool reading
the page as text rather than rendering it will find a title where there
used to be none.

**The banner's overlay lines are a column, not two pinned corners.** The
site name and the claim used to be positioned absolutely against opposite
corners of the picture, which reads well and holds only as long as there
is picture between them -- and the height of that picture is the one
thing the engine does not decide. On a phone it runs out. Rather than
buying a little room (smaller type, thinner insets) and hoping, the two
went into one box laid out as a column, where overlapping is not a state
the layout can reach. *Cost:* one more element in the markup of every
page, and the insets moved out of the two lines into the box around them
-- so a stylesheet that positioned `.banner-title` or `.banner-claim`
itself has to be looked at. In return, the corners are described in one
place instead of four, and a banner short enough to run out of room
crowds its lines instead of printing one through the other.

**Reduced motion is answered with one blanket rule, not a list of the
things that move.** `prefers-reduced-motion` switches off transitions
and animations for everything, rather than naming the declarations that
actually carry movement -- and most of the engine's do not, they fade a
colour. A list would be more precise on the day it was written and
wrong on the first day somebody added a rule and did not think of it,
which is exactly the kind of upkeep a preference like this cannot
depend on. *Cost:* a skin's own transitions go off with the engine's,
whether or not they move anything, and an animation a site genuinely
needs under that preference (a loading indicator that means something)
has to ask for itself back in its own media query.
