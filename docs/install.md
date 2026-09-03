# Installing blog.sh

From zero to a deployed site. The [main README](../README.md) is the
quick tour; this is the complete path, including the server side.
Day-to-day usage lives in [operations.md](operations.md).

In a hurry? The [Quick start](#quick-start) below is a complete
copy-paste path to a site running locally on your machine -- one block
per platform. The numbered sections after it are the full reference,
including [picking a deploy target](#6-pick-a-deploy-target) to put the
site on the internet.

## What you need

- **Ruby 2.7+** (3.x is what the real deployments run) -- standard
  library only, no gems, no Bundler. Check with `ruby -v`; `blog.sh`
  checks too and says exactly this if the interpreter is too old.
- **bash** -- for the thin `blog.sh` / `deploy-web.sh` /
  `refresh-sidebar.sh` wrappers. (On Windows that means WSL2 -- see the
  quick start; there is no native cmd/PowerShell path.)
- **A place to serve static files** -- any of the six deploy targets
  below, from a Cloudron Surfer app to a plain directory behind your own
  nginx/Caddy.
- Optional: a **Mastodon or Bluesky account** (comments, auto-announce,
  sidebar widgets) and **cron** (widget refresh, scheduled publishing).
- Optional, only with `media.convert_heic: true` (converting iPhone HEIC
  photos to JPEG on save): an image tool the machine typically already
  has -- `sips` is part of macOS; on Linux any of `heif-convert`
  (libheif-examples), ImageMagick with the HEIF delegate, or vips.
  Without one, the engine refuses the file with instructions instead of
  breaking; off by default.
- Optional, only with `media.remux_video: true` (moving a video's index to
  the front of the file, and out of the QuickTime container, on save):
  **ffmpeg**. Without it the post is still saved and the engine names the
  command instead; off by default.

## Quick start

Each block below is the whole path for one platform: prerequisites,
clone, config, first post, local preview. They end at the same place --
a site you can see at `http://localhost:8000/` -- and from there,
[section 6](#6-pick-a-deploy-target) takes it to the internet.

`./setup.sh` is the config step: it asks for the settings a site needs,
checks the answers as it goes, and writes `config/site.yml` and `env.sh`
for you. Every question can be skipped with Enter, and nothing is
written until you have seen the diff and confirmed it -- so it is also
the way to change any of this later. If you would rather edit the files
yourself, the numbered sections below are the full reference and
[section 2](#2-configure-the-site----configsiteyml) still starts with
the two `cp` commands; the wizard leaves both files commented and
hand-editable either way.

### macOS

The system Ruby is 2.6 from 2019 and Apple treats it as frozen, so the
one real step is a current Ruby via [Homebrew](https://brew.sh):

```bash
brew install ruby
echo 'export PATH="/opt/homebrew/opt/ruby/bin:$PATH"' >> ~/.zshrc
exec zsh
ruby -v    # 3.x now, not 2.6.10
```

(That PATH line is for Apple Silicon; on an Intel Mac it's
`/usr/local/opt/ruby/bin`. `brew install ruby` prints the exact line for
your machine at the end of its output -- trust that one.)

(No Homebrew yet? Install it first with the one command on
[brew.sh](https://brew.sh). `git` is already there on any Mac with the
Xcode Command Line Tools -- macOS offers to install them the first time
you type `git`.)

Then:

```bash
git clone https://github.com/DanielSnor/blog.sh.git myblog
cd myblog
./setup.sh           # a few questions -> config/site.yml and env.sh
./blog.sh add        # write the first post; publish or keep as draft
./blog.sh preview    # -> http://localhost:8000/  (Ctrl-C stops it)
```

The system nano is as old as the system Ruby -- if the editor step
complains about options, set your own: `export EDITOR=vim` (or `code -w`,
or plain `nano`).

### Linux (Debian/Ubuntu shown; any distro works)

```bash
sudo apt update && sudo apt install -y ruby-full git
```

(`ruby-full` rather than the bare `ruby` -- see the default-gems note
below. On Fedora: `sudo dnf install ruby`; on Arch: `sudo pacman -S ruby` --
both already complete.)

```bash
git clone https://github.com/DanielSnor/blog.sh.git myblog
cd myblog
./setup.sh           # a few questions -> config/site.yml and env.sh
./blog.sh add        # write the first post; publish or keep as draft
./blog.sh preview    # -> http://localhost:8000/  (Ctrl-C stops it)
```

### Windows

blog.sh's wrappers are bash, so on Windows it runs inside **WSL2** --
Microsoft's Linux environment, one command to set up. In PowerShell
**as Administrator**:

```powershell
wsl --install
```

Reboot when asked; Ubuntu opens and asks you to pick a username. From
that Ubuntu terminal, it's the Linux path verbatim:

```bash
sudo apt update && sudo apt install -y ruby-full git
git clone https://github.com/DanielSnor/blog.sh.git myblog
cd myblog
./setup.sh           # a few questions -> config/site.yml and env.sh
./blog.sh add        # write the first post; publish or keep as draft
./blog.sh preview    # -> http://localhost:8000/  (Ctrl-C stops it)
```

Two Windows-specific notes: clone into the Linux home (`~/myblog`, as
above), not `/mnt/c/...` -- file permissions (`chmod 600` on your
tokens) and speed only work properly on the Linux side; and
`http://localhost:8000/` works straight from your Windows browser, WSL2
forwards it. Git Bash instead of WSL2 mostly runs too, but the
interactive menus degrade (mintty isn't a TTY to a native Ruby),
non-ASCII output is garbled until the console is switched to UTF-8
(`chcp 65001`), and `chmod` protects nothing on NTFS -- with real tokens
in env.sh, WSL2 is the supported route.

The engine has no build-time network dependencies: a machine with Ruby
and bash can build the whole site offline.

**On "no gems" and default gems.** Everything in blog.sh is written
against Ruby's core standard library -- nothing to `gem install`,
ever, for the engine itself to run. The one nuance: the optional
Pixelfed/RSS sidebar widgets parse XML with `rexml`, which Ruby ships
as a *default gem* -- bundled with a normal `ruby` install, but some
Linux distributions split their Ruby package and leave default gems
out of the minimal one. Importing is not optional about it: every XML
source reads through `rexml`, which is WordPress, Blogger,
Squarespace, podcasts, any RSS or Atom feed, the Wayback rescue and
LiveJournal. If none of that is in your way -- no XML import, no
`widgets.pixelfed`/`widgets.rss` -- it never comes up; if it is, and
you see a `LoadError` about `rexml`, either `gem install rexml` or install your distro's
fuller Ruby package -- e.g. `ruby-full` instead of the bare `ruby` on
Debian/Ubuntu (Arch's own `ruby` package already includes the full
standard library, no separate install needed there). `./blog.sh
preview`, by contrast, needed no such caveat to begin with: it's a
small built-in static server (`lib/preview_server.rb`), not the
`webrick`-dependent `ruby -run -e httpd` one-liner some other guides
suggest.

## 1. Get the code

```bash
git clone https://github.com/DanielSnor/blog.sh.git myblog
cd myblog
```

One clone = one site. Everything personal (posts, media, config,
secrets) is gitignored, so pulling engine updates later never touches
your content -- see [Updating the engine](#9-updating-the-engine).

## 2. Configure the site -- `config/site.yml`

```bash
cp config/site.yml.example config/site.yml
```

Or let `./setup.sh` do it: it seeds the file from this same example --
comments and all -- and fills in the answers you give it, which is the
same file you would have written by hand, minus the chance of a tab
where a space belongs. It covers the `site` block, the comments network
and the deploy target; `./style.sh` covers `banner`, `about`, `footer`,
`social`, `colors`, `fonts`, `widgets` and `nav`. Both are re-runnable and
neither takes anything away from editing the file directly.

If you do edit it directly -- which is a first-class way to use this
engine, not a fallback -- run **`./blog.sh doctor`** when you are done. It
reads the file you just wrote and reports every problem in it at once,
which is the half a hand edit does not get for free: an unclosed quote, a
tab, a value in the wrong section, a token in `env.sh` with no section to
use it. It is also the answer when a YAML error names a line that looks
perfectly fine -- the parser stops where things stop fitting, which can be
a long way from the mistake.

The example is fully commented. The short version:

- **Required:** `site` (title, short_name, description, author, lang,
  locale, base_url) and `banner`. That alone is a complete, working
  site.
- **`about` and `footer`** introduce the site and close every page; the
  example ships both filled in. Neither is required: an emptied value
  takes its section with it -- heading and all -- rather than rendering
  empty, and a deleted block reads the same as an emptied one.
- **Optional, each activates only when present:** `analytics`, `social`,
  `widgets` (toots / pixelfed / commits / bluesky / rss, each
  independently), `mastodon` **or** `bluesky` (comments + auto-announce
  -- exactly one, see [step 8](#8-comments-network-optional-mastodon-or-bluesky)),
  `comments` (which replies get published -- same step),
  `colors` (7 keys per light/dark mode -- omitted keys fall back to the
  built-in blue palette; whole palettes ship in `config/palettes.yml`, and
  `./style.sh` shows you a preview -- light and dark side by side -- and
  writes the one you pick into this section, so you never have to choose
  fourteen hex values by hand or blind), `fonts` (the banner title's and claim's font
  stack and size, plus any `.woff2` you put in `assets/fonts/` -- omitted
  keys fall back to the built-in JetBrains Mono at 45px/20px),
  `nav` and `layout` (what the pages are made of --
  [below](#the-menu-the-regions-and-a-stylesheet-of-your-own)),
  `publishing.slots` (the times posts usually go out, so scheduling stops
  asking for a date --
  [operations.md](operations.md#publishing-slots)),
  `media` (`convert_heic`, `remux_video` and `strip_location`, all discussed under
  [Writing from a phone](operations.md#writing-from-a-phone)),
  `tag_icons` (an icon a tag carries, on its own listing and on the date
  badge of every post that has it --
  [operations.md](operations.md#giving-a-tag-its-own-icon)),
  `share` (the row of controls under a post, drawn in the order you name
  them --
  [operations.md](operations.md#letting-a-reader-pass-a-post-on)),
  `write` (`write: true` publishes a page at `/write/` to write a post on
  from a phone --
  [operations.md](operations.md#a-post-sent-from-the-phone-itself)),
  and `seo`
  (`block_ai_crawlers` writes a maintained list of the crawlers that
  collect text to train on into `robots.txt`, `robots_extra` is appended
  verbatim -- off by default, because wanting to be findable in an answer
  somebody gets from a machine is a legitimate position and the engine
  does not take it on your behalf either way).

The `commits` widget reads GitHub unless you give it `instance` -- the
address of a Gitea or Forgejo server (Codeberg, your own git). The address
is the whole configuration: nothing else has to be said, because it already
answers which kind of host this is. That path costs one request where
GitHub costs one per commit, since a Gitea activity item carries the
commits it is about.

`social`, `footer.links` and `nav` are lists, and a list key holds a list
or nothing at all: emptiness is a legitimate answer everywhere. Anything
else under one of them -- a single URL pasted where a list belongs -- is a
mistake `doctor` names and the build reads as empty, rather than a
traceback out of an engine file.

`social` is the row of icons in the footer. Each entry takes `name`,
`url` and either `icon` (a name from the built-in set: the network marks
mastodon, pixelfed, linkedin, github, gitea, forgejo, codeberg, gitlab,
bluesky, instagram, threads, facebook, x, youtube, rss, email -- or any
of the general drawings the engine ships for tag icons, `globe` for
somebody's other site among them, [listed in
operations.md](operations.md#giving-a-tag-its-own-icon)) or `icon_svg`
(your own markup), plus an optional `rel` that is passed through to the
rendered link. `rel: "me"` on the Mastodon entry is what gets your site
verified -- the green check mark next to it on your profile: Mastodon
fetches the address from your profile's metadata field and accepts it
only if that page links back to the profile with `rel="me"`. The footer
is on every page, so pointing the profile field at your home page is
enough; the entry's `url` has to be the profile as Mastodon shows it
(`https://instance/@handle`). Several entries may carry it. Bluesky
verifies domains a different way (DNS or `/.well-known`), so `rel: "me"`
does nothing for a Bluesky entry.

`site.lang` selects `locales/<lang>.yml` for every generated string --
`en`, `cs` and `de` ship with the engine; a partial locale falls back to
English per key. Adding another language is data, not code -- see
[localization.md](localization.md).

`site.timezone` (an IANA name like `Europe/Prague`) is the zone every
timestamp the engine writes is expressed in. **Set it if you'll ever
publish from a server**, because a server's clock is usually UTC: without
it, `schedule` reads "10:30" as 10:30 UTC, and a post written after
midnight local time can be dated to the previous day. Omit it to use the
machine's own zone. A name the system doesn't know is refused at startup
rather than silently treated as UTC. It also governs the dates readers see,
including the sidebar widgets, whose sources report UTC. Existing posts keep
the stored offset -- setting this later rewrites no history, it only changes
the day shown for posts whose local day genuinely differs (and never a
post's URL).

### The palette and the header's type

`colors.light` and `colors.dark` take the same seven keys -- `bg`,
`text`, `meta_text`, `accent`, `nav_bg`, `border`, `pill_bg` -- and the
build compiles them into `assets/css/colors.css`. Everything else the
stylesheet needs is derived from those seven rather than configured
separately: the card background, the nav's text and border, the hover
states of links and badges, the search field's background. That is why
there are seven keys and not twenty, and why a palette cannot end up
internally inconsistent. Omit the section entirely and the site uses
blog.sh's own blue (`DEFAULT_COLORS`).

`assets/css/site.css` is the other half, and it is not generated: layout
and structure, plus the few colors that are fixed because they work
against any palette -- white on accent surfaces, the dark scrims behind
the banner overlays and the lightbox, the search field's grey
placeholder. Changing `colors:` is configuration; editing that file is
editing an engine file, with the pull conflicts that implies (see
[step 9](#9-updating-the-engine)).

`fonts.banner_title` and `fonts.banner_claim` take a CSS font stack each,
`fonts.banner_title_size` and `fonts.banner_claim_size` any CSS length,
and they compile into that same generated stylesheet. Drop a `.woff2`
into `assets/fonts/`, declare it under `fonts.faces`, and the header is
in your own type; say nothing and it stays self-hosted JetBrains Mono at
45px/20px. Narrow screens scale from whatever size is configured, so
there is no second pair of keys to keep in sync.

### The menu, the regions and a stylesheet of your own

Four more settings decide what the pages are *made of* rather than what
they look like. Each has a default that leaves a site saying nothing
exactly as it was, so none of them has to be touched.

`nav:` replaces the menu bar the build otherwise derives from the content
types that actually have posts. An entry takes a `label` plus either a
`tag` (a tag's slug, which becomes `/tag/<slug>/`) or a `url` taken as
written -- so an item can point at a post, at a generated page, or off the
site entirely:

```yaml
nav:
  - { label: "Home", url: "/" }
  - { label: "Photographs", tag: "photo" }
```

An entry missing either half is skipped rather than rendered as an empty
link. An empty list is a decision rather than a mistake: the entries and
the button that opens them are gone, which is also how a site turns the
menu off, so there is no second key for that. The bar itself stays, since
the search field is rendered inside it. `nav:` with nothing under it at all
-- the key left standing after its entries were deleted -- reads the same
way, because a key that is written down is an answer; leave the key out
entirely to ask the engine for its own menu again.

`layout.sidebar` and `layout.hero` switch whole regions on and off. The
sidebar is on unless you say otherwise -- though it is only drawn when
something would stand in it, so a site with no about text and no widgets
gets its full width back without having to say so; the hero -- the post's first
usable image lifted out of the text and run full width above the title --
is off unless you ask, because it reshapes every post page it touches and
a site is entitled to keep the shape it has. A single post can still ask
for one either way with `hero:` in its own header (see
[operations.md](operations.md#writing-and-publishing)). They are switches
for regions, not for how a region looks: what things look like belongs in
a stylesheet, and a key per visual property would turn this file into a
stylesheet written in YAML.

`site.extra_css` is that stylesheet -- one path, or a list of them, loaded
after the site's own, so a skin can live in a file of yours instead of in
an edited engine file with the pull conflicts that implies
([step 9](#9-updating-the-engine)). Local paths only
(`/assets/css/mine.css`): every page carries `style-src 'self'`, so a
stylesheet on another host would be discarded by the browser without an
error you would ever see -- the page would simply render undressed -- and
the build refuses it out loud instead.

`site.page_size` is how many posts a listing page holds; 10 without it.
Worth setting once, before the first deploy: pagination is anchored to the
oldest post precisely so page contents never change as new posts arrive,
and changing the size later renumbers every page in the archive.

## 3. Configure the environment -- `env.sh`

```bash
cp env.sh.example env.sh
chmod 600 env.sh
```

`env.sh` holds secrets and per-environment values; it is gitignored and
mode 600 because live credentials go in it. An **unedited copy is
enough to try everything locally** -- with no deploy target configured,
uploads are skipped (logged, not an error).

The one value worth knowing about right away is `SITE_BASE_URL`: the
canonical URL normally comes from `site.base_url` in `config/site.yml`
(step 2), and this env.sh value **overrides** it when set -- it exists so
a staging or local environment can point somewhere other than production
while building from the same config. One site, one URL? Set
`site.base_url` and leave this out.

Watch the order they start in: the example above ships `SITE_BASE_URL`
**active and pointing at `https://example.com`**, so filling in
`site.base_url` carefully and leaving this file alone gives a site that
still calls itself example.com in its feed, its sitemap and every share
preview. Either comment this line out or give it the same address.
`./setup.sh` writes both to the same value for exactly this reason, and
`./blog.sh doctor` reports the address that would actually be used
rather than the one in the config.

## 4. Banner and favicon

Both ship with the engine as `assets/images/defaults/` -- the first build
copies whatever is missing to the live names `assets/images/header.png`
(the path `banner.src` defaults to) and `assets/images/favicon.png`, so a
fresh clone renders before you've drawn anything. The live names are
gitignored: replace them with your own artwork and neither `git pull` nor
a rebuild will touch it. That also means nothing else keeps a copy -- put
both files in your backup ([Backup](operations.md#backup)), or a restore
brings the site back wearing the engine's default artwork. Set
`banner.width`/`height` to the real
dimensions of your image: those attributes are what reserves space before
it loads, and a mismatch makes the page jump.

`./style.sh` does that part for you -- give it the path to an image and
it copies the file into place, reads its real dimensions and writes
them, so the pair can never drift from the file. `./blog.sh doctor`
reports it if they ever do.

The favicon is used three ways from that one file: the `<link rel="icon">`,
an `apple-touch-icon` (iOS scales it down for a home-screen bookmark), and
a generated `/favicon.ico` for clients that request the root path without
reading the link. A square PNG of 180 px or more covers all three.

The banner gets `site.short_name` rendered top-left and `site.description`
bottom-right (wrapping to several lines if it is long), each darkening the
corner it sits in so it stays readable against any image -- and only that
corner, so a banner with both overlays off is shown exactly as authored. A
calm image still works best. Each is independently optional:
`banner.show_title` and `banner.show_claim` (both default true) decide
whether they render at all, and `colors.<mode>.banner_title` /
`colors.<mode>.banner_claim` override their color per light and dark mode
-- by default `nav_bg` in light, white in dark. `banner.claim` overrides
*only* the overlay's text, in Markdown or raw HTML (a manual `<br>`, say);
`site.description` itself stays plain text everywhere else it is used, in
the meta description and the feed. Their typeface and size are
[`fonts`](#the-palette-and-the-headers-type).

## 5. First build and local preview

```bash
./blog.sh add                  # write your first post (opens $EDITOR)
ruby build/build_blog.rb       # build into public.nosync/
./blog.sh preview               # preview at http://localhost:8000 (Ctrl-C stops it)
```

`add` always creates a draft and offers publishing interactively -- see
[operations.md](operations.md#writing-and-publishing) for the full
authoring flow.

**Replacing an existing blog?** Bring the old content in before you deploy,
so the first published version of the site is already complete. `./import.sh`
walks you through it -- Bluesky, Mastodon, Pixelfed, Tumblr, a Twitter/X
archive export, or WordPress and any RSS/Atom feed -- and
always previews what it would write before writing anything. See
[operations.md → Importing](operations.md#importing-from-another-platform),
and `./import.sh --help` for the scriptable equivalents.

## 6. Pick a deploy target

Set `DEPLOY_BACKEND` in env.sh plus the values for your choice, then:

```bash
./scripts/deploy-web.sh --dry-run   # shows what would upload, touches nothing
./scripts/deploy-web.sh             # first real deploy (uploads everything once)
```

Every later deploy uploads only new/changed files -- a SHA-256 manifest
(`.deploy_manifest*.json`, one per backend) tracks what the target
already has, while `.deploy_baseline.json` records the shape of the last
build the safety guards accepted. Both are gitignored and both are
disposable.

One thing to know before you write your first post with a big attachment:
a single file over 100 MB is refused, at save time and again at deploy
time. The limit is the same for every backend so the site stays portable
between them -- the strictest supported target refuses anything larger.
See [Deploying](operations.md#deploying) for the rest of the guards.

### surfer (Cloudron Surfer -- the default)

```bash
export SURFER_URL=https://surfer.example.com
export SURFER_TOKEN=...        # create an access token in the Surfer admin UI (/_admin)
export SURFER_REMOTE_DIR=      # optional subdirectory; empty = app root
```

No `DEPLOY_BACKEND` needed -- surfer is the default whenever
`SURFER_URL` is set.

### local (a directory on the same machine)

```bash
export DEPLOY_BACKEND=local
export DEPLOY_TARGET_DIR=/var/www/mysite
```

For a docroot served by your own nginx/Caddy, or a mounted volume. Your
web server handles HTTPS (Caddy does it automatically; certbot for
nginx). The engine's CSP arrives via a meta tag so no header
configuration is required -- but if you can set real HTTP headers,
nothing stops you from adding more.

### rsync (any SSH host)

```bash
export DEPLOY_BACKEND=rsync
export RSYNC_TARGET=user@server:/var/www/mysite
export RSYNC_SSH="ssh -p 2022"   # optional, only for a non-default ssh
```

The most universal remote option -- works against any VPS or shared
host with SSH and rsync installed.

### git (GitHub / GitLab / Codeberg Pages)

```bash
export DEPLOY_BACKEND=git
export GIT_PAGES_REMOTE=git@github.com:you/yoursite.git
export GIT_PAGES_BRANCH=gh-pages       # optional, this is the default
export GIT_PAGES_CNAME=www.example.com # optional custom domain
```

Free hosting with HTTPS. Setup on the host's side (GitHub shown,
GitLab/Codeberg analogous): create a repository, then Settings → Pages
→ Build and deployment → Source → "Deploy from a branch" → `gh-pages`.
Every deploy force-pushes the build as a single-commit snapshot; a custom domain must be set via
`GIT_PAGES_CNAME` (the host stores it as a CNAME file *in the branch*,
which a snapshot push would otherwise wipe).

### rclone (S3, R2, B2, WebDAV, ...)

```bash
export DEPLOY_BACKEND=rclone
export RCLONE_TARGET=r2:my-bucket/site
export RCLONE_ARGS="--s3-acl public-read"   # optional provider flags
```

Run `rclone config` once to set up the remote -- credentials live in
rclone's own config, never in env.sh. Needs the `rclone` binary
installed.

### sftp (hosts with neither rsync nor git)

```bash
export DEPLOY_BACKEND=sftp
export SFTP_TARGET=user@server
export SFTP_REMOTE_DIR=/var/www/mysite   # optional; nested paths must exist
export SFTP_ARGS="-P 2022"               # optional
```

Uses openssh's `sftp` in batch mode -- one connection uploads exactly
what the manifest says changed. Set up SSH key auth first; a
password prompt would block the batch.

## 7. Running on a server

The engine runs wherever the content lives -- typically either **on
your laptop** (deploying to a remote target) or **on the server
itself** (SSH in to write; this is how the reference deployment on
sean.cz works, inside a Cloudron/Docker container). For the server
variant:

1. Clone the repo on the server, repeat steps 2-6 there. `env.sh` stays
   on the server only -- it never syncs anywhere.
2. Install the widget cron (see
   [operations.md](operations.md#cron-sidebar-widgets-and-post-stats)).
3. For writing from a phone, prepare the `incoming/` staging directory:
   any SSH/SFTP account that can write into `<repo>/incoming/` works. A
   dedicated user without sudo, limited to SFTP, is the safe shape --
   photos are uploaded there by name and referenced as bare filenames
   in posts (see
   [operations.md](operations.md#writing-from-a-phone)).
4. For a post sent whole from a phone, add the key the shortcut uses to
   `authorized_keys` with a forced command pointing at
   `scripts/receive.sh` -- the line, the RSA requirement and the size
   ceiling are in
   [operations.md](operations.md#a-post-sent-from-the-phone-itself).
   Nothing new listens on the network; it travels over the SSH the
   server already has.
5. In a container setup (Cloudron and similar), the engine lives inside
   the container's persistent data directory and commands run via
   `docker exec` / the platform's terminal -- the engine itself doesn't
   care, it's just Ruby + bash in a directory.

## 8. Comments network (optional): Mastodon or Bluesky

Every published post is announced on the configured network, and
replies to that announcement are the post's comments. A reply's
pictures appear under its words -- thumbnails linking out to the full
image, loaded from the commenter's own network the same way their
avatar already is; a reply marked sensitive keeps its pictures to
itself. Configure
**exactly one** of the two -- the build refuses a config with both,
since a discussion split across two networks serves nobody. Without
either section, everything else still works; publishing just skips the
announcement (logged, not an error).

**Mastodon:**

1. In `config/site.yml`, uncomment the `mastodon:` block -- the header
   line included, which is the half that is easy to miss -- and set
   `mastodon.instance`. This switches on comments, per-post stats and
   the auto-toot on publish.
2. On that instance: Preferences → Development → New application, scope
   `write:statuses`. Put the token into env.sh as
   `MASTODON_ACCESS_TOKEN`.
3. For the "recent toots" sidebar widget, `widgets.toots.account_id`
   wants the *numeric* account id, not the @handle -- find it at
   `https://<instance>/api/v1/accounts/lookup?acct=<username>`.
   (The widget's instance falls back to `mastodon.instance`.)
4. `mastodon.toot_length` is your instance's character limit, 500 by
   default. Set it if yours differs -- the announcement's perex is
   budgeted against this number, so a limit set too high gets the post
   rejected at publish time and one set too low just wastes room.
   `mastodon.link_length` is the other half of that arithmetic: Mastodon
   charges every link a flat 23 characters whatever it measures, and says
   so in its own API (`characters_reserved_per_url`). Leave it alone
   unless your server answers with a different number.

**Bluesky:**

1. In `config/site.yml`, set `bluesky.handle` (e.g.
   `you.bsky.social`); `bluesky.pds` only if you self-host a PDS.
2. On Bluesky: Settings → Privacy and security → App Passwords
   (bsky.app/settings/app-passwords) → create one, and put it into
   env.sh as `BLUESKY_APP_PASSWORD` -- never the account password.
3. Announcements fit Bluesky's 300-grapheme limit automatically (the
   excerpt shrinks; title, link and hashtags never do), with the link
   and hashtags clickable. Comments are read from Bluesky's public
   AppView by the visitor's browser -- no token involved on the page.

**Optional: publish only the replies you star.**

By default every reply to the announcement appears under the article.
`comments.approval: fav` in `config/site.yml` changes that to: a reply
appears once *you* favourite it, from whatever Mastodon or Bluesky
client you already use. Your own replies need no star. Everything else
stays on the network and off the blog.

```yaml
comments:
  approval: fav      # or "off" (the default)
```

**The moment you switch this on, every comment already on the site
disappears.** Moderation publishes only what you have starred, and at
that moment that is nothing -- a site with years of replies goes quiet
in one rebuild. They come back one star at a time, so plan the switch
for a moment when you can go and star the keepers right away, and run
`./scripts/refresh-sidebar.sh --full` once afterwards to settle old
posts on the spot instead of within the week.

Three things have to be true for it to work, and `./blog.sh doctor`
(add `--online` for the token check) says so when they aren't:

1. **`scripts/refresh-sidebar.sh` has to be in cron** (see
   [operations.md](operations.md#cron-sidebar-widgets-and-post-stats)).
   "Did *I* favourite this?" is a question only an authenticated request
   can ask, and the token can't be shipped to a browser -- so cron reads
   the thread and writes `public/comments.json`, and the page renders
   from that. Without that cron job nothing new ever appears.
2. **The token needs `read:statuses`** alongside `write:statuses`. On
   Mastodon that is a choice; on GoToSocial it is the only way comments
   work at all (see the note below). Reissue it under Preferences →
   Development if yours predates this: a token without it gets a perfectly good answer with
   the `favourited` field left out of it, which reads as "approved
   nothing". On Bluesky the existing app password is enough.
3. **You have to go and star the comments worth keeping** -- see the
   warning above the list.

**GoToSocial.** Live comments cannot work there, whatever you configure:
every read of a thread needs a token, all four of its authentication
requirements are on, and a token cannot be put in a visitor's browser.
Turn on `comments.approval: fav` -- the cron reads the thread with the
token and only the replies you star reach the page. Two more things worth
knowing: the token is made under Settings → Applications → New
Application (not Preferences → Development, which is Mastodon's path and
does not exist here), with the scopes written space-separated -- it needs
`read:statuses` as well as `write:statuses`, and both fit in one token
because GoToSocial has granular scopes. And a GoToSocial
instance usually allows 5000 characters rather than 500, so
`mastodon.toot_length` is worth setting to whatever your server's
`statuses-max-chars` says. `doctor --online` checks the first of these
for you and says so in one sentence.

Worth knowing before switching it on:

- Approval is not instant -- up to one cron interval, and for a post
  older than ~90 days up to a week, since old posts are only refreshed
  occasionally. `./scripts/refresh-sidebar.sh --full` does it now.
- A favourite is public on both networks. Anyone can see which replies
  you starred, and replies starred in the past count as approved.
- The side effect nobody asks for and everybody gets: with the thread
  already read server-side, the visitor's browser stops contacting the
  network at all, and the page's CSP drops its `connect-src` grant to
  it. Avatars are still loaded from the instance hosting them.
- It keeps replies off the blog. It cannot remove them from the network,
  where the thread stays public and this site still links to it. Block,
  mute and report remain the tools for that.

## 9. Updating the engine

```bash
git pull
ruby build/build_blog.rb && ./scripts/deploy-web.sh
```

The first build after an upgrade may be a full one -- the engine's own
fingerprint changed, so the record of the last build is thrown away --
and it writes `.build_cache.json` in the installation directory, which
is per-machine, gitignored and always safe to delete. Deploy the assets
with it: a page that cannot fetch `assets/js/share.js` logs a 404 on
every load.

Per-deployment files (`content.nosync/`, `media.nosync/`,
`config/site.yml`, `env.sh`, `incoming/`, `trash/`, `drafts/`,
manifests) are gitignored and survive any pull untouched. The one thing
to watch: if you've **edited engine files in place** (templates, CSS),
a pull can conflict -- keep such customizations as commits on your own
branch so git merges them for you. `config/palettes.yml` is one of
those: it ships with the engine, so a palette of your own added to it
is an edit in place. The wizards also leave a `.bak` of whatever they
rewrote -- `config/site.yml.bak`, `env.sh.bak` -- which is how you take
a wizard run back by hand. Nothing deletes them, and the `env.sh` one
holds your previous tokens at the same 0600, so remove it once you have
rotated a token.
