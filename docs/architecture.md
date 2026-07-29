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
  heading1-6/quote), `list`, `table`, `code`, `image`, `video`, `link`,
  `hr`.
- Inline formatting (bold/italic/strikethrough/code/link) is stored as
  **codepoint offset ranges into plain text**, not nested HTML -- the
  same NPF-style shape Tumblr's API uses, which is what the importers
  naturally produce.
- Media lives next to its post in `media.nosync/<year>/<slug>/`,
  referenced by bare filename; nothing is ever hotlinked.

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
- The migration scripts (`migrate_tumblr.rb`, `migrate_twitter.rb`)
  write the same schema through the shared `lib/post_writer.rb`, so an
  imported post and a hand-written one are indistinguishable downstream.

Supporting casts: `lib/slug.rb` (one folding/slugification used for
post slugs, tag slugs, heading anchors and the search index -- and
mirrored client-side by `fold()` in search.js), `lib/content_type.rb`
(dominant type: video > image > link > text), `lib/media_dimensions.rb`
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
6. **Colors.** `config/site.yml`'s 7-key palettes compile into
   `assets/css/colors.css`; `site.css` itself contains zero color
   values.
7. **Write & prune.** `emit` writes a file only when its bytes actually
   changed and records every generated path; whatever the build didn't
   produce this run is deleted afterward, deepest directories collapsing
   first.

Renders are memoized per post (content HTML, parsed time, dominant
type, list item) keyed by object identity -- a post appears on its own
page plus every listing, and would otherwise be rendered 4-6x. ERB
partials (nav, aside, footer) are cached by name+locals since they
don't depend on page content.

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

- **Comments** (`comments.js`): a published post's toot URL is baked
  into the page; the visitor's browser fetches the reply thread from
  the Mastodon instance's public context API. Everything except the
  Mastodon-sanitized status HTML is escaped via `Blog.escapeHtml`.
- **Widgets** (`sidebar.js`) read same-origin JSON
  (`toots.json`, `pixelfed.json`, `commits.json`, `stats.json`) that
  **cron** (`scripts/refresh_sidebar.rb`) fetched server-side -- the
  visitor's browser never contacts GitHub or the Fediverse for them. A
  failed cron fetch keeps the previous JSON rather than publishing an
  empty widget.
- **Search** (`search.js`) runs entirely client-side over the two
  index files, with the same diacritic folding the build used to create
  them.
- **i18n:** locale strings the client needs are embedded once per page
  as `window.BLOG_I18N` -- the only inline script, allowlisted in the
  CSP by its SHA-256 content hash rather than `unsafe-inline`.
