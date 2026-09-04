# blog.sh — .sh → .rb → .html

![sh → .rb → .html](https://blogsh.app/assets/images/header.png)

*minimalistic static web/log cms*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-CLI_wrapper-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ruby](https://img.shields.io/badge/Ruby-Pure_stdlib-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![JSON](https://img.shields.io/badge/JSON-Content_format-000000?logo=json&logoColor=white)](https://www.json.org)
[![HTML](https://img.shields.io/badge/HTML-ERB_templates-E34F26?logo=html5&logoColor=white)](https://developer.mozilla.org/en-US/docs/Web/HTML)
[![CSS](https://img.shields.io/badge/CSS-Handwritten-1572B6?logo=css3&logoColor=white)](https://developer.mozilla.org/en-US/docs/Web/CSS)
[![Mastodon](https://img.shields.io/badge/Mastodon-Instance-6364FF?logo=mastodon&logoColor=white)](https://joinmastodon.org)
[![Bluesky](https://img.shields.io/badge/Bluesky-Comments-0285FF?logo=bluesky&logoColor=white)](https://bsky.social)

A minimalist, file-based web/log engine. Posts are plain JSON files, the
site is a static build, and authoring happens through a CLI/wizard --
no database, no admin server, no PHP.

> **Who it's for:** one person writing their own blog, at home in a
> terminal, who wants to own the whole archive -- including everything
> they already wrote somewhere else. Twenty-two
> [import sources](#importing-existing-content) bring it in, from a
> WordPress export to a blog whose platform no longer exists. It deploys
> to Surfer, rsync, git-pages, rclone, SFTP or a local directory.
>
> **Who it isn't for:** several authors sharing one site, anyone who
> needs a web admin interface, or a workflow where publishing isn't a
> command. It grew around a single deployment
> ([sean.cz](https://sean.cz)) and still fits that shape best, but it
> installs and runs as-is -- `setup.sh` asks the questions, and
> [blogsh.app](https://blogsh.app) is a second site running the same
> unmodified engine.

**See it running:** [blogsh.app](https://blogsh.app) is this engine
publishing its own documentation -- every page there was built and
deployed by `./blog.sh` itself.

MIT licensed (see [LICENSE](LICENSE)); the fonts and brand marks it
ships belong to other people, and [NOTICE](NOTICE) says who.

| Light | Dark |
| --- | --- |
| ![Homepage, light mode](docs/screenshot-light.png) | ![Homepage, dark mode](docs/screenshot-dark.png) |

*The default blue palette -- both modes come entirely from the 7-key
`colors:` section in `config/site.yml` (see
[install.md → The palette and the header's type](docs/install.md#the-palette-and-the-headers-type)).*

**Contents:** [Why this exists](#why-this-exists) ·
[What it does](#what-it-does) · [Stack](#stack) · [Structure](#structure) ·
[Requirements](#requirements) · [Getting started](#getting-started) ·
[Authoring](#blogsh----authoring) ·
[Configuration](#configuration-envsh-per-deployment-never-in-git) ·
[Importing existing content](#importing-existing-content) ·
[Exporting](#exporting) ·
[Deploy](#deploy) · [Roadmap](#roadmap) ·
[Example deployments](#example-deployments)

## Why this exists

The build, the authoring tool and the deploy step are one program, built
around one workflow rather than around the general case.

- **A static generator.** One build, plain files out. No database, no
  server, no request-time rendering.
- **Markdown is the form you write in, not what is stored.** On save it is
  parsed once into typed blocks -- paragraph, heading, quote, list, table,
  code, image, video, audio, chat, link, divider. The build never parses
  Markdown again, and every importer targets that one schema.
- **The Fediverse is the comment system.** A published post is announced
  on Mastodon or Bluesky; replies to that announcement are the comments,
  fetched from the network's public API. Nothing to moderate, migrate or
  host. Favourite a reply to publish it (`comments.approval: fav`).
- **The archive is a directory of JSON files.** One post, one file. It is
  readable, greppable and backed up by copying it.
- **Authoring is a command.** `./blog.sh` writes, edits, publishes,
  schedules and deploys. A phone writes at `/write/` and sends over SSH.
- **The deploy is paranoid.** A SHA-256 manifest ships only what changed,
  and refuses when the file count or the byte total swings too far from
  the last build it accepted.
- **Nothing calls a third party from the reader's browser.** Sidebar
  widgets are fetched server-side on a cron.

What you give up: themes, plugins, and a second author.


## What it does

Each part says where it is described in full.

- **Content.** One post is one JSON file, `content.nosync/posts/<year>/<slug>.json`, holding typed blocks. Drafts, scheduled posts, pages, unlisted posts, series, tags and a trash with restore. → [architecture.md](docs/architecture.md#content-model)
- **Writing.** `./blog.sh` bare is a menu; every command also works directly: add, edit, publish, schedule, unpublish, delete, restore, rename, re-announce. `add <file>` takes a markdown file and asks nothing; `--json` answers as one object. → [operations.md](docs/operations.md#writing-and-publishing)
- **From a phone.** `/write/` is a page on the blog itself: title, text, tags, photographs, video. It sends over the SSH the server already has, publishes, and polls for the answer. → [operations.md](docs/operations.md#writing-from-a-phone)
- **Markdown.** One parser, shared by the build and the authoring tool, with a cheat sheet the parser generates for your own site at `/markdown/`. Editing a post round-trips through it. → [operations.md](docs/operations.md#writing-and-publishing)
- **Search, and the other ways to find a post.** Full text over the whole archive, entirely in the
  reader's browser -- no server, no index service, nothing called from outside, on a site of any
  size. Quoted phrases, `-word` to exclude, and diacritics never decide a match, so *nemecko*
  finds *Německo*. The index is split so the page is not made to wait for it: the recent half
  loads with the page, the archive only when a search reaches past it -- on a 6,600-post site,
  432 kB against 4.3 MB. Beside it, `/archive/` maps the whole site in two levels and `/tag/`
  lists every tag with its count. → [architecture.md](docs/architecture.md#the-client-side),
  [operations.md](docs/operations.md#reading-the-archive)
- **Build.** Static HTML from JSON through ERB templates: stable pagination, tag, series and type archives, RSS, sitemap, `robots.txt`, a generated favicon, a 404 in the site's own chrome. A page whose inputs have not moved is not rendered again. → [architecture.md](docs/architecture.md#build-pipeline-buildbuild_blogrb)
- **Deploy.** Cloudron Surfer, a local directory, rsync over SSH, a git-pages push, any rclone remote, or SFTP. A SHA-256 manifest ships only what changed and refuses a build that swings too far from the last one. → [operations.md](docs/operations.md#deploying)
- **Comments.** The announcement's replies are the thread; `comments.approval: fav` publishes only the ones you favourite. → [Why this exists](#why-this-exists)
- **Sidebar widgets.** Toots, Bluesky posts, Pixelfed posts, commits, any RSS feed, per-post stats -- each optional, all fetched server-side on a cron. → [operations.md](docs/operations.md#cron-sidebar-widgets-and-post-stats)
- **Appearance.** Light and dark from CSS custom properties, a three-state toggle, and a seven-key palette in `config/site.yml` that the wizard previews before writing. A listing card is cut to a size budget as it is written rather than drawn in full and hidden with CSS. → [install.md](docs/install.md#the-palette-and-the-headers-type)
- **Reachable without a mouse.** One focus ring for the whole site, skip links, and motion that respects `prefers-reduced-motion`. → [architecture.md](docs/architecture.md#the-client-side)
- **Security.** A Content-Security-Policy on every page, self-hosted fonts, nothing third-party in post data, `env.sh` out of git at mode 600. → [architecture.md](docs/architecture.md#security)
- **Importing.** Twenty-two sources through `./import.sh`, always previewed in dry-run before anything is written, landing in the same schema as a hand-written post. → [importing.md](docs/importing.md)
- **Exporting.** The archive leaves as markdown with front matter, or as JSON. → [operations.md](docs/operations.md#taking-your-content-elsewhere)


## Stack

- **Build:** Ruby (`build/build_blog.rb`)
- **Authoring:** a Ruby CLI/wizard (`scripts/manage_post.rb`, run via `./blog.sh`)
- **Templates:** ERB (`templates/`)
- **i18n:** `locales/*.yml` + `lib/i18n.rb` -- ships with English (default),
  Czech and German; add another `locales/<code>.yml` for a different
  language, missing keys fall back to English
- **Deploy:** pluggable backends (`lib/deploy_backend/`) -- Cloudron
  Surfer (Files API), a local directory, rsync, git-pages, rclone, or
  SFTP; `scripts/deploy_web.rb`
- **Sidebar widgets:** entirely optional, `lib/*_fetcher.rb` + `lib/sidebar.rb`

## Structure

```
blog.sh                  Main tool -- CLI and interactive wizard (see below)
setup.sh                 Setup wizard -- identity, address, comments network, deploy target
style.sh                 Appearance wizard -- palette, banner, menu, about, footer, sidebar
import.sh                Import wizard -- pick a source, preview, confirm (see below)
build/                   Build script (JSON posts -> static HTML)
scripts/                 Ruby CLI, import/deploy scripts, and their .sh wrappers:
                           deploy-web.sh      standalone deploy of public.nosync/ to the configured target (no rebuild)
                           refresh-sidebar.sh cron: refreshes only the sidebar widgets (no site rebuild)
                           publish-scheduled.sh cron: publishes whatever the queue has come due
                           receive.sh         takes a whole post over one SSH connection into incoming/
                           migrate_*.rb       one per import source, scriptable alternative to import.sh
lib/                     Shared Ruby libraries (Surfer client, fetchers, post writer, i18n, ...)
lib/import/              Import adapters plus the layer they share (media, run, CLI)
locales/                 UI strings for the generated site and the CLI (en.yml, cs.yml, de.yml)
templates/               ERB templates (layout, post, index, search, partials)
                         + markdown-cheat-sheet.<lang>.md, the /markdown/ page's source
assets/                  CSS/JS/fonts (drop your own images into assets/images/)
write/                   The page served at /write/ when write: true -- the editor itself, its
                         locale sources and the script that turns them into i18n.js
config/site.yml.example  Documented config template -- copy to config/site.yml (gitignored) per deployment
env.sh.example           Documented secrets/env template -- copy to env.sh (gitignored) per deployment
docs/                    Install, operations, importing, architecture, decisions, skinning and
                         localization guides; this README's screenshots; and shortcuts/,
                         the two iOS shortcuts that send a post from a phone

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

- **Ruby 2.7+** (3.x recommended), standard library only -- no gems, no Bundler, nothing to
  install. One caveat: the optional Pixelfed/RSS sidebar widgets use
  `rexml`, a Ruby *default gem* (ships with a normal Ruby install, but
  some distro package splits leave it out -- see
  [install.md](docs/install.md#what-you-need) if `gem install rexml`
  is ever needed). Importing needs it for real: every XML source --
  WordPress, Blogger, Squarespace, podcasts, any RSS or Atom feed, the
  Wayback rescue and LiveJournal -- reads through `rexml`
- **bash** (the thin `blog.sh` / `deploy-web.sh` / `refresh-sidebar.sh` wrappers)
- Optional, per integration: somewhere to deploy to (a
  [Cloudron Surfer](https://cloudron.io) app, any rsync/SSH host, a
  GitHub/GitLab/Codeberg Pages branch, an rclone remote, or just a local
  directory served by your own web server), a Mastodon or Bluesky
  account for comments and the auto-announcement, cron for the sidebar
  widgets -- and, only if you turn on `media.convert_heic` (converting
  iPhone HEIC photos to JPEG on save), an image tool the machine
  typically already has: `sips` (built into macOS), `heif-convert`,
  ImageMagick or vips. Off by default; without a tool the engine refuses
  the file with instructions instead of breaking. `media.remux_video`
  (repacking a phone video so it starts playing before it has finished
  downloading) asks for ffmpeg in the same spirit: off by default, and
  without it the post is saved anyway

## Getting started

With Ruby 2.7+ on the machine. Coming from zero, there is a copy-paste
path per platform in [install.md → Quick start](docs/install.md#quick-start).

```bash
./setup.sh                 # title, address, timezone, comments network, deploy target
./style.sh                 # palette, banner, bio, footer, sidebar
./blog.sh doctor           # is the configuration sound?
./blog.sh add              # write the first post
./blog.sh rebuild          # build and deploy
./blog.sh preview          # or look at it locally first, on :8000
```

Both wizards show a diff and write nothing until you confirm, and
re-running either is how you change any of it later. By hand instead:
copy `config/site.yml.example` and `env.sh.example` (`chmod 600 env.sh`)
and edit them -- an unedited pair is already a working local site.

Everything beyond the core -- analytics, each sidebar widget, comments and
the announcement -- activates only when its config section is present.
Replace `assets/images/favicon.png` with your own artwork; it and the
banner are gitignored, so they survive `git pull` and nothing else keeps a
copy of them.

The whole path -- server install, every deploy backend, the phone
workflow, the comments network -- is [install.md](docs/install.md);
day-to-day usage is [operations.md](docs/operations.md). What changed
between versions is [CHANGELOG.md](CHANGELOG.md), and `./blog.sh version`
says what you are running.


## `blog.sh` -- authoring

```bash
./blog.sh                      # interactive wizard (menu)
./blog.sh add [<file>] [--json] [--untrusted]
                               # creates a draft, shows a preview, asks what's next;
                               # with a markdown file it asks nothing, and --json answers as data;
                               # --untrusted refuses a picture reference that is not a bare filename
./blog.sh edit [<slug>]        # without a slug, offers the last 50 posts
./blog.sh props [<slug>]       # a post's state and its actions; [e] changes what the post IS --
                               # its series and part, tags, type, and the unlisted/hero/toc flags
./blog.sh publish [<slug>] [--yes] [--no-announce] [--json]
                               # shows the draft's preview, asks what's next;
                               # --yes publishes without asking, --no-announce keeps it off Mastodon and Bluesky;
                               # --json (with --yes) answers as one object, for a script or a phone
./blog.sh schedule [<slug>]    # asks for a date, then auto-publishes the draft when it arrives
./blog.sh queue                # what is scheduled, when each one goes, and the slots it uses
./blog.sh unpublish [<slug>]   # moves a published post back to draft (also deletes its announcement)
./blog.sh delete [<slug>]      # deletes a post to trash/
./blog.sh restore [<slug>]     # restores a post from trash
./blog.sh empty trash          # deletes everything in the trash, for good
./blog.sh empty versions       # keeps each post's newest version, removes the older ones
./blog.sh toot [<slug>]        # (re-)sends the comment toot (Mastodon sites)
./blog.sh bluesky [<slug>]     # (re-)sends the announcement (Bluesky sites)
./blog.sh rebuild [--full]     # rebuilds and deploys the whole site;
                               # --full builds every page again instead of only the changed ones
./blog.sh preview [<port>]     # serves public.nosync locally (default 8000)
./blog.sh browse [--type=image] [--tag=foo] [--drafts]
                               # the archive on screen: filters, search, preview, Enter opens the post
./blog.sh list [--type=image] [--tag=foo] [--drafts]
                               # the same, printed one line per post
./blog.sh doctor [--online]    # reads the configuration and says what is wrong with it
./blog.sh doctor --strip-location
                               # removes the place of capture from photos already in the archive
./blog.sh check [--online] [--json] [--repair]
                               # walks the archive and says what is broken in it;
                               # --json prints every finding as data instead of a screenful;
                               # --repair offers, per finding, the one repair that finding allows
./blog.sh export [<dir>] [--no-drafts] [--dry-run] [--force]
                               # writes the whole archive out as a tree of markdown files
./blog.sh stats [--json]       # counts the archive: posts by year and kind, words, tags, media, sources
./blog.sh version              # which version this installation is running
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
export TUMBLR_API_KEY=...          # importing a Tumblr blog (wizard or script)
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

```bash
./import.sh                        # pick a source, preview, confirm
```

An imported post is indistinguishable from one you typed: same block
schema, media downloaded locally. The wizard previews in dry-run before it
writes, and re-running is safe -- posts are matched on their source id and
overwritten in place.

| Source | Needs | Scope |
| --- | --- | --- |
| beehiiv | the posts CSV export | newsletters and drafts; paid issues arrive as drafts |
| Blogger | the Atom backup file | posts and drafts; comments skipped, images at full size |
| Bluesky | nothing (public API) | your standalone posts; replies, reposts, quotes skipped |
| Facebook | an unpacked export | your posts with their photos and video; crossposts skipped |
| Ghost | the JSON export + the live site's URL | every post and page, drafts included |
| Instagram | an unpacked export | your grid and IGTV; stories and archived posts skipped |
| Jekyll/Hugo | the site tree (or any markdown folder) | posts and drafts with front matter; relative image paths come from the tree, absolute URLs download one request each -- import while the old host answers |
| LiveJournal | `LJ_PASSWORD` | every entry via the API; friends-only arrive as drafts |
| Mastodon | an unpacked account archive | standalone posts; boosts and replies skipped |
| Medium | an unpacked export | posts and drafts; responses to others become drafts |
| Movable Type/TypePad | the MT export file | posts and drafts; redirects need a URL pattern |
| Pixelfed | a statuses export | standalone posts with their photos |
| Podcast | a feed URL | every episode, audio and artwork hosted locally |
| Squarespace | the "WordPress format" XML export | posts, drafts and pages, feature images included |
| Substack | an unpacked export | newsletters and podcasts; paid posts tagged `substack-paid` |
| Threads | an unpacked export | your standalone posts; replies to others skipped |
| Tumblr | `TUMBLR_API_KEY` | every published post; a reblog keeps its trail |
| Twitter/X | an extracted archive export | standalone tweets; replies, RTs and quotes skipped |
| Wix | the blog CSV export | posts and drafts; unsupported node types counted by name |
| Wayback Machine | the dead blog's old URL | whatever the Archive saved, reassembled oldest-first |
| WordPress | a WXR export file | every post and page with its featured image and captions |
| RSS/Atom | a feed URL | whatever the feed carries, usually its last few dozen items |

One thing to decide before the first run: `KEEP_PERMALINKS=1` writes the
`redirect_from` list that keeps the old site's links working. Without it an
archive imports with no redirects at all, and the only way back is another
import.

What each source skips and why, the traps per platform, the variables, the
non-interactive form and how to undo an import: [importing.md](docs/importing.md).


## Exporting

```bash
./blog.sh export [<dir>] [--no-drafts] [--dry-run] [--force]
```

An archive you cannot take with you is not yours. The whole thing comes
out as markdown with YAML front matter, in the layout most other engines
read -- and `./import.sh` reads that tree back, posts keeping their
identity, series, redirects and media, so export plus re-import is also
how an installation moves.
→ [operations.md](docs/operations.md#taking-your-content-elsewhere)


## Deploy

```bash
ruby build/build_blog.rb   # rebuild into public.nosync/
./scripts/deploy-web.sh            # uploads only new/changed files (SHA256 manifest)
./scripts/deploy-web.sh --prune    # also deletes orphaned files on the target
```

`./blog.sh rebuild` does both steps at once.

### Cron (sidebar widgets and post stats)

The sidebar widgets and per-post stats are refreshed by
`scripts/refresh-sidebar.sh` -- it fetches the data, rewrites only the
JSON files (six at most: toots, Pixelfed, commits, Bluesky, RSS, stats)
and uploads just the ones the site's configured widgets produce, no site
rebuild. Run it from cron wherever the site is built:

```
*/30 * * * * /path/to/blog.sh/scripts/refresh-sidebar.sh
```

Every 30 minutes is plenty -- the data it refreshes (recent toots,
Pixelfed posts, commits, like/boost counts) doesn't move faster than
that. Skip the cron entirely if no widgets are configured -- unless
comments are moderated (`comments.approval: fav`): approved replies
reach the site through this same job (it writes `comments.json` too),
so a moderated site needs it with or without widgets.

A second, optional job powers `./blog.sh schedule` -- it publishes
scheduled drafts whose date has arrived (and does nothing otherwise):

```
*/15 * * * * /path/to/blog.sh/scripts/publish-scheduled.sh >/dev/null
```

## Roadmap

What is not built, and why.

- **Imports.** Twenty-two sources are covered; a new one needs an adapter
  with three methods, because media, dedup, dry-run and reporting are
  shared. Not everything in the table has been leaned on equally: pages
  from Squarespace and Substack rest on sample exports, and LiveJournal
  has never run against the live service, since it has no export file and
  the adapter talks to the API.
- **Comments on X: rejected.** Since February 2026 the API bills per use
  -- reads $0.005 each, no public access -- so an announcement plus a
  continuously re-fetched thread would cost money forever on a personal
  blog.
- **Comments on Threads: feasible, deferred.** The free API can publish
  and read replies to your own posts, but only server-side: a Meta
  developer app, an OAuth dance, 60-day tokens with a refresh cron, and
  comments cached into JSON on a timer instead of the live threads
  Mastodon and Bluesky give the reader's browser for nothing. Sketched;
  waiting for real demand. Scraping it instead is rejected outright --
  it breaks without warning and risks the user's account.


## Example deployments

[sean.cz](https://sean.cz) is the blog this engine was extracted from --
Daniel Šnor's own, and the reference for what a fully configured
deployment looks like.

[blogsh.app](https://blogsh.app) is the project's own site, running the
same unmodified engine and publishing its documentation as ordinary posts.

[blog.elegantlich.com](https://blog.elegantlich.com) is the first
deployment in hands other than the author's -- the planning blog of the
*Elegant Lich* magazine. Its owner's first-install feedback is in the
engine: an announcement that cannot happen now says why.

[arch-linux.cz](https://arch-linux.cz) is the community blog of the Czech
Arch Linux user group: the stock engine under its own stylesheet, no
template edits, and the first site to pair it with GoToSocial -- which is
where the GoToSocial comments in 1.4 were found.

[blog.oscloud.cz](https://blog.oscloud.cz) is the news blog of OSCloud, a
Czech self-hosting community, skinned the same way. The tag index and the
copy button on code blocks were both their requests -- a blog of terminal
how-tos wanted them first.

[archive.bierfaristo.com](https://archive.bierfaristo.com) is the largest
archive we know of running this engine, some 13,700 posts -- a working
answer to "does it scale". Its owner has reported more than anyone else
outside.
