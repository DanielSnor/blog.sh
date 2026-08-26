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

**A post's header can say more than the template offers.** `add` prefills
title, tags and type, because that is what every post needs; the parser
accepts a few more keys, and `edit` brings back whichever ones the post
already carries, so each can be read as well as changed:

- **`series: Name`** files the post into a series. A series with two or
  more published parts gets a listing of its own at `/series/<slug>/` --
  a series of one is just a post, and the listing appears when the
  second part does. The build puts "Part 2 of 5"
  on each post in it, with the way to the part before and the part after
  -- within the series only, since a post's chronological neighbours
  across a whole archive are rarely what a reader wants next. Parts are
  ordered by date, which is what a series written in order needs;
  **`series_part: 3`** is for the one written out of order or inserted
  afterwards. The draft preview answers the series question at writing
  time: a name with published parts shows how many and which part this
  would become, and a name no published post carries yet is called out
  as "a typo, or the first part?" -- so a misspelling doesn't quietly
  found a second series. `check` catches the older ones
  ([below](#checking-the-archive)).
- **`toc: true` / `toc: false`** overrides the table of contents. A post
  with four headings or more gets one on its own -- that is the length at
  which a reader starts scrolling to look for something rather than
  reading down. Say `false` on a post that has the headings but not the
  shape, `true` to force one below the threshold.
- **`hero: true` / `hero: false`** decides whether the post's first usable
  image runs full width above the title, with the date moving into a
  byline under the picture. Without the key the post follows
  `layout.hero` for the whole site
  ([install.md](install.md#the-menu-the-regions-and-a-stylesheet-of-your-own)).
  A 1px image is never lifted, and a post with no usable picture simply
  keeps the ordinary shape -- there is no second template to keep in step.

**Two things the site says without being asked.** Every card and every
post page carries how long the post takes to read, counted at 200 words
a minute -- the same figure `./blog.sh stats` reports; a post too short
to time says "under a minute". And the build writes a `noindex`
`/404.html` in the site's own chrome, menu and search field included, so
a dead end is somewhere to go on from.

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

Two kinds of post are published by that cron without being announced, and
it says so per post, naming `./blog.sh toot <slug>` for sending the
announcement by hand: a post dated more than a day from now (a backfill --
an old thread given a page, a post imported and then queued -- reads as
news in a live timeline), and a post that already carries an announcement
of its own, which happens when it was published once, unpublished and put
back in the queue. Announcing that one again would leave the first thread
live with its replies while the post pointed at a second, empty one.
Several posts falling due in the same tick -- after the cron has been down,
say -- are published oldest first, in the order the queue was arranged in.

### In the terminal

The CLI adapts to where it runs. In an interactive terminal you get
arrow-key menus (digits still quick-select, typing a slug still works),
single-keypress answers without Enter, colored state markers and a
**QR code of the draft preview URL** -- point your phone's camera at
the screen instead of retyping a token. A menu longer than the terminal
is tall scrolls, showing your position in the list next to the hint;
`Page Up`, `Page Down`, `Home` and `End` work in every list.

**The screens hold still.** Menus, the queue, the archive, a post's
properties and every picker repaint over themselves instead of printing
another copy on each keypress -- and not on the alternate screen, so the
last screen and your scrollback survive. Resizing straightens a waiting
menu, the queue or the properties screen on the spot; a picker or the
archive browser keeps the size it opened with until you leave it.

The three question-and-answer wizards -- `./setup.sh`, `./style.sh` and
`./import.sh` -- keep the section you are in and the answers already given
above the question, so a half-finished run says where you are.

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
  rename the slug, delete;
- **either, once there is one**: `[v]` restores what the post said before
  one of its recent saves.

**Undoing an edit** is what `[v]` is for. Every `edit` keeps the previous
text first, up to ten of them per post, and `[v]` lists them newest first
with the line under the cursor showing what that version said -- its
title, or its opening words when it has none -- so the choice is made by
recognising the text rather than by reading timestamps. The key appears
only on a post that has been edited at least once.

Choosing one is itself undoable: the current text is kept as a version
before it is replaced, so a wrong choice is one `[v]` away from being
walked back -- which is why a single key confirms it. Only the text comes
back -- images are not versioned, and the line above the list says so. A
version that will not parse stays in the list without a preview. Versions
travel with the post into the trash and back out again.

Type and tags are shown here but *edited* in the frontmatter of `edit`,
prefilled with their current values -- one keystroke away from the text
they describe. The pin is the exception: it is a switch, not a value,
so `[c]` flips it right here (the `pinned:` header line keeps working
too). The pinned post is also marked `[PINNED]` in every list and
picker, so it can be found without remembering it. A plain draft shows
no time on purpose: a draft has none until publishing or scheduling
gives it one.

**Keeping a post out of the listings** is the `unlisted: true` line in
its frontmatter. The post keeps its ordinary address, its date and its
redirects, and drops out of the homepage, the tag and type archives, the
feeds, the sitemap and the search index; its page is `noindex`. It is
the draft's hidden address, generalised to something finished -- for a
post meant for the few people you send the link to. **It is not a
password**: a static site hands over whatever is asked for, so anyone
with the link can read it and forward it. If that is not good enough,
the answer is not to publish it. Publishing an unlisted post announces
nothing -- by hand or from cron, and `--force` does not open that door,
because an announcement cannot be recalled once a server has it; to
announce the post, take the flag off first. `props` says so on an
unlisted post, and the line comes back with its current value the next
time you edit, so the state can be read as well as changed.

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

The wizard menu lists six activities -- a new post, a post in hand, the
scheduled-post queue, the archive browser, the trash and a rebuild --
not every command: publish, schedule, unpublish, delete and the
announcement live in this dialog (and the draft dialog) instead of
being menu items. Every CLI command still exists unchanged --
`./blog.sh unpublish <slug>` works exactly as before; only the menu
stopped listing it.

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

**A photo's GPS position never reaches the site.** Saving strips the
place of capture from the file's metadata (`media.strip_location`, on
unless `config/site.yml` turns it off -- the notes there say why); the
camera, the moment and the orientation stay. `./blog.sh doctor
--strip-location` cleans photos saved before the engine did this -- the
only thing doctor ever writes.

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
about the front page, not about the archive. Toggling it is a small
deploy, because pagination is anchored and the front page is the only
flexible one. Pin a second post and the newest of them wins, with a
warning in the build output.

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

The offer also names the earlier slots it had to walk past and the post
sitting in each, so a queue that seems to skip a day explains itself.
The properties dialog of a scheduled draft prints the whole queue for
the same reason, with an arrow on the post you are looking at.

Slots only ever suggest. A post scheduled by hand for 14:17 occupies no
slot and blocks nobody, nothing moves a post that already has a time,
and without the key in `config/site.yml` the prompt is the plain one it
always was. Times follow `site.timezone`, daylight saving included --
"mon 09:30" is 09:30 on the wall clock on both sides of the change. The
[publish-scheduled cron](#cron-sidebar-widgets-and-post-stats) still runs
on its interval, so a slot publishes within one tick of its time.

### Working the queue

`./blog.sh queue` (also a wizard menu entry) shows every scheduled post
in publish order and acts on the one you pick:

- `[u]` / `[d]` move it a slot earlier or later. Moving exchanges times
  with the neighbouring post -- the set of occupied times never changes,
  only which post sits in which. A hand-scheduled 14:17 stays a 14:17.
  The cursor follows the post you moved, so pressing `[u]` again carries
  the same post further.
- `[m]` picks the post up and carries it: the arrows then move the post
  itself through the queue, Enter puts it down and Escape leaves the queue
  as it was. Carrying from the eighth slot to the second steps the six in
  between back one slot each, so the same times stay occupied and the
  whole move is one write instead of one per slot. For a single slot
  `[u]`/`[d]` are quicker; `[m]` is for the longer trip, and it is offered
  in a terminal only -- a piped run has `[u]`/`[d]` and no screen to carry
  anything across.
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

If the publishing cron happens to be running at the moment you move
something, the move is refused rather than written: the two would be
writing the same files, and the cron holds them for a few seconds at a
time. Press the key again in a moment.

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
and why. Nothing is written until you confirm, and confirming means typing the
number of posts rather than pressing a key -- an answer you can't give
without having read the preview. The sources cover blog and newsletter
platforms (WordPress, Blogger, Ghost, Medium, Substack, a Jekyll/Hugo
tree, ...), the social networks (Twitter/X, Mastodon, Bluesky, Instagram,
...), podcast feeds, and the Wayback Machine for a blog whose platform no
longer exists at all. The wizard groups them by that question -- a blog
you published, a network you posted to, a dead site -- and the full list
lives in [importing.md](importing.md).

Every source also runs without the wizard, for cron or a scripted
migration -- one `scripts/migrate_<source>.rb` each, e.g.
`scripts/migrate_bluesky.rb <handle>`, `scripts/migrate_instagram.rb <export-dir>`,
`scripts/migrate_wayback.rb <https://dead-blog.example>`,
`scripts/migrate_feed.rb <export.xml | feed-url>`.
Those skip the preview and write immediately; see
[the README](../README.md#importing-existing-content).

Two things to expect on a real archive:

- **It is slow, and it says so.** Media is downloaded per post, so a few
  thousand posts run for hours. Every phase reports progress -- what it's
  reading, how many items it found, then a `12/847` counter -- so a quiet
  terminal means something is wrong, not that it's working. Sample before
  committing to that: every script takes `LIMIT=20` to import only the
  first twenty, which is enough to see whether the mapping does what you
  expect. A second full run then overwrites them in place.
- **The deploy guard will stop you afterwards**, because a bulk import is
  exactly the "file count swung wildly" shape it watches for. That's
  working as intended: check the numbers, then re-run with `--force`.
- **The summary names what HTML could not become blocks.** Every adapter
  that parses HTML bodies counts the elements it had to drop -- embeds
  and forms, usually -- and the summary lists them by name and count, so
  a silent summary means nothing was lost, not that nobody counted.

Per-source walkthroughs -- where to get each export, what is kept and
skipped, undo, troubleshooting -- live in [importing.md](importing.md).

Re-running an import is safe -- posts are matched on their source
identity and overwritten in place, never duplicated
([importing.md](importing.md#what-every-import-does)); the same identity
is the safe selector when [undoing an
import](importing.md#undoing-an-import).

Back up `content.nosync/` before the first real import
(`tar czf ../content-backup-$(date +%F).tar.gz content.nosync`) -- it isn't
in git, and on a server there's nothing else to fall back on.

## Taking your content elsewhere

```bash
./blog.sh export ~/my-blog-export        # everything, drafts included
./blog.sh export ~/public-copy --no-drafts
./blog.sh export ~/somewhere --dry-run   # counts, writes nothing
```

Writes the archive as a tree of markdown files with YAML front matter,
in Jekyll's layout: `_posts/2026-05-01-slug.md`, `_drafts/slug.md`,
pages at the root, media copied under `assets/<year>/<slug>/`. Without a
directory it writes to `tmp/export`. A directory that already has
something in it is refused until you repeat the command with `--force`,
which writes alongside what is there -- an export never deletes
anything, at either end.

It reads only the archive on disk -- deliberately, so it works on an
installation whose `env.sh` is gone or whose config no longer parses.

Three things are worth knowing before you rely on the result:

- **The summary counts what could not stay markdown.** Video, audio and
  link cards are written as HTML -- video and audio deliberately, because
  the engine's own `!![caption](url)` reads as an exclamation mark and an
  image to everybody else's markdown parser. Every engine that passes
  HTML through renders them properly, and importing the tree back gives
  them again as blocks -- each carries its own definition in a comment
  above it, which other engines ignore.
- **`redirect_from` is written in the shape `jekyll-redirect-from`
  reads,** and it merges both kinds of old address -- where the post
  lived on the platform it came from, and where it lived here before a
  rename. On a Jekyll site with that plugin, every address the post has
  ever had goes on answering.
- **An export can be imported back.** `./import.sh` → *Markdown tree*
  reads the `blogsh:` block the export writes, so posts keep their
  identity (`source`), their series, their redirects and their
  announcement URLs. That is the supported way to move an installation
  to another machine or another host -- and, run against a scratch
  copy, the way to check that an export really did come out whole.

## Checking the archive

```bash
./blog.sh check            # walks every post and every media file
./blog.sh check --online   # also asks whether the links that leave the site still answer
./blog.sh check --json     # the findings as data: every one of them, no screen
```

`doctor` asks whether the installation is sound and takes a second;
this asks whether the *archive* is, and walks all of it -- two commands
so the fast half keeps being run, and it is the fast half that belongs
before a deploy. `check` reads the content on disk, so it works before a
build has ever run, and it names a post and a slug for every finding
rather than a file under `public.nosync`: something to go and fix.

What it looks for, each with a line saying what to do about it:

- **A post file that will not read, a date nothing can parse, a post whose
  text is not a list of blocks, or a slug that is not one path segment
  (a slash or a `..` in it).** The build refuses to run on any of them, or
  writes the page nowhere good, so check says so first: without this it
  counted the archive minus the broken file and called the rest sound.
- **A file a queue move stepped aside and a crash left parked.** The
  parking name is dotted precisely so no listing shows it -- which also
  means nothing would ever find one again without this. What to do with
  it depends on whether the post inside is still in the archive somewhere:
  a copy of a post that landed is a leftover to compare and delete, a
  parked file that is the only copy of its post is one to put back under
  a free name, and the finding says which of the two it is looking at.
  It never tells you to write over the post standing at that name.
- **Media a post asks for and hasn't got** -- a video's poster image
  included -- usually an import whose download failed. The page renders
  a hole. A file that is there and useless -- empty, unreadable, or a
  folder under the picture's name -- is reported the same way, with a
  sentence that says which it is.
- **Images stored as 1px or smaller.** The build treats those as tracking
  pixels and drops them *together with their caption*, so the page loses
  both without saying so.
- **Internal links pointing at nothing.** Typically a permalink left over
  from an import, or a slug renamed back before renames left a redirect
  behind.
- **Links written relative to the post rather than to the site** --
  `./?item=another-post`, `photo/index.php?gallery=3`, `../about/`. A
  dynamic site could afford those; a static one resolves them inside the
  post's own address, and a static host ignores a query string, so the
  link answers 200 with the page the reader is already on. Nothing breaks
  and nobody arrives, which is why these survive audits: rewrite them as
  rooted paths. A bare `#fragment` is left alone -- resolving against its
  own page is the point of it.
- **Media directories no post owns** -- left by a deleted or renamed post,
  or an import that ran twice. Nothing links to them; they cost disk, not
  correctness, which is why they are a warning.
- **Files in a post's own media directory that the post no longer
  names** -- a source that dropped a picture leaves its file behind,
  because an import only ever adds. A warning too; dotfiles are left
  alone.
- **Two series whose names differ by a character or two** -- usually one
  series with a typo that quietly founded its own. A warning; names
  differing only in digits are left alone (`rok-2025` next to `rok-2026`
  is two year-series, not a typo).
- **One old address claimed by two posts.** Whichever renders last wins
  and the other's readers land on it.
- **Two posts that would be served at one address.** The build refuses to
  run at all in this state, so this is the one finding that stands between
  you and a site that cannot be rebuilt.
- **A `redirect_from` the build will not serve** -- one whose first segment
  belongs to the site itself (`/tag/...`, `/posts/...`), or whose shape no
  directory can be made of. The build says so once, in the middle of a log
  nobody keeps, and the old address quietly 404s; worse, a link pointing at
  it used to pass as sound.

- **Text carrying HTML entities instead of the characters they stand
  for.** `journalists &amp; writers` reads as `journalists &amp; writers`
  on the page: the build escapes it again, correctly, because as far as it
  knows the ampersand is what you wrote. Twitter escapes `&`, `<` and `>`
  in its archive without saying so, and the importer only learned to decode
  them in 1.4 -- so an archive imported before that carries them, and
  upgrading cannot help, since by then they are in the posts. Reported
  rather than corrected: somebody writing *about* html has every right to
  `&amp;` in their text.

It only reports, unless you ask it not to. On its own -- and that is how
cron runs it -- nothing here deletes a directory or rewrites a post: the
value of the tool is that its output can be trusted, and a checker that
also acts has to be trusted twice. `--repair` is where the asking happens,
one finding at a time and never without a key press; it is described
below, and it earns its trust the hard way -- it adds rather than
rewrites where it can, it moves files to the trash rather than deleting
them, and it keeps a version of a post before changing it. Twenty findings of each kind are
listed and the rest counted, so one bad import can't bury everything else.
It exits non-zero on errors only, never on warnings, so it can hang off
cron and speak up only when something is actually broken.

**`--online` additionally asks the web about every link that leaves the
site.** It takes minutes rather than a second, which is why it has to be
asked for by name. What it reports is deliberately narrow: a host that no
longer resolves, and a page answering 404 or 410. A timeout, a refused
connection, a 5xx or a 403 is the web saying "not right now", and
reporting those would turn one flaky evening into forty findings that are
all fine tomorrow. Anything that looks dead is confirmed with a second
request before it is believed, because some servers answer a HEAD with 404
and a GET with 200 for the same address. Verdicts are remembered in
`tmp/link-check.json` for two weeks, so running it again next week only
asks about the links it hasn't seen lately; deleting that file just means
the next run asks about everything.

`--repair` walks the findings and offers, for each one, the single repair
that finding allows -- nothing is applied without a key press. A dead link
to an old address is repaired on the **target** post, by writing that
address into its `redirect_from`: one added line, your own text untouched,
and every link to the old address answered at once, including the ones
from outside the site that no check can see. A link written relative to the
post is rewritten to the address it means. A media directory or file no
post references is moved to the trash the engine already uses --
`trash/<year>/<slug>/media/` -- and `./blog.sh restore <slug>` puts it
back; the repair pass never deletes anything. A file whose name differs
from the one on disk only in letter case or unicode form is not a leftover
at all: the pass offers to write the name the directory actually uses into
the post, and never touches the file.

Where the right answer is a matter of judgement -- two posts claiming one
old address, an image the author has to look at, a link to something this
archive never had, a slug two posts share across two years, or a target
that is still a draft -- it says so and passes over. A second run proposes
nothing, because the findings it repaired are gone; run `./blog.sh rebuild`
afterwards to put the changes on the site.

The screen shows at most twenty findings of a kind and totals the rest in
a "...and N more" line, which is right for reading and useless for acting
on: a script that wants to add `redirect_from` for every dead link cannot
work from a summary. `--json` prints all of them instead, each with the
kind it is (`link_dead`, `media_stray`, `series_similar`...) and the data
it is about -- the post's slug, the address, the file. The exit code is
the same in both modes: 0 when the archive is sound, 1 when something in
it is not.


## Counting the archive

```bash
./blog.sh stats           # a screen: posts by year and kind, words, tags, media, sources
./blog.sh stats --json    # the same figures, for whatever reads them next
```

Reads the archive on disk -- no build, no network, no `env.sh` -- and
comes back in seconds even on a large archive. What it says, and why
each line is there:

- **The archive**: posts split into published, drafts, scheduled and
  pages. The four add up to the total; a page that is also a draft counts
  once, as a page.
- **By year** and **What they are**: where the archive is thickest, and
  what it is made of (the dominant content type per post, the same one
  the `/type/` listings use).
- **Words**: total, mean and median. Both averages, deliberately -- an
  archive half made of imported tweets pulls the mean far above the
  middle, and only the pair says so.
- **Tags**, **Media** (files on disk, or what the posts ask for when the
  media directory is not here) and **Where it came from** -- the
  platforms the archive is actually made of, which is a different number
  from how many the importers support.

`--json` prints the same figures unlocalized and unrounded, so the
numbers can go into a post, a cron job or a graph.

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

  The absolute floors keep the percentages usable on a small site, where
  two posts published at once would otherwise read as an explosion.

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
  three unfinished runs in a row it says that too -- however high the
  count, since stopping after N attempts would be its own dead end.
- **Manifests are disposable.** `.deploy_manifest*.json` (one per
  backend) records what the target already has. Deleting one is always
  safe -- the next deploy re-uploads everything once and rebuilds it. The
  guards are unaffected, because their reference lives elsewhere.
- **...with one exception worth knowing.** `rsync`, `rclone` and `git`
  diff the target themselves, so a lost manifest costs one full re-upload
  and nothing else. For `sftp`, Surfer and a local directory the engine
  never reads the far end, so the manifest is also the only record of what
  stands on it: a file you delete at home *after* the manifest went missing
  stays on the target, and no flag will find it again. This is why a deploy
  says out loud that the manifest was written for another target instead of
  quietly starting over -- and why the target's identity ignores the
  switches that cannot move a connection (`-v`, `-q`, the order they are
  written in), so reformatting a line in `env.sh` is not a new target.

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
| Delete `.deploy_baseline.json` | pass, with no stand-down notice -- the growth guard borrows the file count from the manifest |
| Delete the manifest too | pass, saying the growth guard stands down once |
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

Every 30 minutes is plenty. The crontab lines in this section are
recommendations; what actually runs is whatever the installation's own
crontab says -- installing it is step 7 of
[install.md](install.md#7-running-on-a-server). Post stats refresh
live for posts younger
than ~90 days; older posts get a full refresh about once a week
(tracked in `.stats_full_refresh_at`). A failed fetch **keeps the last
known content** rather than publishing an empty widget -- a one-minute
network hiccup never blanks the sidebar. Systems without cron: a
systemd timer or launchd job invoking the same script does the same
thing. No widgets configured = no cron needed.

**With `comments.approval: fav` this job stops being optional.** It is
what reads which replies you favourited and writes `comments.json`, so
without it a newly starred comment never reaches the site -- the pages
keep whatever was uploaded last. The same "keeps the last known
content" rule applies and matters more here: a failed fetch leaves the
thread as last published rather than blanking a discussion.

Two timings to know. A comment starred under a recent post appears at
the next run, so within the cron interval. Under a post older than ~90
days it waits for the weekly full pass -- run

```
./scripts/refresh-sidebar.sh --full
```

to do that pass now instead. And switching moderation back off deletes
`comments.json` on the next run, so a rejected comment doesn't stay
readable at a public URL after the page stops showing it.

A second, optional job publishes scheduled drafts
(`./blog.sh schedule`) once their date arrives -- it exits immediately
when nothing is due, so a tight interval costs nothing:

```
*/15 * * * * /path/to/blog.sh/scripts/publish-scheduled.sh >/dev/null
```

Every run of that job touches `.last-scheduled-run` in the project root,
including the runs with nothing due. That file is the only evidence that
anything is serving the queue at all, and it is what `./blog.sh doctor`
reads to tell a queue that is simply waiting from one whose cron was
never set up.

A post is announced before the site is rebuilt, so the toot and the page
it links to come from the same build. If the deploy then fails, the job
leaves a `.deploy-pending` marker and the next run retries the deploy on
its own, even with nothing due -- so an announcement never keeps pointing
at a page that was never uploaded. A post that cannot be published (a slug
the target year already owns, a malformed date) is reported by name and
skipped; the rest of the batch still publishes.

### One writer at a time

Building and deploying take an advisory lock (`.blog-sh.lock` in the
project root), because two of the things that write `public.nosync` run
from cron: the scheduled publish and the sidebar refresh
([Cron](#cron-sidebar-widgets-and-post-stats)). On a large archive a
build plus a full deploy takes longer than
a tick, so overlapping runs are ordinary -- and what they do to each other
is not: a deploy walking a tree that is being rewritten, or pruning as an
orphan a page the other run has just published.

A run that finds the lock held does not wait for it. A cron tick says so
and leaves with exit 0 -- cron is back within its interval, and a queue of
blocked publishes would all wake up and do the same work at once. A run
you started reports it and exits non-zero, so `./blog.sh` doesn't tell you
a deploy happened when it didn't. The scheduled publish holds the lock for
its whole run (publish, rebuild, deploy are one operation as far as the
site is concerned), and the build and deploy it shells out to inherit it
rather than deadlock against their own parent.

Reordering the queue takes the same lock, for a different reason: it does
not write `public.nosync` at all, it writes the same post files the
scheduled publish is publishing from. It holds the lock only for the moment
of the move -- the checks and the writes together -- never while a prompt
is open, so a queue left on screen never keeps the cron out.

If the filesystem can't do advisory locks -- some network mounts -- the
lock degrades to no lock, which is where every installation was before
this existed.

## Backup

Back up the per-deployment data -- the engine itself is a git clone and
everything generated is rebuildable:

| Path | Why |
| --- | --- |
| `content.nosync/posts/` | the posts -- the one thing that's truly irreplaceable |
| `content.nosync/versions/` | what each edited post said before its last ten saves, which is what `[v]` restores from ([Properties and actions](#properties-and-actions)). It sits beside the content and dies with it, so a backup of the posts alone keeps the archive and loses the undo |
| `media.nosync/` | their images and videos |
| `config/site.yml` | site identity and integrations |
| `assets/images/header.png`, `assets/images/favicon.png` | your banner and icon -- gitignored, so a fresh clone brings back the engine's defaults instead, silently ([Banner and favicon](install.md#4-banner-and-favicon)) |
| `env.sh` | tokens (or re-create them; mind the file's 600 mode in backups too) |
| `trash/` | optional -- deleted-but-recoverable posts |
| `config/palettes.yml` | only if you added a palette of your own -- the file itself ships with the engine |

Not needed: `public.nosync/` (build output), `.deploy_manifest*.json`
(self-heals with one full re-upload), `.deploy_baseline.json` (the guards'
reference; losing it costs one deploy with the growth guard standing down,
and it is rewritten by that same run), `incoming/` (transient staging), and
the working files next to them -- `.last-edit.md` (the text from the last
editor session, with `.last-edit.meta` recording which command it came
from), `.deploy-pending` (a marker that says a scheduled publish still
owes the target a deploy; see [Deploying](#deploying)) and
`.last-scheduled-run` (the scheduled-publish heartbeat above). The
wizards' `config/site.yml.bak` and `env.sh.bak` are not needed either --
but the second holds your previous tokens, so delete rather than
archive it.
**Restore** = fresh clone + copy those paths back + `./blog.sh rebuild`.
The same list is exactly what to move when changing machines.

A backup is those paths as they are -- not an export. `./blog.sh export`
([Taking your content elsewhere](#taking-your-content-elsewhere)) is for
leaving, and it converts: what markdown cannot write down comes out as
HTML. Restoring from an export is possible (`./import.sh` reads it back
whole), but restoring from the archive itself is exact.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Anything at all, and you need to know what you're running | `./blog.sh version` -- it needs neither `env.sh` nor a config, on purpose. |
| The site looks wrong, or you want to change how it looks | `./style.sh` -- a menu over everything that decides how the site looks and what it says about itself; it lists its own sections. The bio, the footer note, the copyright line and the banner's claim are Markdown, the same as a post, and raw HTML still works in them; a multi-paragraph value needs YAML's literal block (`|-`) -- the notes in `config/site.yml.example` show why. Picking a palette offers a preview (light and dark side by side, uploaded to the site too so a phone can see it) before anything is written -- temporary on purpose, the next build takes it down -- and the run ends by offering a rebuild. |
| Anything config-shaped, and you want the whole picture | `./blog.sh doctor` -- it reads whatever is on disk and reports every problem at once, each with a fix line. It runs on a config too broken for anything else to load, including one whose YAML won't parse, and needs neither `env.sh` nor a valid config. Add `--online` to also ask whether the feeds, the analytics script and the access token still answer, and `--strip-location` to clean the location out of photos saved before the engine did it on the way in ([Writing from a phone](#writing-from-a-phone)); rebuild afterwards, since the site is built from what it cleans. |
| Anything archive-shaped -- a hole where a picture should be, a link that leads nowhere | `./blog.sh check` -- it walks every post and every media file and says what is broken *inside the archive*, each finding with a fix line; `--online` additionally asks whether the links that leave the site still answer ([Checking the archive](#checking-the-archive)). It only ever reports: nothing is deleted or rewritten, so it is safe to run at any time, including from cron. |
| `config/site.yml is not valid YAML` | The message names the line and column. Almost always a tab where spaces belong, a missing quote, or a colon inside an unquoted value (`title: Colon: here`). `./blog.sh doctor` says the same thing without stopping at the first problem. |
| A save aborted and took your text with it | It didn't: the text is in `.last-edit.md`, and the next `add`/`edit` offers it back -- `[r]` opens the editor on it, `[d]` throws it away, `[c]` leaves it alone. Text from an interrupted `edit <slug>` is only offered to that same post: restoring it into an `add` would make a second post out of it, so the offer names the command that does continue it. |
| `Missing env.sh` | `./setup.sh`, or copy the template by hand: `cp env.sh.example env.sh && chmod 600 env.sh`. An unedited copy works locally. |
| `Missing config/site.yml` | Same two ways: `./setup.sh`, or `cp config/site.yml.example config/site.yml` and fill it in -- the build refuses to guess. |
| `Duplicate year/slug ... build stopped` | Two posts resolve to the same URL and media directory. Rename one slug; the build aborts rather than silently overwriting one with the other. |
| Deploy stopped with a "% drop/increase" message | One of the four guards ([Deploying](#deploying)) -- broken build until proven otherwise, `--force` only when the change is intended. |
| Deploy or save stopped naming an oversized file | The one file-size limit ([Deploying](#deploying)) -- shrink the file, or take it out of the post and link to it instead. |
| `N deploys in a row have not finished` | Something is refused every time; the failures listed under that line say which ([Deploying](#deploying)). |
| `upload -> ... (HTTP 401)` on Surfer | Token expired or wrong -- create a fresh one in the Surfer admin UI (/_admin) and update `SURFER_TOKEN`. |
| `Mastodon API returned 401` / toot was not created | `MASTODON_ACCESS_TOKEN` missing, expired, or lacking the `write:statuses` scope. The post itself is fine -- fix the token and use `./blog.sh toot <slug>`. |
| `Posting to Bluesky failed` / announcement not sent | `BLUESKY_APP_PASSWORD` missing, revoked, or it's the account password instead of an app password (Settings → Privacy and security → App Passwords). The post itself is fine -- fix it and use `./blog.sh bluesky <slug>`. |
| Every comment disappeared after turning on `comments.approval` | Expected until you star them -- moderation publishes only favourited replies ([Cron](#cron-sidebar-widgets-and-post-stats)). If starring changes nothing either, `./blog.sh doctor --online` catches the usual cause: a token without `read:statuses`. |
| A comment you starred still isn't on the site | It arrives with the next `refresh-sidebar.sh` run; an older post waits for the full pass, which `--full` does now ([Cron](#cron-sidebar-widgets-and-post-stats)). Check the cron job is actually installed. |
| `comments.approval is on but MASTODON_ACCESS_TOKEN is not set` | The cron run refused to publish rather than emptying every thread; the pages keep their last known comments until the token is there ([Cron](#cron-sidebar-widgets-and-post-stats)). Same for `BLUESKY_APP_PASSWORD` on a Bluesky site. |
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
