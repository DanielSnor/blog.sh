# Operating blog.sh

Day-to-day usage of an installed site: writing, deploying, cron, backup
and what to do when something fails. For the zero-to-deployed path see
[install.md](install.md).

## Writing and publishing

`./blog.sh` with no arguments opens a numbered menu; every command also
works directly (`./blog.sh add`, `edit`, `publish`, ...). The flow is
built around drafts:

1. **`add`** opens `$EDITOR` with a frontmatter template (title, tags,
   type) -- the in-editor hint links to the `/markdown/` syntax
   reference on your own site. Saving always creates a **draft**: it
   builds and deploys immediately, but only onto a hidden
   `/draft/<token>/<slug>/` address with `noindex` -- invisible in every
   listing, shareable by URL (that's the point: open the preview on a
   phone or send it to someone before publishing).
2. The CLI then asks: **publish / schedule / keep as draft / back to
   editing.** Publishing sets the date to that moment (scheduling asks
   for one instead), moves the post to its real URL and -- with a comments
   network configured (Mastodon or Bluesky, see
   [install.md](install.md#8-comments-network-optional-mastodon-or-bluesky)) --
   sends the announcement post that replies-as-comments hang off.
3. **`edit <slug>`** round-trips the stored post back to Markdown in
   your editor. A save that would drop content markdown can't express
   (an imported embed, a link card) warns and asks before proceeding.
4. **`unpublish <slug>`** returns a post to draft and deletes its
   announcement on the network (an announcement pointing at a dead URL
   helps nobody). The next publish gets a fresh date.
   **`delete <slug>`** moves the post and its media to `trash/` --
   **`restore <slug>`** brings it back. Trash keeps only the most
   recent deletion per slug.
   The same slug can exist in several years (backdating makes that
   easy); every slug-addressed command -- `edit`, `delete`, `toot`,
   `publish`, ... -- then first lists the matching posts (date, type,
   state, title) and asks which one you mean, so a delete can't
   silently land on the older post. A number picks, anything else
   cancels.
5. **`toot <slug>`** (Mastodon sites) or **`bluesky <slug>`** (Bluesky
   sites) (re-)sends the announcement for an already published post --
   typically an imported one that never had one. An existing
   announcement is never overwritten.

**Backdating** isn't part of that flow -- publishing means "now" -- but
the frontmatter parser still honors a `date:` line you type in by hand
(the template just doesn't offer one). To publish a draft into the
past:

```bash
./blog.sh edit muj-post      # add a line between the --- markers:  date: 2019-11-17 10:00
./blog.sh publish muj-post   # -> "Date kept from frontmatter: Nov 17, 2019 10:00"
```

The date takes any format `Time.parse` reads and is interpreted in
`site.timezone`. The post's URL year follows the date -- the JSON and
the media directory move into that year -- and the auto-announcement
asks for confirmation first when the date is more than a day off. A
backdated post is ordered by its date, so it can skip the homepage and
RSS entirely and land straight in the archive; the CLI says so when it
happens. If another post already owns that year/slug combination,
publishing refuses rather than overwrite it. (`schedule` is the
opposite direction on purpose: it refuses past dates.)

**Scheduled publishing:** in the post-save dialog, choose `[s]` and
enter the publish date and time directly -- the
[publish-scheduled cron](#cron-sidebar-widgets-and-post-stats) then
publishes the draft (toot included) once that date arrives, keeping it
as the post's date. The standalone `./blog.sh schedule <slug>` asks the
same question, so either route works. The time you type is read in
`site.timezone` ([install.md](install.md#2-configure-the-site----configsiteyml))
-- worth setting before you schedule anything from a server, whose clock
is usually UTC. A past date is refused (that would
just mean "publish now", and `publish` is for that). Running `schedule`
on an already scheduled draft cancels it; `list` shows scheduled drafts
as `[SCHEDULED]`.

### In the terminal

The CLI adapts to where it runs. In an interactive terminal you get
arrow-key menus (digits still quick-select, typing a slug still works),
single-keypress answers without Enter, colored state markers and a
**QR code of the draft preview URL** -- point your phone's camera at
the screen instead of retyping a token. A menu longer than the terminal
is tall scrolls, showing your position in the list next to the hint.
Piped, scripted or cron runs get the plain line-based prompts unchanged,
with no escape codes in the output. Colors honor `NO_COLOR` and
`TERM=dumb`.

`./blog.sh preview [<port>]` serves the built site locally (default
port 8000) when you want to look at it without deploying.

### Properties and actions

`./blog.sh props <slug>` (in the wizard: pick a post, then `v`) shows
everything about one post in one place -- state, type, tags, the pin,
the announcement -- and offers the guarded actions:

- **published**: unpublish, (re-)announce, pin/unpin, rename the slug,
  review the old addresses that redirect here, delete;
- **draft**: publish, schedule (or reschedule, or cancel the schedule),
  rename the slug, delete.

Type and tags are shown here but *edited* in the frontmatter of `edit`,
prefilled with their current values -- one keystroke away from the text
they describe. The pin is the exception: it is a switch, not a value,
so `[c]` flips it right here (the `pinned:` header line keeps working
too). The pinned post is also marked `[PINNED]` in every list and
picker, so it can be found without remembering it. A plain draft shows
no time on purpose: a draft has none until publishing or scheduling
gives it one.

**Renaming a slug** never breaks a link. The old address stays on the
site as a one-page redirect to the new one, recorded in the post itself
(`former_slugs`), so it survives edits, re-imports and full rebuilds. A
rename costs one extra page per old address -- not a 404. Two things to
know: unpublishing takes the redirects off the site along with the post
(they return when it does), and deleting the post deletes its old
addresses' redirects with it. Renaming a draft is free -- nothing is
published yet -- but its preview URL changes, so share the new link.
One consequence the redirect can't cover: feed readers identify posts by
their URL, so a renamed post may appear once more as a new item in
subscribers' readers. The redirect keeps every clicked link working;
what a reader app shows is its own business.

**Moving a post to another year** -- editing its date across a New Year
-- moves its public address the same way a rename does, and records the
old one the same way. The link from before the edit keeps working.

**Old addresses can also be given up**, with `[a]` in the same dialog:
it lists every address that redirects here and drops the one you pick.
There is one situation where that is the only cure rather than a
preference: if a NEW post has since taken an old address, the build
refuses to overwrite a live page with a redirect stub -- correctly -- and
says so on every build. The entry can never do anything again, and `[a]`
marks exactly that entry as "taken by another post". Dropping any other
one is a decision, not a repair: that link stops working for good.

The wizard menu lists five activities, not every command: publish,
schedule, unpublish, delete and the announcement live in this dialog
(and the draft dialog) instead of being menu items. Every CLI command
still exists unchanged -- `./blog.sh unpublish <slug>` works exactly as
before; only the menu stopped listing it.

## Writing from a phone

The trick is that a bare filename in an image line resolves against the
`incoming/` staging directory:

1. Shoot a photo, upload it via any SFTP client into `<repo>/incoming/`
   (setup: [install.md](install.md#7-running-on-a-server)).
2. SSH into the server, `./blog.sh add`, and write
   `![caption](photo.jpg)` -- no path.
3. If the photo hasn't finished uploading yet, the CLI waits and
   re-checks on Enter instead of failing.
4. On save the photo is copied into `media.nosync/<year>/<slug>/` and
   its `incoming/` copy is removed -- an empty `incoming/` means nothing
   is pending.
5. Editing that post later doesn't need the photo again: a bare filename
   is looked for in the post's own `media.nosync/<year>/<slug>/` first and
   in `incoming/` only after that, so a file that's already been saved
   resolves without any upload (and without being copied again).

iPhones photograph in HEIC by default, which only Safari can display.
Attaching one stops the save with the exact conversion command -- or, with
`media.convert_heic: true` in `config/site.yml`, the engine converts it to
JPEG itself during the save (detected by content, so a HEIC named `.jpg`
is caught too; AVIF, which browsers do display, is left alone). The
simplest fix is on the phone itself: Settings → Camera → Formats →
Most Compatible.

**Video from the same phone is mentioned, not refused.** The same
setting decides the codec, and the save says one line when it matters:
that a clip is HEVC (most browsers play it, the rest show an empty
player), or that it is a QuickTime `.mov` (the video inside is usually
ordinary H.264, but not every browser accepts the container). Both come
with the `ffmpeg` command that fixes them -- re-encoding for the codec,
repacking for the container, which copies the video across untouched.
The post is saved either way; the only hard stop for a video is the
per-file size limit, and a long 4K clip reaches that on its own.

## Pinning a post to the front page

The `[c]` action in `./blog.sh props <slug>` pins a published post --
or unpins it again; `pinned: true` in the post's header
(`./blog.sh edit <slug>`) does the same thing the long way round. A
pinned post is held at the top of the front page, marked with a pin in
the corner of its date badge. It appears there once: while it is still on the front
page anyway it is lifted to the top rather than shown twice, and once it
has aged onto `/page/2/` the front page keeps the copy at the top while
page 2 lists it in its normal place, unmarked.

Only the front page. Type and tag listings, the RSS feed, the sitemap
and the search index stay strictly chronological -- a pin is a statement
about the front page, not about the archive. Toggling it costs one or
two files in a deploy, because pagination is anchored and the front page
is the only flexible one. Pin a second post and the newest of them wins,
with a warning in the build output.

## Publishing slots

Set the times posts usually go out and `[s]` stops asking for a date:

```yaml
publishing:
  slots:
    - "mon 09:30"
    - "wed 09:30"
    - "fri 09:30"
    # or a single "daily 09:00"
```

The draft dialog then names the next FREE slot in the `[s]` choice
itself, and the prompt offers it: Enter accepts, typing a date overrides
it, the cancel word backs out. Free means no other scheduled post is
aimed at that exact time, so three drafts written in one evening queue
onto three consecutive slots instead of publishing together, and the
confirmation says which post goes out before this one.

The offer also names the slots it had to walk past, and the post sitting
in each:

```
Publish when?
  Next free slot: Aug 9, 2026 17:30
  Earlier slots are taken:
     Aug 6, 2026 17:30 → 'a-post'
     Aug 8, 2026 08:30 → 'another'
```

Without that line an offer of Sunday evening on a site whose slots
include Saturday morning reads as a queue that skips Saturdays -- the
answer being that Saturday was already taken. The properties dialog of a
scheduled draft prints the whole queue for the same reason, with an arrow
on the post you are looking at.

Slots only ever suggest. A post scheduled by hand for 14:17 occupies no
slot and blocks nobody, nothing moves a post that already has a time,
and without the key in `config/site.yml` the prompt is the plain one it
always was. Times follow `site.timezone`, daylight saving included --
"mon 09:30" is 09:30 on the wall clock on both sides of the change. The
cron still runs every 15 minutes, so a slot publishes within that window
of its time.

### Working the queue

`./blog.sh queue` (also a wizard menu entry) shows every scheduled post
in publish order and acts on the one you pick:

- `[u]` / `[d]` move it a slot earlier or later. Moving exchanges times
  with the neighbouring post -- the set of occupied times never changes,
  only which post sits in which. A hand-scheduled 14:17 stays a 14:17.
- `[p]` publishes it right now, the same flow as publishing a draft by
  hand (announcement included).
- `[s]` asks for a different time, same prompt as scheduling.
- `[n]` returns it to the drafts; the post keeps its text, loses only
  the plan.

When a post leaves the queue -- published now, or removed -- its time is
free again, and the screen offers to let the posts behind it each step
forward into the gap, every one taking over its predecessor's time. It
only offers: a hand-picked date further down may be deliberate, and
nothing moves a post's time except you. A post whose time already passed
is waiting for the cron and can't be reordered.

The preview rebuilds once, when you leave the screen, not after every
move.

## Attachments and the document type

A line that is nothing but `[label](handbook.pdf)` -- a bare filename,
whitelisted extension -- makes the file part of the post: it is picked
up from `incoming/` exactly like a photo, stored in
`media.nosync/<year>/<slug>/`, and rendered as a download card showing
the label, the extension and the file's size. A link to an address stays
a link; the engine can only publish files it was handed.

Whitelisted: `.pdf .zip .tgz .epub .txt .md .ics .gpx .csv` (`.tar.gz`
is not, because only the last suffix survives the rename -- use `.tgz`).
A post whose text is a short line plus attachments is filed under
DOCUMENTS, which appears in the nav once the first such post exists; a
longer article that attaches its data stays an article with a file on it.

## Importing from another platform

`./import.sh` opens its own wizard: pick a source, and it reads the whole
thing in dry-run first and tells you what *would* be written -- how many
posts and media files, the first few slugs, and how many items it skipped
and why. Nothing is written until you confirm, and confirming means typing the number of posts rather than pressing a key -- an answer you can't give without having read the preview. Sources are Bluesky and Tumblr over their
APIs, and five exports you already have on disk: Twitter/X, Mastodon,
Pixelfed, Instagram, and WordPress or any RSS/Atom feed -- those last two
are one option, since a WXR export is RSS with extra elements and the file
says which it is.

Every source also runs without the wizard, for cron or a scripted
migration -- one `scripts/migrate_<source>.rb` each, e.g.
`scripts/migrate_bluesky.rb <handle>`, `scripts/migrate_instagram.rb <export-dir>`,
`scripts/migrate_twitter.rb <export-dir>`,
`scripts/migrate_feed.rb <export.xml | feed-url>`.
Those skip the preview and write immediately; see
[the README](../README.md#importing-existing-content).

Two things to expect on a real archive:

- **It is slow, and it says so.** Media is downloaded per post, so a few
  thousand posts run for hours. Every phase reports progress -- what it's
  reading, how many items it found, then a `12/847` counter -- so a quiet
  terminal means something is wrong, not that it's working. Sample before
  committing to that: the Tumblr and Twitter scripts take `LIMIT=20` to
  import only the first twenty, which is enough to see whether the mapping
  does what you expect. A second full run then overwrites them in place.
- **The deploy guard will stop you afterwards**, because a bulk import is
  exactly the "file count swung wildly" shape it watches for. That's
  working as intended: check the numbers, then re-run with `--force`.

Per-source walkthroughs -- where to get each export, what is kept and
skipped, undo, troubleshooting -- live in [importing.md](importing.md).

Re-running an import is safe. Posts are matched on
`source.platform`/`account`/`original_id` and overwritten in place, so a
second pass fixes a bad first one rather than doubling it. That same triple
is the safe way to undo an import: select on it rather than on "everything
except the posts I wrote".

Back up `content.nosync/` before the first real import
(`tar czf ../content-backup-$(date +%F).tar.gz content.nosync`) -- it isn't
in git, and on a server there's nothing else to fall back on.

## Deploying

`./blog.sh rebuild` = build + deploy with `--prune` in one step; the
publish/edit flows run it for you. The deploy script alone:

```bash
./scripts/deploy-web.sh             # only new/changed files
./scripts/deploy-web.sh --dry-run   # print what would happen, touch nothing
./scripts/deploy-web.sh --prune     # also delete files the build no longer generates
./scripts/deploy-web.sh --force     # ignore the manifest, re-upload everything
./scripts/deploy-web.sh --only=A,B  # just the listed files
```

Things worth knowing:

- **The safety guards.** Four of them, all measuring this build against
  the last build a deploy *accepted* -- recorded in
  `.deploy_baseline.json` before the first byte goes out, so no upload
  failure can move it:

  | Guard | Trips at | What it does |
  | --- | --- | --- |
  | File count dropped | >20%, at least 8 files | stops |
  | Total bytes dropped | >50%, at least 25 MB | stops |
  | File count grew | >20%, at least 25 files | stops |
  | Total bytes grew | >50% | says so, continues |

  A drop almost always means a broken build; the byte version catches
  what counts cannot -- the same pages, each nearly empty. Growth in
  bytes is only a notice, because adding a video is authoring, not a
  malfunction; a single file too big to host is caught separately and by
  name (below). If a swing is genuinely intended (bulk import, mass
  deletion), rerun with `--force`. An empty build is always refused.

  The percentages need those absolute floors to be usable on a small
  site: 20% of a 32-file build is six files, so two posts published at
  once would otherwise read as an explosion -- and abort a flow that
  `./blog.sh` runs for you, which cannot pass `--force`.

  A drop also measures against the manifest when that is larger, since
  every entry in it is a file that really did upload. Growth never does:
  the manifest legitimately lags the build after a failed upload or on a
  fresh target, and reading that lag as growth is exactly what used to
  disable these guards.
- **One file-size limit, everywhere.** A single file over 100 MB is
  refused -- when the post is saved (so you can still shrink it) and
  again before a deploy sends it. The same limit applies to every
  backend so the site stays portable: the strictest supported target
  (git pages) refuses anything larger. `--force` does not lift it, since
  the target would refuse the file on every run. Files between 50 MB and
  100 MB are named but allowed. A file already on the target from before
  this limit existed is reported, not refused.
- **`--prune` is the only destructive flag.** Without it, files the
  build stopped generating stay live on the target (the deploy log
  counts these "orphans"). With the `git` backend every deploy is a
  snapshot and prunes implicitly -- the log says "(snapshot deploy)".
- **The previous run's outcome is reported, not acted on.** A deploy that
  failed or was interrupted says so at the top of the next one, and after
  three unfinished runs in a row it says that too -- something is being
  refused every time. Deliberately a warning however high that count
  goes: stopping after N attempts would be its own dead end.
- **Manifests are disposable.** `.deploy_manifest*.json` (one per
  backend) records what the target already has. Deleting one is always
  safe -- the next deploy re-uploads everything once and rebuilds it. The
  guards are unaffected, because their reference lives elsewhere.
- **Switching backends** starts from a fresh manifest on purpose; the
  first deploy to a new target uploads the whole site. The baseline is
  *shared* across backends -- it describes the build, which is the same
  wherever it goes -- so switching targets no longer leaves the guards
  with nothing to compare against.

### Checking the guards by hand

`--dry-run` needs no target and writes nothing, which makes it the way to
prove the guards still behave before trusting a release. Copy a build to a
scratch directory, point `DEPLOY_TARGET_DIR` at a throwaway path with
`DEPLOY_BACKEND=local`, and work through the cases that are easy to get
wrong:

| Set up | `--dry-run` must |
| --- | --- |
| Delete one post from a small site | pass -- the absolute floor covers it |
| Delete most of the build | stop, naming the accepted build it compared against |
| Publish two posts at once on a small site | pass |
| Duplicate the build | stop |
| Baseline intact, manifest truncated, build complete | pass -- this is recovery after a failed upload, and it is the case a naive fix breaks |
| Same, but the build is also broken | stop |
| Same file count, contents emptied past 25 MB | stop on bytes |
| Add one 60 MB file | pass, with a notice |
| Add one 120 MB file | stop, naming the file |
| Empty `public.nosync/` | stop |
| Delete `.deploy_baseline.json` | pass, saying the growth guard stands down once |
| Any of the above | leave `.deploy_baseline.json` untouched -- a dry run is read-only |

Two things make this easier to reason about: the failure state is anything
that leaves `last_run.outcome` in `.deploy_baseline.json` set to something
other than `ok`, and a run under `--only` must never change that file at
all (that is how the sidebar cron stays out of the way).

## Cron (sidebar widgets and post stats)

`scripts/refresh-sidebar.sh` refetches the widget JSON (toots, Bluesky,
Pixelfed, commits, RSS) and per-post stats, then uploads **only those
files** -- no site rebuild:

```
*/30 * * * * /path/to/blog.sh/scripts/refresh-sidebar.sh
```

Every 30 minutes is plenty. Post stats refresh live for posts younger
than ~90 days; older posts get a full refresh about once a week
(tracked in `.stats_full_refresh_at`). A failed fetch **keeps the last
known content** rather than publishing an empty widget -- a one-minute
network hiccup never blanks the sidebar. Systems without cron: a
systemd timer or launchd job invoking the same script does the same
thing. No widgets configured = no cron needed.

A second, optional job publishes scheduled drafts
(`./blog.sh schedule`) once their date arrives -- it exits immediately
when nothing is due, so a tight interval costs nothing:

```
*/15 * * * * /path/to/blog.sh/scripts/publish-scheduled.sh
```

A post is announced before the site is rebuilt, so the toot and the page
it links to come from the same build. If the deploy then fails, the job
leaves a `.deploy-pending` marker and the next run retries the deploy on
its own, even with nothing due -- so an announcement never keeps pointing
at a page that was never uploaded. A post that cannot be published (a slug
the target year already owns, a malformed date) is reported by name and
skipped; the rest of the batch still publishes.

## Backup

Back up the per-deployment data -- the engine itself is a git clone and
everything generated is rebuildable:

| Path | Why |
| --- | --- |
| `content.nosync/posts/` | the posts -- the one thing that's truly irreplaceable |
| `media.nosync/` | their images and videos |
| `config/site.yml` | site identity and integrations |
| `assets/images/header.png`, `assets/images/favicon.png` | your banner and icon -- gitignored, so a fresh clone brings back the engine's defaults instead, silently ([Banner and favicon](install.md#4-banner-and-favicon)) |
| `env.sh` | tokens (or re-create them; mind the file's 600 mode in backups too) |
| `trash/` | optional -- deleted-but-recoverable posts |

Not needed: `public.nosync/` (build output), `.deploy_manifest*.json`
(self-heals with one full re-upload), `.deploy_baseline.json` (the guards'
reference; losing it costs one deploy with the growth guard standing down,
and it is rewritten by that same run), `incoming/` (transient staging), and
the working files next to them -- `.last-edit.md` (the text from the last
editor session, with `.last-edit.meta` recording which command it came
from) and `.deploy-pending` (a marker that says a scheduled publish still
owes the target a deploy; see [Deploying](#deploying)).
**Restore** = fresh clone + copy those paths back + `./blog.sh rebuild`.
The same list is exactly what to move when changing machines.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Anything at all, and you need to know what you're running | `./blog.sh version` -- it needs neither `env.sh` nor a config, on purpose. |
| Anything config-shaped, and you want the whole picture | `./blog.sh doctor` -- it reads whatever is on disk and reports every problem at once, each with a fix line. It runs on a config too broken for anything else to load, including one whose YAML won't parse, and needs neither `env.sh` nor a valid config. Add `--online` to also ask whether the feeds, the analytics script and the access token still answer. |
| `config/site.yml is not valid YAML` | The message names the line and column. Almost always a tab where spaces belong, a missing quote, or a colon inside an unquoted value (`title: Colon: here`). `./blog.sh doctor` says the same thing without stopping at the first problem. |
| A save aborted and took your text with it | It didn't: the text is in `.last-edit.md`, and the next `add`/`edit` offers it back -- `[r]` opens the editor on it, `[d]` throws it away, `[c]` leaves it alone. Text from an interrupted `edit <slug>` is only offered to that same post: restoring it into an `add` would make a second post out of it, so the offer names the command that does continue it. |
| `Missing env.sh` | `./setup.sh`, or copy the template by hand: `cp env.sh.example env.sh && chmod 600 env.sh`. An unedited copy works locally. |
| `Missing config/site.yml` | Same two ways: `./setup.sh`, or `cp config/site.yml.example config/site.yml` and fill it in -- the build refuses to guess. |
| `Duplicate year/slug ... build stopped` | Two posts resolve to the same URL and media directory. Rename one slug; the build aborts rather than silently overwriting one with the other. |
| Deploy stopped with a "% drop/increase" message | One of the four guards -- see [Deploying](#deploying). Broken build until proven otherwise; `--force` only when the change is intended. The message names what it compared against, and when. |
| Deploy or save stopped naming a file over 100 MB | One limit for every backend, so the site stays portable ([Deploying](#deploying)). Shrink the file, or take it out of the post and link to it instead. `--force` does not lift this -- the target would refuse it every run. |
| `N deploys in a row have not finished` | Something is refused every time: an oversized file, expired credentials, a target that is gone. The guards are still on; the failures listed under that line say which. |
| `upload -> ... (HTTP 401)` on Surfer | Token expired or wrong -- create a fresh one in the Surfer UI and update `SURFER_TOKEN`. |
| `Mastodon API returned 401` / toot was not created | `MASTODON_ACCESS_TOKEN` missing, expired, or lacking the `write:statuses` scope. The post itself is fine -- fix the token and use `./blog.sh toot <slug>`. |
| `Posting to Bluesky failed` / announcement not sent | `BLUESKY_APP_PASSWORD` missing, revoked, or it's the account password instead of an app password (Settings → App Passwords). The post itself is fine -- fix it and use `./blog.sh bluesky <slug>`. |
| Sidebar widget disappeared from the page | Its fetch returned nothing repeatedly (`refresh-sidebar` logs say which) -- the widget card hides when its JSON is empty/unreachable. Check the instance/feed URL in `config/site.yml`. |
| `MISSING media: <slug> -> <file>` during build | A post references a file that isn't in `media.nosync/<year>/<slug>/` -- restore the file or edit the post. The build continues, and a copy already uploaded stays on the site rather than being pruned, so the page keeps working until you fix it. |
| `Unreadable post file(s) ... build stopped` | A post's JSON is truncated or isn't a post object -- the message names every offending file. Fix or remove them; `list` and the pickers keep working meanwhile and name it too. |
| `The image size could not be read` when attaching a photo | PNG, JPEG, GIF and WebP are measured; anything else is attached and rendered without reserved space, so the page jumps once while loading. |
| `HEIC displays only in Safari` when attaching a photo | The iPhone default format. Convert it with the command the message prints, set `media.convert_heic: true` to have the engine do it, or set the phone to Settings → Camera → Formats → Most Compatible. |
| `/markdown/` page missing | `templates/markdown-cheat-sheet.<lang>.md` was removed -- restore it from the repo (`git checkout templates/`). |
| A published post shows the wrong date | Publishing uses "now" and scheduling uses the date you entered, so a surprising date means a `date:` line was typed into the frontmatter by hand -- it's respected, including past dates (which skip the homepage -- by design). |
| sftp deploy hangs | It's waiting for a password -- the sftp backend needs key-based auth (see [install.md](install.md#sftp-hosts-with-neither-rsync-nor-git)). |

When in doubt: `ruby build/build_blog.rb` and
`./scripts/deploy-web.sh --dry-run` are both safe to run any time --
the build only writes into `public.nosync/`, and a dry run touches
nothing at all.
