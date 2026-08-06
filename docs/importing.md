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
- **A re-import updates, never duplicates.** Posts are matched on their
  source identity -- platform, account and the item's own id -- not on the
  title, so fixing a typo at the source and importing again updates the
  existing post in place, keeping its slug and URL. The one exception is an
  item with no usable identity (a plain RSS item with neither `guid` nor
  `link`): rather than guess and risk merging two different posts, a
  re-import writes it again -- a duplicate you can delete, where a wrong
  match would destroy a post you can't get back.
- **Origin becomes a tag.** Every imported post is tagged with its platform
  (`tumblr`, `wordpress`, ...; for a plain feed, the site's domain), so
  `/tag/tumblr/` is the whole of one old blog. Deduplicated
  case-insensitively against the post's own tags.
- **One bad item costs one item.** A date that won't parse or markup nothing
  anticipated is counted under `error` and named on stderr; the run
  continues. A rejected API key still stops everything, as it should.
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
  same domain the old blog did, sources that know their original URLs
  (Ghost, Substack, WordPress/feed and Tumblr today) can record each
  published post's old path as `redirect_from` -- the build then serves a redirect at every one
  of them, so nothing anyone ever linked goes dark. The wizard asks; the
  scripts take `KEEP_PERMALINKS=1`. Say yes only on the same domain: on any
  other, the old paths were never yours to answer. Posts with no usable
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

### Ghost

```bash
ruby scripts/migrate_ghost.rb <export.json> <https://old-site.example>
```

In Ghost Admin: **Settings → Advanced → Import/Export → Export your
content**. The JSON file is the whole database -- posts, pages, tags --
but **not the images**: they appear only as `__GHOST_URL__/...`
references, and the files themselves exist only on the live site. That is
why the site URL is a required second argument, and why the import has to
happen **while the old site is still up** -- afterwards there is nowhere
left to download from.

Every post comes over, drafts included. Posts Ghost had scheduled arrive
as drafts too, and the summary says how many: their publish times were a
promise made to a different site, and this one's queue should not
announce posts nobody here reviewed. Pages (about, contact, ...) are
skipped and counted -- they are site furniture, not timeline entries. A
custom excerpt becomes the post's first paragraph, the feature image its
first image. YouTube embeds become the same video blocks a hand-written
post gets; any other embedded player becomes a link to the embedded page,
which outlives the player. Ghost's internal `#hashtag` tags are routing
config, not labels, and are dropped.

### Instagram

```bash
ruby scripts/migrate_instagram.rb <path-to-unpacked-export>
```

In Instagram: **Accounts Centre → Your information and permissions →
Download your information**. Ask for either format -- **HTML and JSON are
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

Captions lose their trailing hashtags -- the tail is already the post's
tags, and as prose it would be a wall of one-word links under every photo.
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

**The HTML export's timestamps are Pacific standard time, all year.** It
prints them without a zone and in Meta's own, so they are read as -08:00
and stored in `site.timezone`. Taken at face value instead, an archive
comes out shifted by most of a day: the export this was built against
showed a six-hour hole across every afternoon and 106 of 286 posts between
midnight and 6am, which after conversion became peaks at 10am and 8pm --
someone posting after the morning and the evening walk.

Note *standard* time, not the `America/Los_Angeles` zone, which is the
obvious reading and is wrong: the export does not shift for daylight
saving, so treating a July post as PDT puts it an hour early. That one was
only findable by importing the same account both ways -- 173 of 288 posts,
exactly those falling in Pacific daylight-saving months, disagreed by
exactly an hour, and the JSON export's epochs settled which side was
right. The JSON path has none of this: an epoch means what it says.

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

### Substack

```bash
ruby scripts/migrate_substack.rb <path-to-unpacked-export> [site-url]
```

In Substack: **Settings → Exports → Export your data**. Unpack the ZIP
and point the script at the directory itself -- the one holding
`posts.csv` and `posts/`. The site URL is optional: the `/p/<slug>`
paths that redirects need come straight out of the export, the domain
only adds each post's full address for the record.

Newsletters and podcasts come over, drafts included; a podcast episode's
mp3 downloads and leads the post as an audio block. **Paid posts import
in full** -- the export is the author's, so it carries the complete
text, and the paywall marker is simply removed. The subtitle becomes the
post's first paragraph. Threads and pages are skipped and counted.

Two honest gaps, both the export's: **tags don't exist in it** (Substack
keeps them only on the live site -- posts arrive with just the platform
tag), and the newest posts sometimes ship as CSV rows with no HTML body
-- those are skipped and counted rather than imported empty.

### Tumblr

```bash
TUMBLR_API_KEY=... ruby scripts/migrate_tumblr.rb yourname.tumblr.com
```

Get a key at tumblr.com/oauth/apps (the API requires one even for public
blogs) and keep it in `env.sh`. Every post on the blog is imported --
drafts stay drafts, reblogged content from the trail is appended to your
own, and audio posts arrive as players (a self-hosted file is downloaded,
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

### WordPress, or any RSS/Atom feed

```bash
ruby scripts/migrate_feed.rb <export.xml | feed-url>
```

One command for both, because a WordPress WXR export *is* RSS 2.0 with
extra elements -- the file itself says which it is. The difference that
matters: **a public feed carries only its last few dozen items; a WXR file
is the complete archive.** For WordPress, always export: **Tools → Export →
All content**.

From a WXR: only posts are imported (pages, attachments and menu items are
counted separately -- in a stock export they outnumber the posts), the slug
the site already published under is kept, `publish` stays published and
`draft`/`pending`/`private`/`future` become drafts, trashed items are
skipped. Post bodies arrive as HTML and are converted to content blocks in
the conservative subset the schema supports; anything with no representable
shape (an iframe, an embedded player, a form) is dropped **and counted**,
so the summary names what it couldn't keep. Images referenced in the markup
are downloaded and measured.

## Checking the result

The preview already told you the counts; after the real run, spot-check the
built pages (`./blog.sh preview`), and remember two date rules: imported
posts keep their original dates, so they land in the archive rather than on
the homepage, and dates a reader sees render in `site.timezone` -- set it
before importing if the machine's clock isn't in your zone (see
[install.md](install.md#2-configure-the-site----configsiteyml)).

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
| Many `skipped (not a post)` from a WXR | Normal -- menu items, attachments and pages travel in the same export. |
| `skipped (error)` with stderr lines | Those items were malformed at the source; the rest imported. Re-run after a fix overwrites in place. |
| `The source stopped answering after N item(s)` | The platform died mid-run. Everything written so far is saved; re-run once the source recovers -- posts are matched on their source id, so nothing duplicates. |
| `cannot move '<slug>' into <year>: a different post already owns ...` | A re-imported item's date moved into a year where another post has the same slug. That one item is skipped, nothing was touched; rename one of the slugs and re-run. |
| The same id-less post appears twice after a re-import | The item carries neither `guid` nor `link`, so it can't be matched. Delete the extra copy; better, give the item a `guid` at the source. |
| The deploy stops with a % increase warning | The guard doing its job after a bulk change -- re-run with `--force` once the numbers look right. |
| An imported post shows a shifted date | `site.timezone` wasn't set and the machine runs UTC -- set it and rebuild; stored dates don't change, only the rendered day. |
