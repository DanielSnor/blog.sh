# Importing an old blog

The long version of [operations.md → Importing](operations.md#importing-from-another-platform):
per-source walkthroughs, what each import keeps and skips, and how to check
-- or undo -- the result. Everything here was verified against real archives,
not just read from API docs.

Two ways in, same mapping underneath:

```bash
./import.sh                              # wizard: pick a source, preview, confirm
ruby scripts/migrate_<source>.rb <arg>   # scriptable: writes immediately, for cron
```

The wizard always reads the whole source in dry-run first and reports what
*would* be written -- posts, media files, the first slugs, and every skipped
item with its reason -- then asks you to **type the post count** to confirm.
The scripts skip the preview; sample with `LIMIT=20` instead, which stops
after twenty written posts. Re-running either way is safe: posts are matched
on `source.platform`/`account`/`original_id` and overwritten in place, never
duplicated.

## What every import does

- **Media comes home.** Images are downloaded (or copied from the export),
  stored in `media.nosync/<year>/<slug>/`, and measured, so every page can
  reserve layout space for them (one without known dimensions still renders,
  the page just jumps once while it loads). Downloads follow redirects and
  retry transient failures; a file that still can't be fetched costs that
  image, not the post, and the summary says so.
- **A file already here is not downloaded twice.** Each media entry records
  the address it came from, so a re-import recognises what the archive
  already holds and fetches only what is missing -- the summary says how
  many it did not have to fetch, and over a complete archive that is no
  requests at all. A picture that leaves a post and later returns finds
  its old file again -- the post's kept versions remember the address,
  and failing those the file's own bytes do -- so a drop-and-return
  cycle does not grow the post's directory.
- **An import only ever ADDS media.** A file already in
  `media.nosync/<year>/<slug>/` is never replaced -- not by a re-import,
  not by any flag -- because the bytes an import brings come from
  somewhere it cannot vouch for. `REFETCH_MEDIA=1` only makes the run ask
  the source about every address again instead of trusting the archive's
  records; what lands on disk is still just the files that were missing.
  When a download no longer matches the copy the archive keeps -- a
  source that re-encoded a picture under its old address -- the
  archive's copy wins and the summary counts the discarded download,
  which is the one signal that the source has drifted away from this
  archive. And nothing an import does repairs a damaged file:
  `./blog.sh check` reports media a post names that the archive doesn't
  have, and putting it right is a separate job with your own copy of the
  original.
- **The post describes the file that is really there.** Width and height
  are re-read from the archive's own copy once the media is in place, so
  a post cannot end up claiming dimensions over a file that never
  arrived. A copy that cannot be measured -- zero bytes, truncated, a
  format this engine cannot read -- leaves the post's previous record
  standing; on a first import, where there is no previous record, a
  video or an SVG keeps the dimensions its source stated. An entry whose
  file is missing entirely is left saying exactly what it said.
- **A re-import updates, never duplicates.** Posts are matched on their
  source identity -- platform, account and the item's own id -- not on the
  title, so fixing a typo at the source and importing again updates the
  existing post in place, keeping its slug and URL. The one exception is an
  item with no usable identity (a plain RSS item with neither `guid` nor
  `link`): rather than guess and risk merging two different posts, a
  re-import writes it again -- a duplicate you can delete, where a wrong
  match would destroy a post you can't get back.

  The other exception is about WHERE the export sits. Several sources have
  no account name anywhere in their files (Facebook, Threads, Wix, Movable
  Type, Substack), so the identity borrows the export's own directory or
  file name. Unpack the next export into a folder named after its date and
  every post in it is a new post: the archive imports a second time, slugs
  and all. Import from the same path each time -- or rename the new export
  to the old name -- and matching works as described.

  Ghost is a third shape, and this list left it out until 1.5.1: the
  address you type as the second argument is presented as "where the
  images live", and the host out of it is also half of every post's
  identity. Case and a leading `www.` are folded away, so
  `https://www.cynicky.blog` and `https://cynicky.blog` are the same site
  on a re-import -- but a genuinely different host is a different site,
  and typing one imports the archive a second time.

  A markdown tree is the one source that can do better, because a site
  built by Hugo or Jekyll writes its own name down. The identity is that
  name -- `baseURL` or `title` out of `hugo.toml` (or `config/_default/`),
  `url` or `title` out of `_config.yml` -- so such a tree can be moved,
  renamed, restored somewhere else or unpacked on a second machine and a
  re-import still finds its own posts. A tree that declares nothing falls
  back to the full path it was imported from, and that is the case to know
  about: a bare `content/` directory, a folder of `_posts/` with no
  `_config.yml` beside them, or anything a converter produced matches only
  while it stays where it was. Point the import at the site root rather
  than at the content directory where you can -- that is where the
  configuration is. A skeleton nobody has edited yet (`hugo new site`
  leaves `baseURL` at example.org, `jekyll new` leaves the title at "Your
  awesome title") counts as declaring nothing, on purpose: two untouched
  skeletons would otherwise claim the same identity and the second import
  would land on top of the first.
- **Origin becomes a tag.** Every imported post is tagged with its platform
  (`tumblr`, `wordpress`, ...; for a plain feed, the site's domain), so
  `/tag/tumblr/` is the whole of one old blog. Deduplicated
  case-insensitively against the post's own tags.
- **One bad item costs one item.** A date that won't parse or markup nothing
  anticipated is counted under `error` and named on stderr; the run
  continues. A rejected API key still stops everything, as it should.
- **What HTML conversion cannot keep is counted:** markup with no block
  equivalent (an iframe, an embedded player, a form) is dropped and named
  in the summary -- by every adapter that converts HTML, not just the
  feed import.
- **A dying source still leaves a summary.** If the platform stops answering
  mid-run (a 5xx on page twelve, a feed that goes away), the run stops,
  says so, and reports honest partial counts -- everything written up to
  that point is saved. The scripted path exits non-zero so cron notices.
  Re-running once the source recovers picks up safely: the posts already
  written are matched and updated, not duplicated.
- **Progress is narrated** -- what's being read and how big it is, then a
  running counter. A silent minute means something is wrong, not that it's
  working.
- **Old addresses can survive the move.** When the new site answers on the
  same domain the old blog did, a source that knows its original URLs --
  most do -- can record each published post's old path as
  `redirect_from`: the build then serves a redirect at every one of them,
  so nothing anyone ever linked goes dark. The wizard asks wherever the
  source can answer; the scripts take `KEEP_PERMALINKS=1`, and a source
  that needs a URL pattern's help says so in its section below. Say yes
  only on the same domain: on any other, the old paths were never yours
  to answer. Posts with no usable
  path (WordPress "plain" `?p=123` permalinks live in the query string,
  which a static file can never see) are counted in the summary and
  imported without a redirect. For an archive imported before this
  existed, `scripts/backfill_redirects.rb <old-domain>` adds the same
  entries from what the import already stored -- preview by default,
  `WRITE=1` to apply.
- **Nothing deploys by itself.** The wizard offers a rebuild at the end; the
  scripts leave both to you.

## Before the first real run

Back up your content -- it isn't in git, and on a server there is nothing
else to fall back on:

```bash
tar czf ../content-backup-$(date +%F).tar.gz content.nosync media.nosync
```

And expect the deploy guard afterwards: a bulk import is exactly the "file
count swung wildly" shape it watches for. Check the numbers, then re-run
`./scripts/deploy-web.sh` with `--force`.

## The sources

### beehiiv

```bash
ruby scripts/migrate_beehiiv.rb <posts.csv>
```

In beehiiv: **Settings → Export Data → Export Posts → Export All
Posts**, the posts CSV. One file, no media:
each row carries the entire EMAIL as HTML, and most of the import is
undoing that -- slicing out the real content, dropping template
variables, tracking pixels and the unsubscribe footer, turning the
layout tables back into prose. The subtitle becomes the first
paragraph, YouTube thumbnails become video blocks, and images download
from beehiiv's CDN with the email's quality=80 rewritten to full
quality. Paid posts import in full -- the export is yours -- but a
premium issue arrives as a **draft** tagged `beehiiv-premium` rather
than published, so nothing your subscribers paid for goes public
without you deciding it should.

Two things worth knowing, both the CSV's: **the only date in it is
`created_at`** -- beehiiv does not export the publish date, so a
long-scheduled archive can sit slightly early on the timeline -- and
tags ride in a semicolon-separated column that not every export
populates.

### Blogger

```bash
ruby scripts/migrate_blogger.rb <blog-backup.xml>
```

In Blogger: **Settings → Manage blog → Back up content**. The file is an
Atom feed that mixes your posts with **every comment anyone ever left**
and the blog's settings -- the importer tells them apart by their kind
marker, so the summary's `comment` and `not_a_post` counts are expected,
not a problem. Drafts come over as drafts.

Blogger's markup only ever points at thumbnails -- the size token in
each image URL (`/s320/`) is rewritten up front so the full-size file
downloads instead. The link-to-itself every image sits in is unwrapped;
a link to anywhere else is the author's and stays. YouTube embeds become
the same video blocks a hand-written post gets.

Old Blogger addresses (`/2015/03/post.html`) become real `.html` files
when permalinks are kept, so links from the blogspot era keep working
without any server configuration -- provided the blog ran on a custom
domain the new site now answers at.

### Bluesky

```bash
ruby scripts/migrate_bluesky.rb someone.bsky.social
```

Reads the public AppView -- the same unauthenticated API the sidebar widget
and comment threads use, so **no credentials**. Imports your standalone
posts; skipped and counted: reposts, quote-posts (replies never arrive --
the server filters them, which also means only a self-thread's opening post
is imported). Rich-text facets become formatting spans, hashtag facets
become tags. A video arrives as an HLS playlist rather than a file, so the
post gets its poster frame as an image -- better in an archive than a
"video unavailable" placeholder.

### Facebook

```bash
ruby scripts/migrate_facebook.rb <path-to-unpacked-export>
```

In Facebook: **Accounts Center (or Meta Account settings -- Meta is
renaming it, and you may see either) → Your information and permissions
→ Export your information → Create export**. Either format -- **HTML and JSON are both
read**, and the export says which one it is, so there is nothing to
choose here. Unpack the ZIP and point the script at the directory;
photos and videos come from the archive itself, no network. Where you
still get to pick, pick JSON: its timestamps are epochs, while the
HTML prints a wall clock in the account's own timezone without naming
it. The import reads that wall clock in the *site's* timezone -- the
same place, when you import your own archive into your own blog, and
verified epoch-exact against the JSON of the same account -- but an
archive from someone in another timezone is better taken as JSON. The
HTML timestamps are also printed in the export's own language; Czech
and English are understood, and an export in another language says so
and skips what it cannot date rather than guessing.

The one thing to know: **an older Facebook account is mostly not
Facebook**. Posts mirrored in from Twitter, Posterous and their era --
often the vast majority -- are recognized (by the platform name in
Facebook's own title line, and by the era's link shorteners) and
**skipped with a count**, because those platforms' own imports carry
the originals; importing them here would duplicate an entire Twitter
archive. `FACEBOOK_CROSSPOSTS=1` includes them for an account that
really lived on Facebook. Wordless check-ins and app stories are
skipped and counted too. Facebook's export has no post ids at all, so
re-import identity is minted from timestamp plus content -- stable
across re-exports.

### Ghost

```bash
ruby scripts/migrate_ghost.rb <export.json> <https://old-site.example>
```

In Ghost Admin: **Settings → Advanced → Import/Export → Export**. The JSON file is the whole database -- posts, pages, tags --
but **not the images**: they appear only as `__GHOST_URL__/...`
references, and the files themselves exist only on the live site. That is
why the site URL is a required second argument, and why the import has to
happen **while the old site is still up** -- afterwards there is nowhere
left to download from.

Every post comes over, drafts included. Posts Ghost had scheduled arrive
as drafts too, and the summary says how many: their publish times were a
promise made to a different site, and this one's queue should not
announce posts nobody here reviewed. Pages (about, contact, ...) arrive
as pages, and the summary lists the addresses they landed on. A page is
out of the listings, the archive and the feed, which is what a page is
for and also means nothing links to it: add the ones that belong in the
menu under `nav:` in `config/site.yml`. A custom excerpt becomes the
post's first paragraph, the feature image its first image. YouTube
embeds become the same video blocks a hand-written post gets; any other
embedded player becomes a link to the embedded page, which outlives the
player. Ghost's internal `#hashtag` tags are routing config, not
labels, and are dropped. The caption and the alt text written under a
feature image come over with it.

Members-only and paid posts import in full -- the export is yours, and
Ghost's paywall is applied when a page is served, never in the file --
but each one arrives as a **draft** tagged `ghost-members` rather than
published, and the summary says how many there were. Nothing your
members paid for goes onto the open web without you deciding it should.

### Instagram

```bash
ruby scripts/migrate_instagram.rb <path-to-unpacked-export>
```

In Instagram: **Accounts Center (or Meta Account settings -- Meta is
renaming it, and you may see either) → Your information and permissions
→ Export your information → Create export**. Ask for either format -- **HTML and JSON are
both read**, and the export says which one it is, so there is nothing to
choose here. Unpack the zip and point the script at the directory itself;
the photos and videos are in there, so this needs no network and no token.

The two are the same archive: on the account this was built against they
produce 288 identical posts, down to the slug and the tag list. Prefer
**JSON** if you are asked to pick, for one reason -- its timestamps are
epochs, where the HTML export prints a wall clock in a zone it never names
(see below). Importing one after the other is safe: they name their media
files differently but agree on the ids, so the second run overwrites the
first in place instead of doubling the archive.

Your grid and your IGTV videos are imported. Not imported, deliberately:
**archived posts**, which you removed from your own profile once already
and which an import would quietly put back; **profile photos**, which are
avatar history; and stories, likes and comments, which aren't posts. A
carousel becomes one image block per photo, which the build then renders as
a photo grid.

Captions lose their trailing hashtag lines -- lines at the caption's end
made of nothing but hashtags. That tail is already the post's tags, and
as prose it would be a wall of one-word links under every photo; a
hashtag inside a sentence is prose and stays where it was written.
Two things neither export contains, so neither does the import: **post
URLs** (`source.post_url` stays unset; a guessed one would 404 while
looking authoritative) and **alt text**. Neither states pixel sizes
either, so every file is measured on the way in; a file whose header can't
be read is named on stderr, because an image block without dimensions is
dropped from the rendered page. Re-import matching uses Instagram's own
media id, which both formats put at the end of every media filename.

What the JSON export costs instead: its text arrives as UTF-8 escaped one
byte at a time -- "Šťastné" as "Å¡Å¥astnÃ©" -- and is put back together on
the way in. Every alphabet with accents is in that trap, and so is every
emoji. It also ships a `posts.json` beside `posts_1.json`: the same grid
with the archived posts mixed back in (307 entries against 286), which is
why the import reads only the numbered files.

Captions are also normalised to NFC on the way in, both formats alike:
some of them were typed on a phone and arrive decomposed, with the accent
as a separate character. Nothing downstream minds -- slugs and the search
index fold through NFKD anyway -- but it means a caption that looks
identical to another one is also the same string, which is what a `grep`
over `content.nosync/` expects.

**Meta's HTML exports print their timestamps in fixed Pacific standard
time** -- -08:00 all year, no daylight-saving shift, no zone named --
and the import reads them as exactly that and stores them in
`site.timezone`; the same convention, and the same conversion, covers
Threads. The JSON path has none of this: an epoch means what it says.

That clock also prints its month names in the language the export was
requested in. Czech and English are understood -- the same tables the
Facebook and Threads imports use -- and an export in another language
names the token it cannot read and skips those posts, rather than
guessing at a calendar; a file none of whose posts could be dated says
so in one line instead of importing nothing in silence.

### Jekyll, Hugo, or any markdown folder

```bash
PERMALINK='/:year/:month/:day/:title/' ruby scripts/migrate_jekyll.rb <path-to-site-tree>
```

Point it at a Jekyll tree (`_posts/`, `_drafts/`), a Hugo content
directory, or **any folder of markdown files with front matter** -- the
output of converters like Meddler (Medium) or Substack2Markdown lands
here too. YAML and TOML front matter both read; the body is blog.sh's
own markdown and goes through the same parser authoring uses, so
nothing is lost to an HTML round-trip. `.html` bodies take the HTML
path instead. Liquid `{% highlight %}` becomes a code block; other
Liquid tags are dropped.

**Images come from the tree where the tree has them.** A root-relative
path resolves against the site root and a relative one against the post,
and neither needs the network: that half works for a site that died years
ago. An **absolute URL is downloaded** -- and a tree that came off a
hosted platform is mostly absolute URLs pointing back at it. So import
**while the old host still answers**, or pull the images down beside the
posts first and point the markdown at them; once that host is gone, those
images are gone with it. The run's summary is the only place that will say
so, because an image that never arrived leaves no block behind: the post
reads as though it never had one, and `./blog.sh check` afterwards finds
nothing to report. Read that number before you rebuild.

One thing a tree cannot tell you is its old URL shape: pass the
pattern (`PERMALINK='/:year/:month/:day/:title/'`, the wizard asks) to
keep permalinks; a post's explicit front matter `permalink` always
wins, and without either, no redirect is guessed at.

Pages count too: markdown in the root of the tree (`about.md`,
`colophon.md` -- where Jekyll keeps its pages) is read alongside
`_posts/` and `_drafts/`, minus the names that are never a page
(`index`, `404`, `feed`, `sitemap` and friends).

**A Hugo site root works as well as its `content/`.** Point the import
at the folder holding `hugo.toml` and `content/` and it reads the
content directory, leaving `layouts/`, `archetypes/` and the built copy
alone -- and says so in the summary, so nothing you keep outside
`content/` goes missing without a word. It holds whether or not the site
ever made a section: with a flat `content/`, the top of it is pages, the
same as with a dozen sections below. If you keep markdown of your own at
the top of the site folder (a `TODO.md`, a `NOTES.md`), the whole folder
is walked instead -- that file may be the tree you meant -- and the
summary names the file that decided it.

Hugo's section listings (`_index.md`, one per section, wherever they sit)
are the site's own furniture rather than posts, and are counted among the
skipped. A branch bundle is the exception the name cannot show: a
directory whose only markdown is its `_index.md` and which carries prose
or files of its own is a page written that way (`about/_index.md` with
its pictures beside it), and it is imported under the directory's name.

**A tree written by `./blog.sh export` comes back whole.** Its front
matter carries a `blogsh:` block -- the post's identity and everything
else no other engine has a word for -- and this importer reads it back,
which makes export + import the supported way to move an installation
between machines or hosts; such a post is coming home, so it collects no
platform tag. The first round does normalise formatting spans markdown
has no way to write -- two identical link spans over the same text, a
span cut at a link's boundary, the order of spans covering the same run
-- into one canonical shape; the visible text does not change. The
mechanics, and the little that is deliberately lost,
live in [architecture.md → Exporting](architecture.md#exporting-libexporterrb).

The pattern understands `:year`, `:month`, `:day`, `:title` and
`:slug`, and nothing else -- anything further is left in the address
exactly as you typed it. That matters because copying Jekyll's own
default out of `_config.yml` is the natural thing to do, and
`/:categories/:year/:month/:day/:title.html` would put a literal
`/:categories/` in front of every redirect. Check one post's
`redirect_from` after the preview before letting the run write.

### LiveJournal

```bash
LJ_PASSWORD=... ruby scripts/migrate_livejournal.rb <username>
```

LiveJournal has no export file, so the import reads the account's own
XML-RPC API -- which is why it needs the password (in `env.sh`, like
the other credentials). It never travels in plaintext: every call sends
only a challenge-response digest. Entries come over with their tags;
`<lj user>` mentions become the links they meant, the `<lj-cut>` fold
disappears (an archive has no fold -- the content behind it stays),
and the plain-text bodies LJ used to auto-format get their paragraphs
back.

**Friends-only and private entries arrive as drafts**, counted in the
summary: they were never public, and a static site has no lock to put
them behind. Comments stay behind entirely. The API rate-limits
enthusiasm; a long journal may pause, and re-running picks up safely.
Kept permalinks use the API's own address for each entry -- the number
in an LJ URL is not the internal id, so it is never reconstructed,
only read.

### Mastodon

```bash
ruby scripts/migrate_mastodon.rb <path-to-unpacked-archive>
```

In Mastodon: **Settings → Import and export → Request your archive**, then
unpack the zip. The archive holds an ActivityPub outbox *and the media
files themselves*, so this import needs no network and no token, and it
covers the whole account -- on a typical one, most items are skipped as
replies and boosts (2984 and 1059 of 6591 in the archive this was built
against). A content warning becomes the post's title. Attachment dimensions
come from the archive's own metadata, and audio attachments become audio
blocks with a native player.

### Medium

```bash
ruby scripts/migrate_medium.rb <path-to-unpacked-export>
```

In Medium: **Settings → Security and apps → Download your information**.
Unpack the ZIP and point the script at the directory itself -- the one
holding `posts/`. Each post is a self-contained HTML file; the importer
reads the metadata Medium hides in it (title, date, canonical URL, tags)
and strips what Medium bakes into every body: the title repeated as a
heading, the subtitle repeated below it, the opening divider. The
subtitle becomes the post's first paragraph; bookmark cards keep their
durable part, the link.

**The images are not in the export** -- they download from Medium's CDN,
which works for as long as Medium serves them. Import sooner rather than
later.

Medium's export cannot tell your articles from responses you wrote under
other people's -- both are just files. A published one-paragraph body
with no image is almost never an article, so those import as **drafts
for review**, counted in the summary: a wrong guess costs a look, not a
lost text. Newer exports carry no tags at all; the summary says how many
posts arrived bare.

### Movable Type / TypePad

```bash
URL_PATTERN='/%Y/%m/{basename}.html' ruby scripts/migrate_movabletype.rb <mt-export.txt>
```

The MT Import Format file -- Tools → Export in Movable Type, and the
export TypePad produces to this day; gzipped files read transparently.
Posts and drafts come over with categories and keywords as tags; the
comments and trackbacks the file also holds are counted and left
behind, a static archive having nowhere to put them. Bodies written as
plain text (`CONVERT BREAKS`) get their paragraphs back before parsing.

Two things the format simply lacks, and what stands in for them: **no
post ids** (the re-import identity is minted from date + basename,
stable across re-exports) and **no URLs** -- kept permalinks take a
pattern (`URL_PATTERN='/%Y/%m/{basename}.html'`, strftime parts plus
`{basename}`), and a TypePad `UNIQUE URL:` line, where present, always
wins over it. TypePad has been known to shorten basenames in real
URLs, so spot-check a few redirects against the old site.

**Decide about the pattern before the first run.** The host in
`URL_PATTERN` is part of a post's re-import identity here, not just a
source of addresses -- so importing once without it and again with it
does not update those posts, it writes the archive a second time. If you
have already done that, see *Undoing an import* below.

### Pixelfed

```bash
ruby scripts/migrate_pixelfed.rb "<path-to-Pixelfed Statuses.json>"
```

In Pixelfed: **Settings → Data Export**, take the *Statuses* JSON. Unlike
Mastodon's archive it links to the CDN instead of shipping files, so photos
are downloaded; real pixel sizes come from the export's metadata. Trailing
hashtag-only lines are dropped from captions -- they are already the post's
tags, and would otherwise render as a stack of one-word paragraphs. Replies
and reblogs are skipped and counted.

### Podcast

```bash
ruby scripts/migrate_podcast.rb <feed-url | export.xml>
```

Any podcast RSS feed works -- Libsyn, Buzzsprout, Anchor, anything whose
items carry an enclosure, audio or video. A bare `<show>.libsyn.com` URL is
expanded to the metadata-carrying feed automatically. Each episode
becomes a post: artwork, then the episode itself -- audio as a native
player, video as video -- then the shownotes. **The file downloads and is
hosted locally** -- the
archive has to outlive the hosting account, which is usually why anyone
migrates a podcast -- and the preview's size note says what that means
in gigabytes before anything is written, because a long-running show
means real disk. Items without an enclosure (blog posts syndicated into
the same feed) are skipped and counted.

No redirects here: on Libsyn the feed's per-episode link points at the
mp3 itself, not at an episode page, so there is no original address to
keep -- a guessed one would 404 with a straight face.

### Squarespace

```bash
ruby scripts/migrate_squarespace.rb <squarespace-export.xml>
```

In Squarespace: **Settings → Import/Export → Export**, pick "WordPress
format". It is almost a WordPress export, and everything a WXR import
does applies -- pages arrive as pages, attachments counted as skips, drafts as
drafts. The differences are all in what a plain parse would silently
lose, and the importer restores each: image URLs hidden in `data-src`,
audio players that are just a `<div>` with data attributes (they become
native audio blocks with the file downloaded -- better than the
original hotlink), video embeds stored as escaped markup in an
attribute (YouTube becomes a video block, other players a link), and
the post's feature image, which the export ships as a separate
attachment item right after the post.

The media is not in the file -- everything downloads from Squarespace's
CDN, so import while the old site is still up. Kept permalinks record
the `/blog/<slug>` paths from the export itself.

The not-quite-XML repair described under
[WordPress](#wordpress-or-any-rssatom-feed) applies here too -- a bare `&`
printed into a `<title>` is the Squarespace case it was written for.

### Substack

```bash
ruby scripts/migrate_substack.rb <path-to-unpacked-export> [site-url]
```

In Substack: **Settings → Exports → Create new export**. Unpack the ZIP
and point the script at the directory itself -- the one holding
`posts.csv` and `posts/`. The site URL is optional: the `/p/<slug>`
paths that redirects need come straight out of the export, the domain
only adds each post's full address for the record.

Newsletters and podcasts come over, drafts included; a podcast episode's
mp3 downloads and leads the post as an audio block. **Paid posts import
in full** -- the export is the author's, so it carries the complete
text, and the paywall marker is simply removed. The subtitle becomes the
post's first paragraph. A page arrives as a page (it keeps its /p/
address as a redirect, which is where Substack served it); threads are
skipped and counted.

Two honest gaps, both the export's: **tags don't exist in it** (Substack
keeps them only on the live site -- posts arrive with just the platform
tag), and the newest posts sometimes ship as CSV rows with no HTML body
-- those are skipped and counted rather than imported empty.

### Threads

```bash
ruby scripts/migrate_threads.rb <path-to-unpacked-export>
```

In Threads: **Accounts Center → Your information and permissions →
Export your information**, and note that Meta does not offer this on a
computer at all -- it has to be done in the mobile app or a mobile
browser, which is where people get stuck without being told why. Either
format -- **HTML and JSON are both read**, and the export says which
one it is. Unpack the ZIP and point the script at the directory. Your
own standalone posts import with their media from the archive;
**replies to other people's threads are skipped and counted** -- the
same rule as Bluesky and Twitter, an archive holds your own posts.
Bare URLs in the text become real links, and Meta's mangled encoding
is repaired the same way as for Facebook and Instagram.

JSON is the better ask if you have replies to keep out: only it marks
them, so the HTML page imports every box it holds -- and an HTML run
says so when it finishes, every time, since it cannot know whether
there was anything to miss. HTML timestamps are printed to the minute
in Meta's fixed Pacific clock -- see [Instagram](#instagram) for the
rule and the conversion -- and a re-import should stick to whichever
format the first import used, since the lost seconds mean the two
formats mint different identities for text-only posts.

One flag the export carries deserves a word: `cross_post_source` is
NOT treated as "this came from elsewhere" -- on real exports it sits
on posts written directly in the Threads app too, recording where a
post was *shared to*. Nothing is skipped because of it.

### Tumblr

```bash
TUMBLR_API_KEY=... ruby scripts/migrate_tumblr.rb yourname.tumblr.com
```

Get a key at tumblr.com/oauth/apps (the API requires one even for public
blogs) and keep it in `env.sh`. Every post the key can reach is imported,
which means the published ones: drafts, the queue and private posts live
behind endpoints that want a full OAuth handshake, so an import cannot
see them. Reblogged content from the trail comes with your own, each part
credited to the blog it came from; the question in an ask post arrives as a
quote with the asker's name under it (an anonymous one as a quote with no
name, which is all Tumblr records), so neither ever reads as your own
words. Audio posts arrive as players (a self-hosted file is downloaded,
a SoundCloud/Spotify embed stays an embed). All media is downloaded; an import of a few thousand posts runs for
hours, so sample with `LIMIT` first. A wrong key or blog name aborts with
the API's reason instead of a stack trace.

### Twitter/X

```bash
ruby scripts/migrate_twitter.rb <path-to-extracted-export>
```

Request the archive in X settings, extract the zip, point the script at the
directory (it must contain `data/tweets.js`). Standalone tweets only:
replies, old-style `RT @` retweets and quote-tweets are skipped and counted.
Since the export carries no explicit quote flag, a quote is recognised by an
embedded status link -- which deliberately also skips a tweet that merely
links to another tweet. Media is copied from the export itself, no network.
t.co links come out as their readable targets.

### Wayback Machine — rescuing a dead blog

```bash
ruby scripts/migrate_wayback.rb <https://dead-blog.example>
```

For the blog whose platform no longer exists -- blog.cz, Posterous, a
deleted account anywhere. The trick is that the Internet Archive
crawled the blog's **feed** again and again over the years, and each
capture carries the posts of its day: reading every distinct capture
oldest-first reassembles the history, with the usual re-import
matching merging the overlaps. Point it at the blog's old URL (the
common feed paths are tried) or straight at its feed; images recover
from the Archive the same way, rerouted to the nearest capture.

A blog the Archive only ever saw as pages -- no feed captures -- falls
through to **page mode**: every archived post page, the newest capture
of each. Which paths are posts is the one thing pages cannot say about
themselves, so a **platform pack** answers it for platforms one was
written for, `POST_PATTERN` answers it anywhere else, and with neither
the run refuses and prints sample paths to build a pattern from. Two
packs ship built in: **blog.cz** (`/YYMM/slug` paths, the article
markup, Czech long-form dates), picked automatically by host, and
**b2evolution** -- the self-hosted workhorse of the 2003--2010
blogosphere, which lived on anyone's domain, so it is recognized by
its markup instead: when neither host nor pattern says anything, one
archived page is fetched and sniffed for the stock `bText` template or
the generator meta. `WAYBACK_PACK=b2evolution` names it outright.
b2evolution's numeric dates are `y/m/d` with a two-digit year (taken
from the template source -- a rendered `08/12/07` cannot say which
order it means); installs with query-string permalinks (`?p=123`)
still need `POST_PATTERN`. `WAYBACK_MODE=pages` skips the feed attempt
outright. Pages that refuse to parse as posts are skipped and counted
(`unparsed`); posts whose page names no date carry their capture date,
also counted.

Every one of these variables works for `./import.sh` too, not only for
the script: the wizard reads the same environment, so advice a run prints
about `WAYBACK_DELAY` or `POST_PATTERN` can be followed by starting the
wizard again with the variable set. The one exception is `KEEP_PERMALINKS`
below -- the wizard asks that as a question and the question's answer
wins, because recording the dead blog's paths is irreversible in a way a
pace or a pattern is not.

Kept permalinks (`KEEP_PERMALINKS=1`, or the wizard's question) record
the dead blog's own paths -- the feed item's link in feed mode, the
archived page's address in page mode.

A rescue can also be limited to a stretch of time, the way the
Archive's own site lets you pick a year and a month: `WAYBACK_FROM` and
`WAYBACK_TO` take `2013`, `2013-01` or `2013-01-15`, and a date the
importer cannot read aborts the run rather than quietly meaning
"everything" -- a window dropped in silence would read as a blog the
Archive never captured.

```bash
WAYBACK_FROM=2013-01 WAYBACK_TO=2013-06 ruby scripts/migrate_wayback.rb <url>
```

The window filters CAPTURES, not posts: what the feed had already
dropped before the window opens is missing from the run, not from the
blog, and the summary says the run was windowed. Reading stays
oldest-first inside it; the image survey ignores the window on purpose
-- it is the map you pick the window from.

Honesty is the whole design here. The Archive only has what its
crawler met: posts it never saw stay lost, images it never saved are
dropped and **counted** (it answers a missing image with an HTML page
and a straight-faced 200 -- anything that doesn't measure as an image
is treated as lost, not saved broken). The Archive is also slow the
way a library is slow -- one request per second (`WAYBACK_DELAY` to go
gentler), so a long history takes minutes and narrates its progress.

### Wix

```bash
ruby scripts/migrate_wix.rb <posts.csv>
```

In the Wix admin: export the blog as CSV. Post bodies arrive as Wix's
rich-content JSON, which converts to blocks more directly than HTML
ever would -- paragraphs with their bold/italic/link spans, headings,
lists, tables, dividers, buttons as links. Whatever has no blog.sh
equivalent (video, galleries, polls) is **counted by name** in the
summary rather than silently dropped. The cover image leads the post.

The export carries no files -- images download from Wix's CDN by their
id, so import while the old site is still up. A post with no published
date is a draft (Wix has no explicit status column), and category cells
that hold Wix's internal 24-hex ids instead of names are dropped: an id
makes no tag anyone would click. Kept permalinks come straight from the
export's own Post Page URL column.

### WordPress, or any RSS/Atom feed

```bash
ruby scripts/migrate_feed.rb <export.xml | feed-url>
```

One command for both, because a WordPress WXR export *is* RSS 2.0 with
extra elements -- the file itself says which it is. The difference that
matters: **a public feed carries only its last few dozen items; a WXR file
is the complete archive.** For WordPress, always export: **Tools → Export →
All content**.

From a WXR: posts and pages are imported (attachments and menu items are
counted separately -- in a stock export they outnumber the posts), the slug
the site already published under is kept, `publish` stays published and
`draft`/`pending`/`private`/`future` become drafts, trashed items are
skipped. Post bodies arrive as HTML and are converted to content blocks in
the conservative subset the schema supports; what the conversion cannot
keep is dropped **and counted**, as everywhere. Images referenced in the
markup are downloaded and measured.

**A file that is very nearly XML is read anyway.** Exports are printed by
templating engines, not by XML writers, so a raw query string left inside an
element or a bare `&` in a title is ordinary -- and it makes a conforming
parser refuse the entire archive over one character. Four of the twelve
fixtures that Ghost's own migration tools ship are refused this way. Only
characters that had to be escaped and were not are repaired, never structure
and never inside a post body (where `&` is already an ordinary character),
and the summary says how many. A file with a real defect -- a missing end
tag, a download that stopped halfway -- still fails, and the refusal names
*that* rather than the ampersand it just proved it can handle.

## Checking the result

The preview already told you the counts; after the real run, spot-check the
built pages (`./blog.sh preview`), and remember two date rules: imported
posts keep their original dates, so they land in the archive rather than on
the homepage, and dates a reader sees render in `site.timezone` -- set it
before importing if the machine's clock isn't in your zone (see
[install.md](install.md#2-configure-the-site----configsiteyml)).

Then run **`./blog.sh check`** ([operations.md → Checking the
archive](operations.md#checking-the-archive)), because a body's own links
came across exactly as they were written. Where they point at your old
posts that is right: with `KEEP_PERMALINKS` the import wrote a redirect at
each of those addresses, so they answer here too and `check` accepts them.
Where they point at the old platform's own furniture it is not -- a
WordPress archive still carries `/wp-admin/...`, `/wp-content/...`,
`/category/...` and `/feed/` inside its post bodies, and after the move
those paths address the new site, which has nothing there. `check` names
every one with its post ("links to X, which nothing on this site answers
at"); on a blog that linked to itself a lot there will be dozens, and each
is a decision -- rewrite it, drop it, or point it at the Wayback capture.

Announcements are **not** sent for imported posts -- the auto-toot has a
24-hour recency window, and imported dates are far outside it. That's the
designed behavior: an import should never spam your followers with a
thousand-post flood.

## Undoing an import

Select on the source triple, never on "everything except what I wrote":

```bash
ruby -rjson -rfileutils -e '
n = 0
Dir.glob("content.nosync/posts/*/*.json").each do |f|
  p = JSON.parse(File.read(f, encoding: "utf-8"))
  s = p["source"] || {}
  next unless s["platform"] == "PLATFORM" && s["account"] == "ACCOUNT"
  d = File.join("media.nosync", File.basename(File.dirname(f)), p["slug"])
  FileUtils.rm_rf(d) if Dir.exist?(d)
  File.delete(f); n += 1
end
puts "removed #{n}"'
```

Fill in `PLATFORM`/`ACCOUNT` from any imported post's JSON, then rebuild and
deploy with `--prune --force` (the guard will flag the shrink -- that's it
working). The same selector is why re-importing later is safe.

## Troubleshooting

| Symptom | What it means |
| --- | --- |
| `N media file(s) could not be downloaded` | The URLs are dead at the source -- old CDNs disappear (every `distilleryimage*.instagram.com` link from 2012 resolves to nothing). The posts were written without those images; nothing to fix on your side. |
| `Tumblr API returned 401 Unauthorized` | Wrong `TUMBLR_API_KEY` or blog name. |
| Many `skipped (not a post)` from a WXR | Normal -- WordPress's own menu items and revisions travel in the same export. Attachments and pages have their own lines, and so does every custom post type, named after itself (`wp:portfolio`) -- if you recognize one of those as a section of your blog, its posts stayed behind. |
| `skipped (error)` with stderr lines | Those items were malformed at the source; the rest imported. Re-run after a fix overwrites in place. |
| `The source stopped answering after N item(s)` | The platform died mid-run. Everything written so far is saved; re-run once the source recovers -- posts are matched on their source id, so nothing duplicates. |
| `cannot move '<slug>' into <year>: a different post already owns ...` | A re-imported item's date moved into a year where another post has the same slug. That one item is skipped, nothing was touched; rename one of the slugs and re-run. |
| The same id-less post appears twice after a re-import | The item carries neither `guid` nor `link`, so it can't be matched. Delete the extra copy; better, give the item a `guid` at the source. |
| The deploy stops with a % increase warning | The guard doing its job after a bulk change -- re-run with `--force` once the numbers look right. |
| An imported post shows a shifted date | `site.timezone` wasn't set and the machine runs UTC -- set it and rebuild; stored dates don't change, only the rendered day. |
