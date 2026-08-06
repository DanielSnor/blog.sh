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
out of the minimal one. If `widgets.pixelfed`/`widgets.rss` are unused,
this never comes up; if you configure either and see a `LoadError`
about `rexml`, either `gem install rexml` or install your distro's
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
`social`, `colors`, `fonts` and `widgets`. Both are re-runnable and
neither takes anything away from editing the file directly.

The example is fully commented. The short version:

- **Required:** `site` (title, short_name, description, author, lang,
  locale, base_url), `banner`, `about`, `footer`. That alone is a
  complete, working site.
- **Optional, each activates only when present:** `analytics`, `social`,
  `widgets` (toots / pixelfed / commits / bluesky / rss, each
  independently), `mastodon` **or** `bluesky` (comments + auto-announce
  -- exactly one, see [step 8](#8-comments-network-optional-mastodon-or-bluesky)),
  `colors` (7 keys per light/dark mode -- omitted keys fall back to the
  built-in blue palette; whole palettes ship in `config/palettes.yml`, and
  `./style.sh` shows you a preview -- light and dark side by side -- and
  writes the one you pick into this section, so you never have to choose
  fourteen hex values by hand or blind), `fonts` (the banner title's and claim's font
  stack and size, plus any `.woff2` you put in `assets/fonts/` -- omitted
  keys fall back to the built-in JetBrains Mono at 45px/20px).

`social` is the row of icons in the footer. Each entry takes `name`,
`url` and either `icon` (a name from the built-in set) or `icon_svg`
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

The banner gets `site.short_name` and `site.description` rendered on top of
it (see "Appearance" in the main README), each darkening the corner it sits
in so it stays readable -- so a calm image works best, though turning both
overlays off with `banner.show_title`/`show_claim` leaves the image
completely untouched.

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
export SURFER_TOKEN=...        # create an access token in the Surfer web UI
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
→ "Deploy from a branch" → `gh-pages`. Every deploy force-pushes the
build as a single-commit snapshot; a custom domain must be set via
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
4. In a container setup (Cloudron and similar), the engine lives inside
   the container's persistent data directory and commands run via
   `docker exec` / the platform's terminal -- the engine itself doesn't
   care, it's just Ruby + bash in a directory.

## 8. Comments network (optional): Mastodon or Bluesky

Every published post is announced on the configured network, and
replies to that announcement are the post's comments. Configure
**exactly one** of the two -- the build refuses a config with both,
since a discussion split across two networks serves nobody. Without
either section, everything else still works; publishing just skips the
announcement (logged, not an error).

**Mastodon:**

1. In `config/site.yml`, set `mastodon.instance` -- this switches on
   comments, per-post stats and the auto-toot on publish.
2. On that instance: Preferences → Development → New application, scope
   `write:statuses`. Put the token into env.sh as
   `MASTODON_ACCESS_TOKEN`.
3. For the "recent toots" sidebar widget, `widgets.toots.account_id`
   wants the *numeric* account id, not the @handle -- find it at
   `https://<instance>/api/v1/accounts/lookup?acct=<username>`.
   (The widget's instance falls back to `mastodon.instance`.)

**Bluesky:**

1. In `config/site.yml`, set `bluesky.handle` (e.g.
   `you.bsky.social`); `bluesky.pds` only if you self-host a PDS.
2. On Bluesky: Settings → App Passwords → create one, and put it into
   env.sh as `BLUESKY_APP_PASSWORD` -- never the account password.
3. Announcements fit Bluesky's 300-grapheme limit automatically (the
   excerpt shrinks; title, link and hashtags never do), with the link
   and hashtags clickable. Comments are read from Bluesky's public
   AppView by the visitor's browser -- no token involved on the page.

## 9. Updating the engine

```bash
git pull
ruby build/build_blog.rb && ./scripts/deploy-web.sh
```

Per-deployment files (`content.nosync/`, `media.nosync/`,
`config/site.yml`, `env.sh`, `incoming/`, `trash/`, `drafts/`,
manifests) are gitignored and survive any pull untouched. The one thing
to watch: if you've **edited engine files in place** (templates, CSS),
a pull can conflict -- keep such customizations as commits on your own
branch so git merges them for you.
