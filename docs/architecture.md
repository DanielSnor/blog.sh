# Architecture

How the engine works inside -- one page, following a post's life from
keystroke to visitor. The *why* behind these shapes lives in
[decisions.md](decisions.md).

## The system in one line

```
$EDITOR (markdown) → CLI parse → JSON blocks → build (ERB) → static HTML → deploy backend → host
                                      ↑                                        ↑
                            importers target the                      cron refreshes widget
                            same schema                               JSON + post stats
```

## Content model

One post = one JSON file at `content.nosync/posts/<year>/<slug>.json`:

- `slug`, `title`, `date` (ISO 8601), `tags`, `state`
  (`published`/`draft`), `source` (which platform it came from),
  optionally `mastodon_url` (its comment toot), `draft_token` and
  `created_at` (drafts), `type` (explicit content type override).
- `content` is an array of **typed blocks**: `text` (with `subtype`
  heading1-6/quote), `list`, `table`, `code`, `image`, `video`, `audio`,
  `file`,
  `link`, `chat`, `hr`.
- Inline formatting (bold/italic/strikethrough/code/link) is stored as
  **codepoint offset ranges into plain text**, not nested HTML -- the
  same NPF-style shape Tumblr's API uses, which is what the importers
  naturally produce.
- Media lives next to its post in `media.nosync/<year>/<slug>/`,
  referenced by bare filename; nothing is ever hotlinked.

Everything that walks those directories walks them through
`lib/path_glob.rb`. `Dir.glob` reads its whole argument as a pattern, and
the installation's own absolute path used to be the first half of it -- so
an install in `~/Sites/blog [1]` had `[1]` read as a character class, every
listing came back empty, and `build` reported an empty archive without
naming a path. `PathGlob.under(dir, '*', '*.json')` passes the directory as
`base:`, which `Dir.glob` never parses, and re-joins the results, so callers
keep the absolute paths and the order they always had. The pattern half
stays a pattern: a slug, a filename or a typed directory that lands there
goes through `PathGlob.literal` first, which escapes the metacharacters so
the name stands for itself.

### Field reference

The authoritative schema for anyone writing an importer -- new
importers should produce exactly this and write it through
`PostWriter.write` (which handles slug uniqueness and re-import
dedup by `source`).

**Post object:**

| Field | Type | Notes |
| --- | --- | --- |
| `slug` | string, required | URL segment; `Slug.slugify` output |
| `date` | string, required | ISO 8601 with offset |
| `content` | array, required | blocks, see below |
| `title` | string | optional. A post without one borrows the title of its first `link` block -- that is where a link post keeps what the reader takes for its title, and it becomes the heading (an `h1` on the post's page, an `h2` in a listing, both pointing where the link points), the `<title>`, the feed item and the structured data. With neither, the slug stands in |
| `tags` | array of strings | rendered as pills, slugified for tag URLs |
| `state` | `"published"` \| `"draft"` | absent = published |
| `draft_token` | string | drafts only -- the hidden preview URL segment |
| `created_at` | string | drafts only -- publish-time "was the date edited?" check |
| `type` | string | explicit dominant content type; absent = derived from blocks. `type: page` belongs in FRONT MATTER only: what a stored post carries is `page: true`, and nothing reads `type` when deciding where a post is served |
| `source` | object | `platform` plus optionally `account`, `original_id` -- the re-import dedup key |
| `mastodon_url` | string | the post's comment toot (Mastodon sites), set on publish/`toot` |
| `bluesky_url` | string | the announcement's human link (Bluesky sites), set on publish/`bluesky` |
| `bluesky_uri` | string | the announcement's `at://` URI -- what the thread API takes; stored alongside the URL because converting between them needs a handle→DID resolution round-trip |
| `former_slugs` | array of strings | every address the post used to have, as `"year/slug"` frozen at rename time; the build emits a redirect stub for each (see `props` → rename). Engine-side history like the announcement URLs: edits and re-imports carry it over untouched |
| `unpublished_from` | string | drafts only -- the `"year/slug"` address the post vacated when it was unpublished. Publishing consumes it: back under a different slug it becomes a `former_slugs` redirect, back under the same one it just disappears |
| `series` | string | the series this post belongs to; with two or more published parts the build gives it a listing at `/series/<slug>/` and puts "part 2 of 5" navigation on the post |
| `series_part` | integer | position within the series -- without it, parts are ordered by date, which is the usual case; the number is for the rare insert |
| `pinned` | string/boolean | one post held at the top of the front page. Truth test is strict (`true`/`yes`/`1`), so a hand-edited `false` cannot pin by accident; more than one pinned post warns and the newest wins. Listings past page one, the archives and the feeds ignore it |
| `toc` | string/boolean | table of contents on the post page. Absent = automatic (from 4 headings up); an explicit false suppresses it, an explicit true forces it below that threshold |
| `hero` | string/boolean | whether the first non-degenerate image runs full width above the post. Absent = whatever `layout.hero` says for the whole site |
| `scheduled` | boolean | set on a draft whose `date` is its future publish time; the `publish-scheduled` cron publishes it then and drops the key |
| `unlisted` | string/boolean | a published post out of the listings, the archives, the feeds, the sitemap and the search index, `noindex` on its page -- but on its ordinary dated address, with its redirects intact. Not a password (see [decisions.md](decisions.md)); the truth test is loose, so a typo hides rather than exposes |
| `page` | boolean | a page rather than a post: a permanent address (`/<slug>/`), out of the listings, the archives and the feed, but in the sitemap and the search index. Written as `type: page` in front matter; `page: true` is the older spelling and is still read |
| `redirect_from` | array of strings | site-root paths the post answered at on its PREVIOUS platform (`"/old-post/"`, `"/2009/05/old-post.html"`), written by importers when the new site keeps the old domain. The build emits a redirect stub for each, after everything real -- a live page, listing or site file always wins over a stub, out loud. Deliberately separate from `former_slugs`: that is rename history inside this site, this is where the post lived before it arrived. Paths ending `.html`/`.htm` become literal files (Blogger-era URLs had no trailing slash); first segments the site itself owns (`posts`, `page`, `tag`, `type`, `assets`, `search`, `markdown`) are refused. Published posts only; edits and re-imports carry it over untouched |

**Blocks** (`content` array entries), by `type`:

| `type` | Fields |
| --- | --- |
| `text` | `text`; `subtype` (`heading1`-`heading6`, `quote`; absent = paragraph); `formatting`; a quote may carry `cite` (attribution, rendered as a right-aligned line) |
| `list` | `style` (`"ul"`/`"ol"`); `items` -- each `{text, formatting?, children?}` where `children` is a nested list block |
| `table` | `align` (array of `left`/`center`/`right`); `header` (array of cells, **absent when the table has none** -- written as a table opening with the separator row, rendered without a `<thead>`); `rows` (array of cell arrays); a cell is `{text, formatting?}` |
| `code` | `text` (verbatim, blank lines preserved); `lang` (cosmetic) |
| `chat` | `lines` -- array of `{name, text}`; `name` may be nil for a continuation line |
| `hr` | no fields |
| `image` | `media` (see below); `alt_text`; `caption` |
| `file` | `media` (`url`, `size` in bytes); `label` -- an attachment offered for download; the post's type becomes `document` when its text is caption-short |
| `video` | one of four shapes: local file -- `media` (+ optional imported `poster`, same shape) and `caption` (the authoring CLI requires it); YouTube -- `provider: "youtube"`, `url`, `youtube_id`, `caption`; another platform the address alone identifies (Vimeo, PeerTube, archive.org) -- `provider`, `url`, `embed_id` (+ `embed_hash` for an unlisted Vimeo, `embed_origin` for the PeerTube instance), see `lib/embed.rb`; imported embed -- `embed_html` (+ `provider`, `url`). A `url` alone renders as a polite "video unavailable" notice |
| `audio` | local file -- `media` (first entry's `url`, no dimensions needed) and `caption`; a platform the address identifies (Spotify, SoundCloud, Mixcloud) -- `provider`, `url` and, where there is one, `embed_id`/`embed_kind`, see `lib/embed.rb`; a platform that had to be asked (Funkwhale, Bandcamp) -- `provider`, `url`, `embed_src` resolved once at save time by `lib/embed_lookup.rb` (+ `embed_origin` for the Funkwhale instance); imported embed -- `embed_html` (+ `provider`, `url`). A `url` alone renders a polite "audio unavailable" notice |
| `link` | `url`; `title`; `description`. On a post with no title of its own the FIRST such block lends its title to the post (see `title` above) and then renders without it, leaving the description; anywhere else -- a titled post quoting a link mid-article, or a second link block -- it renders in full as a link card |

An unrecognized `type` renders as its raw JSON in a `<pre>` -- loud,
not silent.

**`media`** is an array whose first entry is used: `{url, width,
height}`. `url` is a bare filename inside the post's
`media.nosync/<year>/<slug>/` directory; `width`/`height` reserve
layout space and should be there for every image -- without them the
browser has nothing to hold the space with and the page jumps as the
picture arrives. Only a real 1x1 is treated as degenerate and dropped
from rendering: that is the tracking pixel the rule exists for, and an
image of unknown size is shown rather than thrown away, because a
picture somebody put in a post is not the engine's to discard over a
missing number. The CLI reads the dimensions from PNG/JPEG/MP4 headers,
and an importer should supply them too.

**`formatting`** is a flat array of `{type, start, end}` spans over the
block's plain `text` -- offsets are **Unicode codepoints** (Ruby string
indexing), `end` exclusive; spans may nest and overlap, and shorter
spans render innermost. Span types the authoring CLI produces: `bold`,
`italic`, `strikethrough`, `code`, `link` (`url` + optional `title`).
Additionally accepted from imports: `small`, `mention` (`blog.url`),
`color` (`hex`).

## The markdown round-trip

Markdown exists only at the editing boundary; storage and build never
see it:

- **`lib/markdown_parser.rb`** (text → blocks) parses the author's
  markdown once, at save time. The `/markdown/` cheat-sheet page is
  generated through this same parser, so the documented syntax can't
  drift from the implemented one.
- **`lib/markdown_writer.rb`** (blocks → markdown) is the mirror: it
  renders a stored post back into editable markdown for `blog.sh edit`.
  The output is always re-parseable, though ties between overlapping
  formatting spans may come out normalized. Content markdown can't
  express (imported embeds, link cards) is protected by a count-based
  loss check in the CLI before saving.
- The count-based check compares block types, so it sees a block that
  disappeared but not an attribute that did. Where an attribute has no
  markdown form and cannot be re-typed by the author -- a video's imported
  `poster` -- the CLI carries it over from the stored post instead,
  matching on the video's file or URL. Anything added to a block that
  markdown cannot write down needs the same treatment.
- The importers write the same schema through the shared
  `lib/post_writer.rb`, so an imported post and a hand-written one are
  indistinguishable downstream.

## Undoing an edit (`lib/post_versions.rb`)

Deleting a post was always reversible -- it goes to `trash/` and `restore`
brings it back -- but editing one was not, and editing is what happens
every day: a paragraph dropped and saved, a round-trip through markdown
that could not express something, a paste into the wrong place. So the
post as it stood is copied aside immediately before it is overwritten, by
whoever is doing the overwriting: `PostWriter.write` for a re-import, the
edit and restore paths in `scripts/manage_post.rb` for everything a person
does by hand.

The store is deliberately plain: `content.nosync/versions/<year>/<slug>/`,
one whole post JSON per file, named for the second it was kept
(`20260813-174204-118.json`) so that sorting the directory is sorting by
time and no index has to be maintained. Ten per post; the eleventh drops
the oldest, because the newest copy answers "what did this say before I
broke it" in nine cases out of ten and an unbounded history of an archive
this size is a second archive. `PostVersions.move` carries the directory
into the trash with the post and back out on a restore, or a restored post
would come back with amnesia and a deleted one would leave its history
orphaned where nothing points at it.

Three deliberate limits. It is **not configurable** -- a safety net with a
switch is off exactly when it is needed, since nobody turns it on before
the mistake, which is how this engine treats `trash/`, the slug-collision
abort and the deploy guards too. Its **failures are swallowed**: a full
disk or a read-only directory must not stop somebody saving their writing,
and the point of this is to lose less. And it is **not git and not a
backup** -- no branches, no diff between two arbitrary points, and it
lives beside the content, so it dies with it. The backup list in
[operations.md](operations.md#backup) still applies.

Only the text is kept, never the media, which is the other half of why the
cap is short: a version old enough to name a picture the post no longer
has would restore a broken reference. The CLI side of this -- the `[v]`
key, what the list shows and why restoring is itself undoable -- is in
[operations.md](operations.md#properties-and-actions).

## Importing

An import splits along the line between what every platform needs and what
only one does, so that adding a source means writing its mapping, not
another copy of the plumbing every existing adapter shares:

- **`Import::Media`** collects one post's media for `PostWriter`, from
  either a URL (download, following redirects, retrying transient failures)
  or a path an export already contains. Filenames are numbered per post in
  registration order, which is what makes a re-import land on the same names
  so `PostWriter`'s "skip if it exists" copy is a no-op instead of a
  duplicate. In dry-run it allocates and counts without fetching -- so
  adapters must take image dimensions from platform metadata, never from the
  downloaded bytes.
- **`Import::Run`** drives: walk the source, hand each item to the adapter,
  write it, count why items were skipped, report. Skips are Symbols, so the
  summary can answer the question anyone reads a summary for -- why fewer
  posts arrived than the source has. Two callbacks, `on_scan` and `on_post`,
  let a wizard show progress without this layer knowing what a terminal is.
- **An adapter** implements only `label`, `each_item` (paging the source)
  and `map(item, media)`, returning a post hash or a skip reason. Five
  optional hooks cover what sources differ on: `preamble` (a line to print
  before a slow read), `total` (the source's size, often knowable only
  once the first page arrives), `postscript` (a one-line note after a run
  or preview -- scheduled posts becoming drafts, posts with no usable
  original address), `platform_tag` (the tag posts are filed under when
  the platform's name makes a poor one -- "medium.com" says more than
  "feed") and `keep_permalinks=` (a setter whose presence tells the
  wizard this adapter can record old addresses as `redirect_from`, so the
  question is asked per capability and defaults to no).
- **`Import::HtmlBlocks`** converts a post body that arrives as markup into
  blocks, for the sources that hand over HTML rather than structured data.
  A tolerant tokenizer and a stack-based tree (an XML parser refuses real
  post HTML outright), then a conservative mapping: exactly what the schema
  can represent, unknown wrappers walked through, and anything with no
  representable shape dropped *and counted* rather than guessed at.
- **`Import::Cli`** is the non-interactive front end the `scripts/migrate_*.rb`
  wrappers share, so each is a handful of lines. Every source is therefore
  reachable both ways -- wizard or script -- over one implementation of the
  mapping.

`Import::Feed` covers WordPress and RSS/Atom in one adapter, because they
are one format: a WXR export *is* RSS 2.0, with a `wp:` namespace layered on
for what a feed has no room for (`post_type` to filter by -- in a stock
export menu items, attachments and pages outnumber the posts -- `status` for
drafts, `post_id` for dedup, `post_name` for the slug the site already
published under). It takes the date from `pubDate` rather than
`wp:post_date`, which carries no offset and would otherwise be read in
site.timezone and shift by hours. Images referenced in the markup are
downloaded and then *measured*: HTML rarely states dimensions, and a block
without them renders with nothing reserving its place, so the page jumps as
each picture lands.

An adapter judges items rather than pre-filtering them: `map` returns the
reason as a Symbol -- `:reply`, `:retweet`, `:quote`, `:empty` and their kin;
the wizard's `TRANSLATED_REASONS` in `scripts/import.rb` names two dozen
across the adapters -- instead of quietly dropping the item, so the run's
summary can account for every item the source held. That
also means a written-post counter is not a progress fraction -- a source that
skips half its items never writes as many posts as it has -- so both counters
are reported and the caller picks: against a `LIMIT` the goal is posts
written, against a whole source it's position scanned.

`Import::Bluesky` is the reference adapter. Two things it has to get right
generalize to any API source: facet offsets are UTF-8 **byte** positions
while the schema's formatting spans are **codepoints**, so every boundary is
converted (skip that and spans land several characters off on any non-ASCII
text), and video arrives as an HLS playlist rather than a file, so the
poster frame is imported as an image -- a `video` block with no media would
render as "video unavailable".

`scripts/import.rb` is a second wizard rather than a menu entry in
`blog.sh`, and always previews in dry-run before writing. `lib/site_header.rb`
is shared by both wizards so the site-identity block can't drift between
them.

Supporting casts: `lib/slug.rb` (one folding/slugification used for
post slugs, tag slugs, heading anchors and the search index -- and
mirrored client-side by `fold()` in search.js), `lib/content_type.rb`
(dominant type: video > audio > image > chat > quote > link > text, where
"quote" means the post's first block is one, and media win only while the
post's text stays caption-sized -- past 500 characters it's an article
with illustrations, i.e. text), `lib/media_dimensions.rb`
(width/height straight from PNG/JPEG/MP4 headers -- EXIF orientation
included, so a photo taken sideways reserves the space it is shown at),
`lib/video_probe.rb` (the video track's codec from the same box walk, two
levels further down at `stsd`, so a save can say that a clip is HEVC).

## Exporting (`lib/exporter.rb`)

The mirror of the importers, and a much smaller thing: one source (this
archive), one destination format, no adapters. `./blog.sh export` walks
`content.nosync` and writes a Jekyll-shaped tree -- `_posts/<date>-<slug>.md`,
`_drafts/<slug>.md`, pages at the root, media copied under
`assets/<year>/<slug>/`. It only reads: nothing in the archive is
touched, which is what lets it be the one command that still works on an
installation somebody is leaving (hence its own entry point in
`scripts/export.rb`, needing neither `env.sh` nor a config that parses).

Three details carry the design:

- **Its own front matter writer, deliberately not the CLI's.**
  `build_frontmatter` in `scripts/manage_post.rb` is not YAML and does
  not try to be: its reader (`MarkdownParser.parse_frontmatter`) splits
  on the first colon and quotes nothing, which is right for a human
  editing one post. Every reader downstream of an *export* -- Jekyll,
  Hugo, `Import::Jekyll` -- uses a real YAML parser, where an unquoted
  title containing a colon is a syntax error that takes the whole post
  with it. The exporter therefore dumps through Psych with
  `line_width: -1` (a folded long title is valid YAML and unreadable).
- **Blocks markdown cannot write down become HTML, and get counted.**
  `MarkdownWriter` drops what it has no syntax for -- the link card, an
  imported embed with no recognisable address -- which is correct for
  `edit`, where the CLI's loss guard stands behind it, and wrong for an
  export. So the exporter renders block by block (the writer keeps no
  state between blocks, so this is equivalent) and gives anything that
  came back empty the same HTML the build renders. Counted per type and
  said out loud, because the destination gets HTML where the rest of the
  post is markdown. Above each one goes `<!-- blogsh:block {...} -->`,
  the block's own JSON with its media paths rewritten to where they sit
  in the export: every other engine ignores an HTML comment, and
  `Import::Jekyll` turns it back into the block (`own_blocks_to_sentinels`
  → `own_block`), so the round-trip loses nothing. `--` inside the JSON
  is escaped as `\u002d`, or a caption containing `-->` would close the
  comment early and spill markup into the page.
  **Video and audio skip the markdown path even where the writer has a
  form for them**: `!![caption](url)` is this engine's own syntax, and
  CommonMark -- what every destination engine reads -- parses it as a
  literal `!` followed by an *image*. Exported as markdown, a YouTube
  video rendered on the destination as a broken image, and re-importing
  the tree downloaded YouTube's HTML page and filed it in the archive as
  `02.jpg` with no error reported, because the fetch had technically
  succeeded. Found only by running the whole thing over a real 118-post
  archive; a fixture could not have shown it, because both ends of a
  fixture round-trip are ours.
- **`blogsh:` is the round-trip.** Everything no other engine has a word
  for goes under that one key -- `source` above all, which is half the
  re-import dedup key. `Import::Jekyll` reads it back (whitelisted, never
  merged), which turns export + import into a way to move an
  installation. A post carrying it also gets no platform tag: a tree that
  came from here and goes back must not collect a "jekyll" pill per
  round.

What is deliberately lost: `small`/`mention`/`color` spans keep their
text and lose their styling, and a draft's preview URL is not exported
(it is a private address, not a permalink).

## Checking the archive (`lib/checker.rb`)

`./blog.sh check` is doctor's counterpart and deliberately a separate
command: doctor answers "is this installation sound", reads a handful of
config values and takes a second, while this walks every post and every
media file there is. Rolled into one command the fast half would stop
being run, which is the half somebody runs before every deploy.

It reads the **content**, not the built site. A finding has to name a post
and a slug -- something to go and fix -- rather than a file under
`public.nosync`, and it has to work before a build has ever run. Judging a
link still needs to know which addresses a build would produce, so those
are derived in the checker from the same rules `build_blog.rb` follows.
Thirteen questions, in one pass: files the checker cannot read at all, posts
whose date nothing can parse, posts whose text is not a list of blocks, and
posts whose slug is not one path segment -- all of them states the BUILD
refuses to run on (or, for the slug, misplaces the page for), so a check that stayed
quiet about them was calling an archive sound that was about to stop the
site; files a queue move stepped aside and a crash left parked, which no
listing shows and whose repair depends on whether the post inside them is
still in the archive anywhere else; media a post asks for and hasn't got
-- or has in a shape no reader can use, or has under a spelling that is not
the one the post names, where a volume that folds letter case and unicode
form renders the page and one that does not has the hole already; images
whose stored dimensions are 1px or smaller, which the build drops
*together with their caption* and would otherwise lose silently; internal
links pointing at an address nothing on this site answers at; links
written relative to the post rather than to the site, which a static host
answers 200 with the page the reader is already on -- the one kind here
that fails at nothing and is therefore invisible from everywhere else;
media directories no post owns any more; files in a post's own directory the
post no longer names; two series whose names sit an edit or two apart,
which is usually one series and a typo; one old address claimed by
two posts, where whichever renders last wins and the others' readers land
on it; and two posts that would be served at one address, which the build
refuses to run on at all -- so an archive in that state used to be called
sound by the one tool whose job is to say otherwise; and a `redirect_from`
the build will refuse to serve, which it says once in the middle of a build
log and which the checker used to count among the addresses this site
answers at, so a link into one passed as sound.

Two rules shape the plain run. **It only ever reports** -- nothing here
deletes an orphaned directory or rewrites a post, because the whole value
of the tool is that its output can be trusted, and a checker that also
acts has to be trusted twice. And each kind of finding is **capped**, the
remainder counted (`more`), since a thousand identical lines is not more
information than a screenful and buries every other kind -- the cap, with
the rest of the command's day-to-day surface, is in
[operations.md](operations.md#checking-the-archive). The exit code is
non-zero on errors only: an orphan directory costs disk rather than
correctness, so a cron job hanging off this would be crying wolf if
warnings failed it. Like `export` and `stats` it has its own entry
point (`scripts/check.rb`) rather than going through `manage_post.rb`,
which applies the site timezone as it loads and aborts on a config it
cannot read -- a run that exits explaining the config has checked nothing.

Both rules have a door in them since 1.4, and both doors are opened by
hand. `--repair` walks the findings and offers, per finding, the single
repair that finding allows: a redirect written into the target post, a
relative link rewritten, a file moved to the trash. Nothing is applied
without a key press, a version is kept before a post is changed, and
nothing is ever deleted. `--json` prints every finding instead of a
capped screenful, because a cap is right for reading and useless for
acting on -- a script cannot work from "...and 23 more".

`--online` is the only part that leaves the machine, and it is asked for
by name because it takes minutes rather than a second and, over an archive
going back twenty years, will find things nobody can do anything about.
What counts as a finding is narrow on purpose: a host that no longer
resolves, and a 404 or 410, are the web saying "this is gone"; a timeout,
a refusal, a 5xx, a TLS error or a 403 are the web saying "not right now",
and reporting those turns one flaky evening into forty findings that are
all fine again tomorrow. A checker nobody believes is worse than no
checker.

Three details make it usable on a real archive rather than only correct:

- **HEAD first, GET to confirm anything fatal.** A link checker has no use
  for the body, and HEAD over a few thousand links is the difference
  between minutes and an afternoon -- but HEAD is never believed when it
  says a page is gone. Some servers answer it with 405 or 501 while
  serving GET perfectly; worse, some answer 404 to HEAD and 200 to GET for
  the very same address (bsky.app does this on profile pages, and the
  first run over a real archive reported dozens of live links as dead
  because of it). So `RETRY_WITH_GET` re-asks with a GET, one extra
  request per apparently-dead link.
- **Politeness rather than throughput.** One request at a time, and a
  one-second pause between two requests to the same host: an archive with
  two hundred links to one site should not read as an attack on it.
- **Memory between runs.** `Checker::Cache` keeps every verdict in
  `tmp/link-check.json` for a while (how long, see
  [operations.md](operations.md#checking-the-archive)), so a second run
  only asks about the links it has not seen lately -- without it nobody
  runs this twice, since a few thousand requests is minutes and most of
  the answers were the same yesterday. A cache it cannot read or write
  is not an error: the check simply asks the network, which is what it
  was going to do anyway.

## Counting (`lib/stats.rb`)

`./blog.sh stats` is the same shape as `check` and `export`: its own
entry point, the archive on disk as its only input, no configuration it
could die on. `lib/stats.rb` counts and returns a plain Hash -- it never
prints, colours or translates -- and `scripts/stats.rb` renders that
either as a screen for a person or, with `--json`, verbatim for whatever
reads it next. That split is what keeps the two outputs from drifting:
there is one set of numbers and two ways of showing it.

It reuses what already answers each question rather than re-deriving it:
`PostText.plain` for words (the same text the search index is built
from), `ContentType.dominant` for what a post is, `FileSize.human` for
sizes, and the build's own 200-words-per-minute constant for reading
time -- two places telling a reader how long something takes must not
disagree.

## Build pipeline (`build/build_blog.rb`)

A single linear pass, no framework:

1. **Load & guard.** Read every post JSON; abort on a year+slug
   collision (two posts would silently overwrite each other's output
   and media).
2. **Order.** Sort by date with slug as tiebreaker -- `sort_by` isn't
   stable and imported posts can share timestamps; without the
   tiebreaker, page contents would shuffle between builds.
3. **Partition.** Drafts leave the main flow: each gets only its own
   page at `/draft/<token>/<slug>/` with `noindex`, and appears in no
   listing, feed or index.
4. **Render.** Per-post pages, then listings: homepage, per-tag,
   per-content-type -- the last only for types with at least one
   published post (`PRESENT_TYPES`); the nav menu and the sitemap
   follow the same set, so an empty type has no pages, no menu item
   and no sitemap entry. Pagination is **anchored to the oldest post** --
   page 1 is the oldest ten, the newest posts live on the landing page,
   which splits only after holding 2x the page size. Page boundaries
   therefore never shift, so adding a post rewrites a handful of files
   instead of the whole archive.
5. **Indexes & feeds.** Client-side search index split into recent
   (`search-index.json`, newest 500, loaded eagerly) and archive
   (`search-index-archive.json`, loaded on first query). Each entry
   carries one folded blob (title, text and tags together), which is what
   `assets/js/search.js` matches on; it scores the hits afterwards -- a
   word in the title above a word in the text, a whole word above the
   same letters inside a longer one, date as the tiebreak -- and draws at
   most `RESULT_LIMIT` of them while reporting the true count;
   RSS (last-build date = newest post, not "now", to keep the file
   byte-stable); sitemap; robots.txt.
6. **Assets, colors and the root favicon.** Before `assets/` is copied
   into the build, any live name missing under `assets/images/` is seeded
   from the tracked `assets/images/defaults/` -- the live banner and
   favicon are per-install files outside git (see decisions.md), so a
   fresh clone renders immediately while an owner's own artwork is never
   overwritten; `defaults/` itself is not published. `config/site.yml`'s 7-key palettes
   compile into `assets/css/colors.css`, together with the header's font
   stacks and sizes and any `@font-face` a site declared for its own files
   in `assets/fonts/`; `site.css` itself contains no palette values -- its
   only color literals are palette-independent neutrals (white, two fixed
   grays, black/white alpha overlays) -- and no site-specific typography. One generated stylesheet rather than two on
   purpose: it is already linked from the layout, so adding fonts to it
   changes two files on a deploy instead of every page in the archive. `build_favicon_ico` wraps `assets/images/favicon.png` in
   an ICO container (a 22-byte header, then the PNG verbatim) and emits
   `/favicon.ico` -- pages link the PNG, so this exists purely for clients
   that request the root path without reading the `<link>`. No image
   library involved, the same "smallest correct slice of a format"
   approach as `lib/qr_code.rb`; returns nil with no source PNG, so a site
   without a favicon simply doesn't get the file. ICO's dimension fields
   are one byte each and 0 means 256, so a larger source can't state its
   size -- browsers load it and report 256, immaterial at favicon sizes.
7. **Write & prune.** `emit` writes a file only when its bytes actually
   changed and records every generated path; `prune_public` then deletes
   whatever the build didn't produce this run, deepest directories
   collapsing first.

Renders are memoized per post (content HTML, parsed time, dominant
type, list item) keyed by object identity -- a post appears on its own
page plus every listing, and would otherwise be rendered 4-6x. ERB
partials (nav, aside, footer) are cached by name+locals since they
don't depend on page content.

## The terminal UI

`lib/tui.rb` is the whole UI layer: colors, single-keypress choices,
arrow-key menus, the screens they live on and a spinner -- pure stdlib
(`io/console`), plain VT100 sequences, no terminfo and no gems. Four
deliberate constraints:

- **Everything degrades.** `Tui.interactive?` gates every enhancement,
  so piped, scripted and cron runs keep the exact line-based behavior
  (and escape-code-free output) they always had. Colors additionally
  honor `NO_COLOR` and `TERM=dumb`.
- **A screen that stays put.** `Tui.frame(rows, keep_last:)` paints from
  the top of the viewport over whatever the previous frame left there,
  writing the rows in one go and ending the last without a newline -- a
  full-height frame that ends in one scrolls the view by exactly what this
  exists to prevent. `keep_last` names the rows that survive a window too
  short to hold the frame (the keys, normally); what gets dropped instead
  is the end of the list, which the cursor can still scroll to. Everything
  interactive is built on it: the wizard menu, the publishing queue,
  `Tui.menu`, `Tui.browse`, the props dialog and the questions in
  `./setup.sh`, `./style.sh` and `./import.sh`.
- **Not the alternate screen.** `\e[?1049h` would discard its plane on
  exit, and this CLI prints things worth keeping -- a draft's address,
  what a deploy uploaded, what refused. The last frame stays where it was
  drawn and the scrollback above it is never touched.
- **Raw mode around a frame, never a session.** `Tui::Screen#key` holds
  raw for one paint-and-read and gives it back, so no crash can leave the
  user's shell broken -- the classic TUI failure mode. A lone Esc is told
  apart from an arrow key by a 50 ms wait for the rest of the sequence.

`Tui.screen` yields a `Screen`: `paint` puts a frame up, `key` waits for
one keypress, and `leave` hands the terminal to something that prints more
than a frame can hold (a build, a publish) and takes it back afterwards.
Nothing in it knows what a post or a queue is. A window resized *while*
`key` waits answers `:resize`, which every caller treats as "paint again":
a trap alone would not do, because `getch` blocks in the kernel and the
handler would run with the read still parked, so the handler writes a byte
to a pipe that `key` waits on alongside the terminal.

Two rules follow from painting at the top, and both are easy to get wrong.
Anything a caller prints *just before* a picker is painted over, so the
rows that belong above a list travel into it as `header:` rather than
being printed first. And a list longer than the window scrolls inside it,
on a window measured once when the picker opens: `Tui.menu` and
`Tui.browse` read the terminal's height before their loop and keep it,
because the arithmetic deciding which rows are visible has to stay valid
for the life of the call. Answering a resize mid-wait is therefore the
privilege of the screens that own a `Screen` -- the wizard menu, the
publishing queue and the props dialog -- and everywhere else a resized
window straightens itself on the next screen rather than on the spot.
`context:` adds one line under the cursor saying what the selected row
*is* -- what a version said, where the row itself can only say when it was
kept -- and it is called for the selected row only.

`lib/qr_code.rb` renders a draft's preview URL as a scannable QR code in
half-block glyphs -- the smallest correct subset of the spec that the job
needs (byte mode, EC level L, versions 1-5, fixed mask 0), verified
module-for-module against a reference encoder.

`lib/preview_server.rb` backs `./blog.sh preview`: a minimal
`TCPServer`-based static file server (GET/HEAD, no keep-alive,
thread-per-connection), in place of the obvious `ruby -run -e httpd`
one-liner -- that depends on `webrick`, a default gem some distros
split out of their minimal Ruby package (see [decisions.md](decisions.md)).
Percent-decodes the request path itself and rejects anything that
resolves outside the served root, the one security property a static
file server actually needs. It answers byte ranges (206, and 416 for a
range past the end) and streams the file rather than reading it whole:
without ranges Safari refuses to play a media element at all, and
seeking in a video or audio post is broken everywhere else -- a preview
that cannot show what the deployed site does is not a preview. Every
extension the engine can attach to a post has a MIME type here, for the
same reason.

## Deploy (`scripts/deploy_web.rb` + `lib/deploy_backend/`)

The deploy script owns the *what*; backends own the *how*:

- A **manifest** (`.deploy_manifest<suffix>.json`, one per backend)
  records hash+size+mtime of everything the target has. Unchanged
  size+mtime skips even reading the file; everything else is hashed to
  decide. From that fall out `to_upload` and `orphans`.
- A **baseline** (`.deploy_baseline.json`, one for *all* backends) records
  the file count and total bytes of the last build the guards accepted,
  plus the previous run's outcome. It is the manifest's opposite number:
  the manifest is the state of the target, the baseline is the shape of
  the build -- which is why it carries no per-backend suffix.
- **Safeguards** run before any backend, and measure the build against
  that baseline rather than against the manifest: an upload failure must
  not be able to move the yardstick. Which checks run, at which
  thresholds, and what `--prune` and `--force` do and do not override is
  in [operations.md](operations.md#deploying) -- so is the single
  per-file size limit alongside them, enforced by `lib/file_size.rb`
  when a post is saved as well as here.
- **Backends** implement one of two shapes: per-file
  `session`/`upload`/`delete` (Surfer's HTTP API, local copies) or a
  single batch `sync` (rsync, rclone and git diff against the target
  themselves; sftp executes the manifest's precomputed lists). The git
  backend is a *snapshot*: every deploy force-pushes one commit that
  mirrors the build exactly, so it declares `always_prunes?` and the
  script keeps its bookkeeping honest.

## The client side

Small single-purpose vanilla JS files, no framework, no third-party
origins. `util.js` loads first because everything else stands on it:
`Blog.escapeHtml`, which every piece of foreign data goes through before
it reaches `innerHTML`, and `Blog.formatDate`, which takes its locale from
`window.BLOG_I18N` so a date the browser writes matches the ones the build
wrote. Then, in load order:

- **Theme** (`theme-toggle.js`): a button cycling three states -- follow
  the system, light, dark -- with the reader's answer in `localStorage`
  and nothing there while they are following the system. Anything else
  found in storage is read as "no choice" rather than written onto the
  root element, where it would match neither the light rules nor the dark
  ones.
- **The menu on a phone** (`nav-toggle.js`): opens and closes the bar, and
  closes it on Escape or a tap on the page as well as on the button. The
  open menu covers most of a phone's screen, and a reader who has decided
  against it reaches for one of those two before hunting for the small
  button again; Escape hands focus back to the button, which is where they
  were before they opened it.
- **Back to top** (`scroll-top.js`): the button appears past 300 px of
  scrolling, on a listener declared `passive` so the browser never waits
  to see whether it cancels the scroll. It asks
  `prefers-reduced-motion` at the click rather than at load, because the
  setting can change while the page is open -- and it has to ask at all,
  since CSS can take the site's transitions out but not a scroll this code
  asks for.
- **Comments** (`comments.js`): a published post's announcement
  reference is baked into the page (`data-toot-url` or
  `data-bluesky-uri` -- exactly one network per site, see
  `SiteConfig.comment_network`). Reading it in the browser needs a server
  that serves a thread to an anonymous request; GoToSocial requires a
  token there and so does Mastodon in secure mode, which leaves
  `comments.approval` (a cron with a token) as the only way in. The
  address itself comes in three shapes -- Mastodon's `/@user/<id>`,
  GoToSocial's `/@user/statuses/<ULID>` and the ActivityPub
  `/users/user/statuses/<id>` -- read by one rule written twice, in
  `lib/post_stats.rb` and in `comments.js`, most specific pattern first.
  Then the visitor's browser fetches the
  reply thread from the Mastodon instance's public context API or from
  Bluesky's public AppView (`getPostThread`, no auth). Everything
  except Mastodon's own sanitized status HTML is escaped via
  `Blog.escapeHtml`; Bluesky reply text is plain text and is escaped
  wholesale.
- **Widgets** (`sidebar.js`) read same-origin JSON (`toots.json`,
  `bluesky.json`, `pixelfed.json`, `commits.json`, `rss.json`,
  `stats.json`) that
  **cron** (`scripts/refresh_sidebar.rb`) fetched server-side -- the
  visitor's browser never contacts GitHub, the Fediverse or Bluesky for
  them. A failed cron fetch keeps the previous JSON rather than
  publishing an empty widget.
- **Search** (`search.js`) runs entirely client-side over the two
  index files, with the same diacritic folding the build used to create
  them.
- **Lightbox** (`lightbox.js`) opens a post's figures and gallery images
  over the page as a real dialog: `aria-modal`, the body held still, Tab
  kept inside it, the arrows walking the group the image belongs to, and
  focus handed back to the picture it was opened from. Its labels come
  from `window.BLOG_I18N` like every other string the client draws.
- **i18n:** locale strings the client needs are embedded once per page
  as `window.BLOG_I18N` -- the only inline script, allowlisted in the
  CSP by its SHA-256 content hash rather than `unsafe-inline`.

## Security

The threat model is a static site with no server of its own: nothing
here authenticates anybody, so what remains to get wrong is what the
pages carry and what the working directory holds.

- **Content-Security-Policy**, delivered as a meta tag, because a static
  host may not let you set headers. Fonts are self-hosted, so no
  third-party origin is needed for them. A media player's origin is
  admitted only on the pages that actually embed one -- the build knows
  which posts carry a provider, so an archive page that embeds nothing
  allows nothing; YouTube's two origins are the exception and are
  allowed everywhere. The one inline script is allowlisted by content
  hash, see [The client side](#the-client-side).
- **Draft URLs** carry a `SecureRandom` token and `noindex`. That makes
  a preview link unguessable and keeps it out of search results. It is
  not access control: anyone the link reaches can read the draft, which
  is the point of being able to send one.
- **Escaping** is consistent for everything that came off a network --
  Fediverse display names, avatar URLs, reply text -- in both the HTML
  the build writes and the DOM the client builds. The one exception is
  Mastodon's own sanitized status HTML, see
  [The client side](#the-client-side).
- **`env.sh`** holds the live credentials, stays out of git, and is mode
  `600`. The wizards leave a `.bak` of whatever they rewrote at the same
  mode, so it still holds the previous tokens -- remove it once one has
  been rotated.
- **No third-party tracking** goes into post data, and the sidebar
  widgets are fetched server-side by cron rather than by the visitor's
  browser, so reading a page contacts one origin.
