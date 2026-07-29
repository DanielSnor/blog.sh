# blog.sh — .sh → .rb → .html

*minimalistic static web/log cms*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-CLI_wrapper-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ruby](https://img.shields.io/badge/Ruby-Pure_stdlib-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![JSON](https://img.shields.io/badge/JSON-Content_format-000000?logo=json&logoColor=white)](https://www.json.org)
[![HTML](https://img.shields.io/badge/HTML-ERB_templates-E34F26?logo=html5&logoColor=white)](https://developer.mozilla.org/en-US/docs/Web/HTML)
[![CSS](https://img.shields.io/badge/CSS-Handwritten-1572B6?logo=css3&logoColor=white)](https://developer.mozilla.org/en-US/docs/Web/CSS)
[![Mastodon](https://img.shields.io/badge/Mastodon-Instance-6364FF?logo=mastodon&logoColor=white)](https://joinmastodon.org)

A minimalist, file-based web/log engine. Posts are plain JSON files, the
site is a static build, and authoring happens through a CLI/wizard --
no database, no admin server, no PHP.

MIT licensed (see [LICENSE](LICENSE)).

> **Status:** a personal tool, built for and around a single deployment
> ([sean.cz](https://sean.cz)). It's shared as a working reference and is
> usable as-is if your setup matches the assumptions below (single
> author; deploys to Surfer, rsync, git-pages, rclone or a local
> directory) -- see [Roadmap](#roadmap) for what would need to change to
> fit other setups.

| Light | Dark |
| --- | --- |
| ![Homepage, light mode](docs/screenshot-light.png) | ![Homepage, dark mode](docs/screenshot-dark.png) |

*The default blue palette -- both modes come entirely from the 7-key
`colors:` section in `config/site.yml` (see Appearance below).*

## Why this exists

Most static-site generators solve the general case, then make you
configure your way back to something specific. `blog.sh` runs the other
direction: it started from one very specific workflow (write on a phone or
a laptop, publish from a terminal, comments live on Mastodon, nothing
ever calls out to a third-party JS SDK) and grew a CLI, a build, and a
deploy step around exactly that. A few of the choices that came out of it:

- **Posts are typed content blocks, not a Markdown blob rendered at
  request time.** You write Markdown; on save it's parsed once into a
  structured block format (paragraph, heading, quote, list, table, code,
  image, video, link, divider) -- the same schema the historical
  Tumblr/Twitter imports also normalize into. The build never re-parses
  Markdown, and any future importer just has to target one schema.
- **Comments without a comment system.** Every published post is
  auto-announced on Mastodon *or* Bluesky (the site picks exactly one);
  replies to that announcement *are* the comments. The client fetches
  the thread from the network's public API at render time -- no database
  of comments to moderate or migrate, and the "comment count" next to a
  post is just the reply count on its announcement.
- **Deploys default to paranoid.** `scripts/deploy-web.sh` diffs a SHA-256 +
  size + mtime manifest so it only ships what changed, and refuses to
  proceed if the file count swings too far in either direction versus the
  last deploy -- a bad `--prune` run can't silently empty your site.
- **Nothing renders that wasn't asked for.** Sidebar widgets (toots,
  Pixelfed posts, commits, per-post stats) are fetched server-side on a
  cron, never by the visitor's browser -- so there's no client-side call
  to a third party on every page load, and no widget can slow down or
  break the page for a visitor.

## Feature overview

**Content model**
- One post = one JSON file (`content.nosync/posts/<year>/<slug>.json`), no database
- Content is a list of typed blocks (text, heading, quote, list, table,
  code, image, video, link, divider) -- the same block format used by the
  Tumblr/Twitter migration imports
- Inline formatting (bold/italic/strikethrough/code/link) is stored as
  offsets into plain text, not nested HTML
- Media (`media.nosync/<year>/<slug>/`) always lives locally next to its
  post -- no hotlinking to external hosts
- Post states are `published` / `draft`, with a per-post `draft_token`
  for private preview links

**Authoring -- `blog.sh` (CLI and interactive wizard)**
- `add` -- always starts as a draft; after saving, offers a preview and
  a publish / schedule / keep-as-draft / back-to-editing prompt
- `edit <slug>` -- reopens an existing post as Markdown in `$EDITOR`
- `publish <slug>` -- shows a preview before confirming, never publishes blind
- `schedule <slug>` -- automatic publishing (toot included) by a cron step
  when the post's date arrives; the [s] dialog choice asks for the date
  directly, the standalone command takes it from a future-dated draft;
  run again to cancel
- `unpublish <slug>` -- returns a post to draft, deletes its announcement;
  gets a fresh date on the next publish
- `delete <slug>` -- moves to `trash/` (recoverable); `restore <slug>` brings it back
- `toot <slug>` / `bluesky <slug>` -- sends (or resends) the announcement
  after the fact, even for older posts that don't have one yet; never
  overwrites an existing one
- `list [--type=] [--tag=] [--drafts]` -- filtered listing
- `rebuild` -- build and deploy in one step
- Run with no arguments for a numbered interactive menu
- Writing from a phone: a bare filename in `![]()` resolves against
  `incoming/` (an SFTP staging directory), with a wait loop for the file
  to actually arrive before continuing

**Markdown** (`lib/markdown_parser.rb`, shared by both the build and the authoring tool)
- Paragraphs, headings `#`–`######`, bold/italic/strikethrough/code,
  titled links, bare URLs auto-linked, ordered and nested lists,
  blockquotes, horizontal rules, fenced code blocks with a language hint,
  GFM-style aligned tables, images and video (local file or YouTube) with
  automatic sizing, backslash escaping
- The full syntax reference at `/markdown/` is generated directly from
  this parser, so it can't drift out of sync with what's actually supported;
  its source (`templates/markdown-cheat-sheet.<lang>.md`) is localized the
  same way as `locales/*.yml` -- picked by `site.lang`, English fallback

**Build** (`build_blog.rb`)
- Static HTML from JSON via ERB templates, no framework
- Pagination anchored to the oldest post (page boundaries stay stable as
  new posts are added), plus tag and content-type archives
- RSS, sitemap, `robots.txt`
- Search index split into recent (newest 500, loaded eagerly) and
  archive (the rest, loaded lazily on first search)
- Separate generated pages for `/markdown/` (cheat sheet) and `/search/`,
  outside `content/posts/`
- Render memoization -- per-post content/time/type computed once, not
  4-6x across every listing it appears in
- Only changed files are written (`emit`); anything the build didn't
  regenerate this run gets removed afterward (`prune_public`)
- Guards against silent data loss: aborts on a year+slug collision between two posts

**Search**
- Fully client-side, no server round-trip -- `search-index.json` (+ `-archive.json`)
- Quoted phrases, `-word` exclusion, diacritic-insensitive

**Sidebar widgets**
- Latest toots, Pixelfed posts, commits -- fetched server-side on a cron
  (`scripts/refresh-sidebar.sh`), never by the visitor's browser
- Per-post stats (likes/boosts/replies) for announced posts -- live for
  the last 90 days, refreshed weekly beyond that

**Comments**
- No comment system of its own -- every published post is auto-announced
  on Mastodon or Bluesky (exactly one per site, `mastodon:` or `bluesky:`
  in config), and replies to that announcement are the comments
- The client fetches the thread via the network's public API (Mastodon
  context, Bluesky AppView `getPostThread` -- both unauthenticated);
  like/boost/reply counts surface next to the post in listings too
- On Bluesky the announcement fits the 300-grapheme limit with clickable
  link and hashtags (facets); on Mastodon it uses the instance's limit
  (`mastodon.toot_length`, default 500)

**Security**
- Content-Security-Policy via meta tag, self-hosted fonts (no third-party origins)
- Draft URLs use a `SecureRandom` token plus `noindex`
- Consistent escaping of untrusted data (Fediverse display names, avatars) in both HTML and JS
- `env.sh` (secrets) stays out of git, mode `600`
- No third-party tracking scripts in post data

**Deploy**
- `scripts/deploy-web.sh` → a pluggable backend (`DEPLOY_BACKEND` in
  env.sh): Cloudron Surfer (Files API, the default), a local directory,
  rsync over SSH, a git-pages snapshot push (GitHub/GitLab/Codeberg
  Pages), any rclone remote (S3, R2, WebDAV, ...), or plain SFTP; a
  SHA-256 + size + mtime manifest means only new/changed files are
  uploaded
- `--prune` (optional, the one destructive operation), `--dry-run`, `--only=`
- Safety nets against both a sudden drop and a sudden spike in file count
  versus the previous deploy

**Appearance / UX**
- Light/dark theme via CSS custom properties and `prefers-color-scheme`, with a manual toggle
- Lightbox for images, collapsible mobile navigation, photo galleries
  auto-assembled from adjacent image blocks
- No framework -- vanilla JS in small, single-purpose files
- Color scheme is config-driven, not a file to swap: `assets/css/site.css`
  holds only layout/structure, no color values; `config/site.yml`'s
  `colors.light`/`colors.dark` (7 keys each -- bg/text/meta_text/accent/
  nav_bg/border/pill_bg) are compiled at build time into
  `assets/css/colors.css` (see `build_colors_css` in `build/build_blog.rb`).
  Everything else the CSS needs (card background, nav text/border, link/
  badge hover, search input background) is derived from those 7, not
  separately configurable. Defaults to blog.sh's own blue palette
  (`DEFAULT_COLORS`) if `colors:` is omitted
- Banner overlay: `site.short_name` (top-left, ~30px) and `site.description`
  (bottom-right, ~20px, wraps to multiple lines) render on top of the banner
  image in self-hosted JetBrains Mono, with a corner scrim for readability
  against any image -- see `.banner-title`/`.banner-claim` in `site.css`

**Migration** (historical, one-off)
- `migrate_tumblr.rb`, `migrate_twitter.rb` -- import from four Tumblr
  blogs and a Twitter archive (2008-2022) into the same content-block schema

## Stack

- **Build:** Ruby (`build/build_blog.rb`)
- **Authoring:** a Ruby CLI/wizard (`scripts/manage_post.rb`, run via `./blog.sh`)
- **Templates:** ERB (`templates/`)
- **i18n:** `locales/*.yml` + `lib/i18n.rb` -- ships with English (default)
  and Czech; add another `locales/<code>.yml` for a different language,
  missing keys fall back to English
- **Deploy:** pluggable backends (`lib/deploy_backend/`) -- Cloudron
  Surfer (Files API), a local directory, rsync, git-pages, rclone, or
  SFTP; `scripts/deploy_web.rb`
- **Sidebar widgets:** entirely optional, `lib/*_fetcher.rb` + `lib/sidebar.rb`

## Structure

```
blog.sh                  Main tool -- CLI and interactive wizard (see below)
build/                   Build script (JSON posts -> static HTML)
scripts/                 Ruby CLI, import/deploy scripts, and their .sh wrappers:
                           deploy-web.sh      standalone deploy of public.nosync/ to Surfer (no rebuild)
                           refresh-sidebar.sh cron: refreshes only the sidebar widgets (no site rebuild)
lib/                     Shared Ruby libraries (Surfer client, fetchers, post writer, i18n, ...)
locales/                 UI strings for the generated site and the CLI (en.yml, cs.yml)
templates/               ERB templates (layout, post, index, search, partials)
                         + markdown-cheat-sheet.<lang>.md, the /markdown/ page's source
assets/                  CSS/JS/fonts (drop your own images into assets/images/)
config/site.yml.example  Documented config template -- copy to config/site.yml (gitignored) per deployment
env.sh.example           Documented secrets/env template -- copy to env.sh (gitignored) per deployment
docs/                    Install & operations guides, plus this README's screenshots

content.nosync/, media.nosync/, public.nosync/, incoming/, trash/, drafts/, env.sh, config/site.yml
                         Per-deployment/generated, not part of the engine -- see .gitignore
```

`content.nosync/posts/` (the posts themselves) and `media.nosync/` (their
images/videos) are deliberately **not** part of this repo: they're personal
content, not code, specific to whoever deploys this engine for their own
site. Likewise `config/site.yml` -- only the documented
`config/site.yml.example` template is committed. The `.nosync` suffix also
excludes both directories from iCloud sync on a Mac; on a server, where
iCloud doesn't exist, it's just a name.

## Requirements

- **Ruby 3.0+**, standard library only -- no gems, no Bundler, nothing to install
- **bash** (the thin `blog.sh` / `deploy-web.sh` / `refresh-sidebar.sh` wrappers)
- Optional, per integration: somewhere to deploy to (a
  [Cloudron Surfer](https://cloudron.io) app, any rsync/SSH host, a
  GitHub/GitLab/Codeberg Pages branch, an rclone remote, or just a local
  directory served by your own web server), a Mastodon or Bluesky
  account for comments and the auto-announcement, cron for the sidebar
  widgets

## Getting started

1. Copy `config/site.yml.example` to `config/site.yml` and fill in your
   site's title, description, social links, and (optionally) analytics,
   sidebar widgets, and Mastodon integration.
2. Copy `env.sh.example` to `env.sh` and `chmod 600 env.sh`. An unedited
   copy is enough to try things out locally -- without the Surfer values,
   uploads are simply skipped (logged, not an error).
3. Drop a banner image at the path set in `banner.src` (and a favicon at
   `/assets/images/favicon.png`).
4. `./blog.sh add` to write your first post.
5. `ruby build/build_blog.rb` to build, or `./blog.sh rebuild` to build and deploy.
6. To preview locally before deploying, point any static file server at
   `public.nosync/`, e.g. `ruby -run -e httpd public.nosync/ -p 8000`.

Every integration beyond the core (analytics, each sidebar widget,
Mastodon comments/auto-toot) is optional and activates only when its
config section is present -- a minimal `site.yml` with just `site`,
`banner`, `about` and `footer` is a complete, working site.

That's the short path. The complete one -- server install, every deploy
backend step by step, the phone workflow, Mastodon setup -- is
[docs/install.md](docs/install.md); day-to-day usage (publishing,
cron, backup, troubleshooting) is
[docs/operations.md](docs/operations.md).

## `blog.sh` -- authoring

```bash
./blog.sh                      # interactive wizard (menu)
./blog.sh add                  # creates a draft, shows a preview, asks what's next
./blog.sh edit [<slug>]        # without a slug, offers the last 10 posts
./blog.sh publish [<slug>]     # shows the draft's preview, asks what's next
./blog.sh schedule [<slug>]    # auto-publish a future-dated draft when its date arrives
./blog.sh unpublish [<slug>]   # moves a published post back to draft (also deletes its announcement)
./blog.sh delete [<slug>]      # deletes a post to trash/
./blog.sh restore [<slug>]     # restores a post from trash
./blog.sh toot [<slug>]        # (re-)sends the comment toot (Mastodon sites)
./blog.sh bluesky [<slug>]     # (re-)sends the announcement (Bluesky sites)
./blog.sh rebuild              # rebuilds and deploys the whole site
./blog.sh list [--type=image] [--tag=foo] [--drafts]
./blog.sh help
```

## Configuration (`env.sh`, per-deployment, never in git)

Copy [`env.sh.example`](env.sh.example) to `env.sh` (gitignored) and fill it
in -- `chmod 600 env.sh`, since it holds live credentials. It lives wherever
the site is built from: on a server for a deployed site, or just on your
laptop for a local one.

```bash
export SITE_BASE_URL=https://example.com
export MASTODON_ACCESS_TOKEN=...   # comment toots (optional)
export TUMBLR_API_KEY=...          # only for scripts/migrate_tumblr.rb
export DEPLOY_BACKEND=...          # surfer (default) | local | rsync | git | rclone | sftp
export SURFER_URL=...              # surfer backend
export SURFER_TOKEN=...
export SURFER_REMOTE_DIR=...
export DEPLOY_TARGET_DIR=...       # local backend
export RSYNC_TARGET=...            # rsync backend (+ optional RSYNC_SSH)
export GIT_PAGES_REMOTE=...        # git backend (+ optional GIT_PAGES_BRANCH/_CNAME)
export RCLONE_TARGET=...           # rclone backend (+ optional RCLONE_ARGS)
export SFTP_TARGET=...             # sftp backend (+ optional SFTP_REMOTE_DIR/SFTP_ARGS)
```

## Importing existing content

`scripts/migrate_tumblr.rb <blog-name>.tumblr.com` and
`scripts/migrate_twitter.rb <path-to-extracted-export>` import posts from
Tumblr's API or a Twitter/X archive export into the same content-block
schema as hand-written posts, downloading all media locally.

## Deploy

```bash
ruby build/build_blog.rb   # rebuild into public.nosync/
./scripts/deploy-web.sh            # uploads only new/changed files (SHA256 manifest)
./scripts/deploy-web.sh --prune    # also deletes orphaned files on Surfer
```

`./blog.sh rebuild` does both steps at once.

### Cron (sidebar widgets and post stats)

The sidebar widgets and per-post stats are refreshed by
`scripts/refresh-sidebar.sh` -- it fetches the data, rewrites only the
four JSON files and uploads just those, no site rebuild. Run it from cron
wherever the site is built:

```
*/30 * * * * /path/to/blog.sh/scripts/refresh-sidebar.sh
```

Every 30 minutes is plenty -- the data it refreshes (recent toots,
Pixelfed posts, commits, like/boost counts) doesn't move faster than
that. Skip the cron entirely if no widgets are configured.

A second, optional job powers `./blog.sh schedule` -- it publishes
scheduled drafts whose date has arrived (and does nothing otherwise):

```
*/15 * * * * /path/to/blog.sh/scripts/publish-scheduled.sh
```

## Roadmap

Things that currently assume this exact deployment and would need
generalizing for anyone else to adopt this as-is:

- **Imports** -- `migrate_tumblr.rb` and `migrate_twitter.rb` cover the two
  platforms this deployment actually migrated from. Instagram, WordPress,
  Threads and Bluesky importers should follow the same pattern: each
  platform's official export (or API) normalized into the shared
  content-block schema via `PostWriter`, media downloaded locally, nothing
  hotlinked. A generic RSS/Atom importer would cover much of the long tail
  (Ghost, Medium, Blogger, ...) -- and since WordPress's WXR export is
  essentially enriched RSS, the two could share a base.
- **More comments backends** -- Mastodon and Bluesky are in
  (`lib/mastodon_poster.rb` / `lib/bluesky_poster.rb`, one network per
  site). Twitter/X and Threads remain worth investigating -- same
  "replies to the announcement post are the comments" model, but the API
  reality differs: X's API is paid and Threads' needs an app token, so
  those threads would likely have to be fetched server-side on a cron
  (the way `stats.json` already works), not by the visitor's browser.
- **More sidebar widgets** -- today's three (Mastodon toots, Pixelfed,
  GitHub commits) are each independently optional; recent posts from
  Bluesky, Instagram, Threads or Twitter/X would follow the same fetcher
  pattern (server-side, cron, same-origin JSON). Honest caveat: it's not
  yet clear which of these are actually feasible -- Bluesky's public API
  makes it straightforward, while Instagram, Threads and X all gate or
  charge for read access, so some may only be possible with an app token,
  or not at all.

## Example deployment

This engine was extracted from the codebase powering
[sean.cz](https://sean.cz), Daniel Šnor's personal blog -- a reference for
what a fully-configured deployment (all optional integrations enabled)
looks like in practice.