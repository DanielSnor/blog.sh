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
  `link`, `hr`.
- Inline formatting (bold/italic/strikethrough/code/link) is stored as
  **codepoint offset ranges into plain text**, not nested HTML -- the
  same NPF-style shape Tumblr's API uses, which is what the importers
  naturally produce.
- Media lives next to its post in `media.nosync/<year>/<slug>/`,
  referenced by bare filename; nothing is ever hotlinked.

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
| `title` | string | posts without one are titled by their slug |
| `tags` | array of strings | rendered as pills, slugified for tag URLs |
| `state` | `"published"` \| `"draft"` | absent = published |
| `draft_token` | string | drafts only -- the hidden preview URL segment |
| `created_at` | string | drafts only -- publish-time "was the date edited?" check |
| `type` | string | explicit dominant content type; absent = derived from blocks |
| `source` | object | `platform` plus optionally `account`, `original_id` -- the re-import dedup key |
| `mastodon_url` | string | the post's comment toot (Mastodon sites), set on publish/`toot` |
| `bluesky_url` | string | the announcement's human link (Bluesky sites), set on publish/`bluesky` |
| `bluesky_uri` | string | the announcement's `at://` URI -- what the thread API takes; stored alongside the URL because converting between them needs a handle→DID resolution round-trip |

**Blocks** (`content` array entries), by `type`:

| `type` | Fields |
| --- | --- |
| `text` | `text`; `subtype` (`heading1`-`heading6`, `quote`; absent = paragraph); `formatting`; a quote may carry `cite` (attribution, rendered as a right-aligned line) |
| `list` | `style` (`"ul"`/`"ol"`); `items` -- each `{text, formatting?, children?}` where `children` is a nested list block |
| `table` | `align` (array of `left`/`center`/`right`); `header` (array of cells); `rows` (array of cell arrays); a cell is `{text, formatting?}` |
| `code` | `text` (verbatim, blank lines preserved); `lang` (cosmetic) |
| `chat` | `lines` -- array of `{name, text}`; `name` may be nil for a continuation line |
| `hr` | no fields |
| `image` | `media` (see below); `alt_text`; `caption` |
| `video` | one of three shapes: local file -- `media` (+ optional imported `poster`, same shape) and `caption` (the authoring CLI requires it); YouTube -- `provider: "youtube"`, `url`, `youtube_id`, `caption`; imported embed -- `embed_html` (+ `provider`, `url`). A `url` alone renders as a polite "video unavailable" notice |
| `audio` | local file -- `media` (first entry's `url`, no dimensions needed) and `caption`; imported embed -- `embed_html` (+ `provider`, `url`). A `url` alone renders a polite "audio unavailable" notice |
| `link` | `url`; `title`; `description` -- rendered as a link card |

An unrecognized `type` renders as its raw JSON in a `<pre>` -- loud,
not silent.

**`media`** is an array whose first entry is used: `{url, width,
height}`. `url` is a bare filename inside the post's
`media.nosync/<year>/<slug>/` directory; `width`/`height` reserve
layout space and are effectively **required for images** -- an image
whose dimensions are missing or <= 1 px is treated as degenerate and
dropped from rendering (the CLI reads them from PNG/JPEG/MP4 headers;
an importer must supply them too).

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
- The importers write the same schema through the shared
  `lib/post_writer.rb`, so an imported post and a hand-written one are
  indistinguishable downstream.

## Importing

An import splits along the line between what every platform needs and what
only one does, so that adding the fifth source doesn't mean a fifth copy of
the first four's plumbing:

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
  and `map(item, media)`, returning a post hash or a skip reason. Two
  optional hooks cover what sources differ on: `preamble` (a line to print
  before a slow read) and `total` (the source's size, often knowable only
  once the first page arrives).
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
without them is dropped at build time by `degenerate_image?`.

An adapter judges items rather than pre-filtering them: `map` returns
`:reply`/`:retweet`/`:quote`/`:empty` instead of the adapter quietly dropping
them, so the run's summary can account for every item the source held. That
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
(dominant type: video > audio > image > link > text), `lib/media_dimensions.rb`
(width/height straight from PNG/JPEG/MP4 headers, so pages reserve
space and never jump).

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
   per-content-type. Pagination is **anchored to the oldest post** --
   page 1 is the oldest ten, the newest posts live on the landing page,
   which splits only after holding 2x the page size. Page boundaries
   therefore never shift, so adding a post rewrites a handful of files
   instead of the whole archive.
5. **Indexes & feeds.** Client-side search index split into recent
   (newest 500, loaded eagerly) and archive (loaded on first query);
   RSS (last-build date = newest post, not "now", to keep the file
   byte-stable); sitemap; robots.txt.
6. **Colors and the root favicon.** `config/site.yml`'s 7-key palettes
   compile into `assets/css/colors.css`; `site.css` itself contains zero
   color values. `build_favicon_ico` wraps `assets/images/favicon.png` in
   an ICO container (a 22-byte header, then the PNG verbatim) and emits
   `/favicon.ico` -- pages link the PNG, so this exists purely for clients
   that request the root path without reading the `<link>`. No image
   library involved, the same "smallest correct slice of a format"
   approach as `lib/qr_code.rb`; returns nil with no source PNG, so a site
   without a favicon simply doesn't get the file. ICO's dimension fields
   are one byte each and 0 means 256, so a larger source can't state its
   size -- browsers load it and report 256, immaterial at favicon sizes.
7. **Write & prune.** `emit` writes a file only when its bytes actually
   changed and records every generated path; whatever the build didn't
   produce this run is deleted afterward, deepest directories collapsing
   first.

Renders are memoized per post (content HTML, parsed time, dominant
type, list item) keyed by object identity -- a post appears on its own
page plus every listing, and would otherwise be rendered 4-6x. ERB
partials (nav, aside, footer) are cached by name+locals since they
don't depend on page content.

## The terminal UI

`lib/tui.rb` is the whole UI layer: colors, single-keypress choices, an
inline arrow-key menu and a spinner -- pure stdlib (`io/console`), plain
VT100 sequences, no terminfo and no gems. Three deliberate constraints:

- **Everything degrades.** `Tui.interactive?` gates every enhancement,
  so piped, scripted and cron runs keep the exact line-based behavior
  (and escape-code-free output) they always had. Colors additionally
  honor `NO_COLOR` and `TERM=dumb`.
- **Raw mode per keystroke, never persistent.** `STDIN.getch` enters and
  leaves raw mode around a single read, so no crash can leave the user's
  shell broken -- the classic TUI failure mode.
- **Inline, not fullscreen.** The menu repaints its lines in place with
  cursor-up; no alternate screen, so the dialog stays in the scrollback.
  A list longer than the terminal is tall scrolls inside a window sized
  once per call (a wrapped or overflowing line would break the
  fixed cursor-up arithmetic, which is also why items are truncated
  rather than wrapped). A lone Esc is told apart from an arrow key by a
  50 ms wait for the rest of the sequence.

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
file server actually needs.

## Deploy (`scripts/deploy_web.rb` + `lib/deploy_backend/`)

The deploy script owns the *what*; backends own the *how*:

- A **manifest** (`.deploy_manifest<suffix>.json`, one per backend)
  records hash+size+mtime of everything the target has. Unchanged
  size+mtime skips even reading the file; everything else is hashed to
  decide. From that fall out `to_upload` and `orphans`.
- **Safeguards** run before any backend: a >20% drop or growth in file
  count versus the last deploy aborts (a broken build must not be
  mirrored), `--prune` is the only deleting flag, `--force` the only
  override.
- **Backends** implement one of two shapes: per-file
  `session`/`upload`/`delete` (Surfer's HTTP API, local copies) or a
  single batch `sync` (rsync, rclone and git diff against the target
  themselves; sftp executes the manifest's precomputed lists). The git
  backend is a *snapshot*: every deploy force-pushes one commit that
  mirrors the build exactly, so it declares `always_prunes?` and the
  script keeps its bookkeeping honest.

## The client side

Small single-purpose vanilla JS files, no framework, no third-party
origins:

- **Comments** (`comments.js`): a published post's announcement
  reference is baked into the page (`data-toot-url` or
  `data-bluesky-uri` -- exactly one network per site, see
  `SiteConfig.comment_network`); the visitor's browser fetches the
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
- **i18n:** locale strings the client needs are embedded once per page
  as `window.BLOG_I18N` -- the only inline script, allowlisted in the
  CSP by its SHA-256 content hash rather than `unsafe-inline`.
