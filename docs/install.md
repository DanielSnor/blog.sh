# Installing blog.sh

From zero to a deployed site. The [main README](../README.md) is the
quick tour; this is the complete path, including the server side.
Day-to-day usage lives in [operations.md](operations.md).

## What you need

- **Ruby 3.0+** -- standard library only, no gems, no Bundler. Check with
  `ruby -v`.
- **bash** -- for the thin `blog.sh` / `deploy-web.sh` /
  `refresh-sidebar.sh` wrappers.
- **A place to serve static files** -- any of the six deploy targets
  below, from a Cloudron Surfer app to a plain directory behind your own
  nginx/Caddy.
- Optional: a **Mastodon account** (comments, auto-toot, sidebar
  widgets) and **cron** (widget refresh).

The engine has no build-time network dependencies: a machine with Ruby
and bash can build the whole site offline.

## 1. Get the code

```bash
git clone https://github.com/DanielSnor/blog.sh.git myblog
cd myblog
```

One clone = one site. Everything personal (posts, media, config,
secrets) is gitignored, so pulling engine updates later never touches
your content -- see [Updating the engine](#7-updating-the-engine).

## 2. Configure the site -- `config/site.yml`

```bash
cp config/site.yml.example config/site.yml
```

The example is fully commented. The short version:

- **Required:** `site` (title, short_name, description, author, lang,
  locale, base_url), `banner`, `about`, `footer`. That alone is a
  complete, working site.
- **Optional, each activates only when present:** `analytics`, `social`,
  `widgets` (toots / pixelfed / commits, each independently), `mastodon`
  (comments + auto-toot), `colors` (7 keys per light/dark mode --
  omitted keys fall back to the built-in blue palette).

`site.lang` selects `locales/<lang>.yml` for every generated string --
`en` and `cs` ship with the engine; a partial third locale falls back to
English per key.

## 3. Configure the environment -- `env.sh`

```bash
cp env.sh.example env.sh
chmod 600 env.sh
```

`env.sh` holds secrets and per-environment values; it is gitignored and
mode 600 because live credentials go in it. An **unedited copy is
enough to try everything locally** -- with no deploy target configured,
uploads are skipped (logged, not an error).

The one value to set right away is `SITE_BASE_URL` -- the canonical URL
that posts, RSS, the sitemap and OG tags are built from.

## 4. Banner and favicon

Drop your banner image at the path set in `banner.src` (default
`/assets/images/banner.png` -> file at `assets/images/banner.png`) and a
favicon at `assets/images/favicon.png`. Set `banner.width`/`height` to
the file's real dimensions -- they reserve space before the image loads.
The banner gets `site.short_name` and `site.description` rendered on
top of it (see "Appearance" in the main README), so a calm image works
best.

## 5. First build and local preview

```bash
./blog.sh add                  # write your first post (opens $EDITOR)
ruby build/build_blog.rb       # build into public.nosync/
ruby -run -e httpd public.nosync/ -p 8000   # preview at http://localhost:8000
```

`add` always creates a draft and offers publishing interactively -- see
[operations.md](operations.md#writing-and-publishing) for the full
authoring flow.

## 6. Pick a deploy target

Set `DEPLOY_BACKEND` in env.sh plus the values for your choice, then:

```bash
./scripts/deploy-web.sh --dry-run   # shows what would upload, touches nothing
./scripts/deploy-web.sh             # first real deploy (uploads everything once)
```

Every later deploy uploads only new/changed files -- a SHA-256 manifest
(`.deploy_manifest*.json`, one per backend) tracks what the target
already has.

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
