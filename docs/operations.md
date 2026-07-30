# Operating blog.sh

Day-to-day usage of an installed site: writing, deploying, cron, backup
and what to do when something fails. For the zero-to-deployed path see
[install.md](install.md).

## Writing and publishing

`./blog.sh` with no arguments opens a numbered menu; every command also
works directly (`./blog.sh add`, `edit`, `publish`, ...). The flow is
built around drafts:

1. **`add`** opens `$EDITOR` with a frontmatter template (title, tags,
   type) -- the in-editor hint links to the `/markdown/` syntax
   reference on your own site. Saving always creates a **draft**: it
   builds and deploys immediately, but only onto a hidden
   `/draft/<token>/<slug>/` address with `noindex` -- invisible in every
   listing, shareable by URL (that's the point: open the preview on a
   phone or send it to someone before publishing).
2. The CLI then asks: **publish / schedule / keep as draft / back to
   editing.** Publishing sets the date to that moment (scheduling asks
   for one instead), moves the post to its real URL and -- with a comments
   network configured (Mastodon or Bluesky, see
   [install.md](install.md#8-comments-network-optional-mastodon-or-bluesky)) --
   sends the announcement post that replies-as-comments hang off.
3. **`edit <slug>`** round-trips the stored post back to Markdown in
   your editor. A save that would drop content markdown can't express
   (an imported embed, a link card) warns and asks before proceeding.
4. **`unpublish <slug>`** returns a post to draft and deletes its
   announcement on the network (an announcement pointing at a dead URL
   helps nobody). The next publish gets a fresh date.
   **`delete <slug>`** moves the post and its media to `trash/` --
   **`restore <slug>`** brings it back. Trash keeps only the most
   recent deletion per slug.
5. **`toot <slug>`** (Mastodon sites) or **`bluesky <slug>`** (Bluesky
   sites) (re-)sends the announcement for an already published post --
   typically an imported one that never had one. An existing
   announcement is never overwritten.

**Backdating** isn't part of that flow -- publishing means "now" -- but
the frontmatter parser still honors a `date:` line you type in by hand,
which is how an imported post keeps its original date. Such a post skips
the auto-toot unless you confirm it, and lands in the archive rather
than on the homepage -- the CLI says so when it happens.

**Scheduled publishing:** in the post-save dialog, choose `[s]` and
enter the publish date and time directly -- the
[publish-scheduled cron](#cron-sidebar-widgets-and-post-stats) then
publishes the draft (toot included) once that date arrives, keeping it
as the post's date. The standalone `./blog.sh schedule <slug>` asks the
same question, so either route works. The time you type is read in
`site.timezone` ([install.md](install.md#2-configure-the-site----configsiteyml))
-- worth setting before you schedule anything from a server, whose clock
is usually UTC. A past date is refused (that would
just mean "publish now", and `publish` is for that). Running `schedule`
on an already scheduled draft cancels it; `list` shows scheduled drafts
as `[SCHEDULED]`.

### In the terminal

The CLI adapts to where it runs. In an interactive terminal you get
arrow-key menus (digits still quick-select, typing a slug still works),
single-keypress answers without Enter, colored state markers and a
**QR code of the draft preview URL** -- point your phone's camera at
the screen instead of retyping a token. A menu longer than the terminal
is tall scrolls, showing your position in the list next to the hint.
Piped, scripted or cron runs get the plain line-based prompts unchanged,
with no escape codes in the output. Colors honor `NO_COLOR` and
`TERM=dumb`.

`./blog.sh preview [<port>]` serves the built site locally (default
port 8000) when you want to look at it without deploying.

## Writing from a phone

The trick is that a bare filename in an image line resolves against the
`incoming/` staging directory:

1. Shoot a photo, upload it via any SFTP client into `<repo>/incoming/`
   (setup: [install.md](install.md#7-running-on-a-server)).
2. SSH into the server, `./blog.sh add`, and write
   `![caption](photo.jpg)` -- no path.
3. If the photo hasn't finished uploading yet, the CLI waits and
   re-checks on Enter instead of failing.
4. On save the photo is copied into `media.nosync/<year>/<slug>/` and
   its `incoming/` copy is removed -- an empty `incoming/` means nothing
   is pending.

## Importing from another platform

`./import.sh` opens its own wizard: pick a source, and it reads the whole
thing in dry-run first and tells you what *would* be written -- how many
posts and media files, the first few slugs, and how many items it skipped
and why. Nothing is written until you confirm. Sources are Bluesky (no
credentials, public API), Tumblr (`TUMBLR_API_KEY` in `env.sh`) and a
Twitter/X archive export.

The same imports also run without the wizard, for cron or a scripted
migration -- `scripts/migrate_bluesky.rb <handle>`,
`scripts/migrate_tumblr.rb <blog>`, `scripts/migrate_twitter.rb <export-dir>`.
Those skip the preview and write immediately; see
[the README](../README.md#importing-existing-content).

Two things to expect on a real archive:

- **It is slow, and it says so.** Media is downloaded per post, so a few
  thousand posts run for hours. Every phase reports progress -- what it's
  reading, how many items it found, then a `12/847` counter -- so a quiet
  terminal means something is wrong, not that it's working. Sample before
  committing to that: the Tumblr and Twitter scripts take `LIMIT=20` to
  import only the first twenty, which is enough to see whether the mapping
  does what you expect. A second full run then overwrites them in place.
- **The deploy guard will stop you afterwards**, because a bulk import is
  exactly the "file count swung wildly" shape it watches for. That's
  working as intended: check the numbers, then re-run with `--force`.

Re-running an import is safe. Posts are matched on
`source.platform`/`account`/`original_id` and overwritten in place, so a
second pass fixes a bad first one rather than doubling it. That same triple
is the safe way to undo an import: select on it rather than on "everything
except the posts I wrote".

Back up `content.nosync/` before the first real import
(`tar czf ../content-backup-$(date +%F).tar.gz content.nosync`) -- it isn't
in git, and on a server there's nothing else to fall back on.

## Deploying

`./blog.sh rebuild` = build + deploy with `--prune` in one step; the
publish/edit flows run it for you. The deploy script alone:

```bash
./scripts/deploy-web.sh             # only new/changed files
./scripts/deploy-web.sh --dry-run   # print what would happen, touch nothing
./scripts/deploy-web.sh --prune     # also delete files the build no longer generates
./scripts/deploy-web.sh --force     # ignore the manifest, re-upload everything
./scripts/deploy-web.sh --only=A,B  # just the listed files
```

Things worth knowing:

- **The safety guards.** A deploy stops when the file count dropped or
  grew by more than ~20% versus the last deploy. That almost always
  means a broken or duplicated build, not intent -- check the build
  output first. If the change is genuinely intended (bulk import, mass
  deletion), rerun with `--force`.
- **`--prune` is the only destructive flag.** Without it, files the
  build stopped generating stay live on the target (the deploy log
  counts these "orphans"). With the `git` backend every deploy is a
  snapshot and prunes implicitly -- the log says "(snapshot deploy)".
- **Manifests are disposable.** `.deploy_manifest*.json` (one per
  backend) records what the target already has. Deleting one is always
  safe -- the next deploy re-uploads everything once and rebuilds it.
- **Switching backends** starts from a fresh manifest on purpose; the
  first deploy to a new target uploads the whole site.

## Cron (sidebar widgets and post stats)

`scripts/refresh-sidebar.sh` refetches the widget JSON (toots, Bluesky,
Pixelfed, commits, RSS) and per-post stats, then uploads **only those
files** -- no site rebuild:

```
*/30 * * * * /path/to/blog.sh/scripts/refresh-sidebar.sh
```

Every 30 minutes is plenty. Post stats refresh live for posts younger
than ~90 days; older posts get a full refresh about once a week
(tracked in `.stats_full_refresh_at`). A failed fetch **keeps the last
known content** rather than publishing an empty widget -- a one-minute
network hiccup never blanks the sidebar. Systems without cron: a
systemd timer or launchd job invoking the same script does the same
thing. No widgets configured = no cron needed.

A second, optional job publishes scheduled drafts
(`./blog.sh schedule`) once their date arrives -- it exits immediately
when nothing is due, so a tight interval costs nothing:

```
*/15 * * * * /path/to/blog.sh/scripts/publish-scheduled.sh
```

## Backup

Back up the per-deployment data -- the engine itself is a git clone and
everything generated is rebuildable:

| Path | Why |
| --- | --- |
| `content.nosync/posts/` | the posts -- the one thing that's truly irreplaceable |
| `media.nosync/` | their images and videos |
| `config/site.yml` | site identity and integrations |
| `env.sh` | tokens (or re-create them; mind the file's 600 mode in backups too) |
| `trash/` | optional -- deleted-but-recoverable posts |

Not needed: `public.nosync/` (build output), `.deploy_manifest*.json`
(self-heals with one full re-upload), `incoming/` (transient staging).
**Restore** = fresh clone + copy those paths back + `./blog.sh rebuild`.
The same list is exactly what to move when changing machines.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Missing env.sh` | Copy the template: `cp env.sh.example env.sh && chmod 600 env.sh`. An unedited copy works locally. |
| `Missing config/site.yml` | Same idea: `cp config/site.yml.example config/site.yml` and fill it in -- the build refuses to guess. |
| `Duplicate year/slug ... build stopped` | Two posts resolve to the same URL and media directory. Rename one slug; the build aborts rather than silently overwriting one with the other. |
| Deploy stopped with a "% drop/increase" message | The shrink/growth guard -- see [Deploying](#deploying). Broken build until proven otherwise; `--force` only when the change is intended. |
| `upload -> ... (HTTP 401)` on Surfer | Token expired or wrong -- create a fresh one in the Surfer UI and update `SURFER_TOKEN`. |
| `Mastodon API returned 401` / toot was not created | `MASTODON_ACCESS_TOKEN` missing, expired, or lacking the `write:statuses` scope. The post itself is fine -- fix the token and use `./blog.sh toot <slug>`. |
| `Posting to Bluesky failed` / announcement not sent | `BLUESKY_APP_PASSWORD` missing, revoked, or it's the account password instead of an app password (Settings → App Passwords). The post itself is fine -- fix it and use `./blog.sh bluesky <slug>`. |
| Sidebar widget disappeared from the page | Its fetch returned nothing repeatedly (`refresh-sidebar` logs say which) -- the widget card hides when its JSON is empty/unreachable. Check the instance/feed URL in `config/site.yml`. |
| `MISSING media: <slug> -> <file>` during build | A post references a file that isn't in `media.nosync/<year>/<slug>/` -- restore the file or edit the post. The build continues; the page just has a broken image until fixed. |
| `/markdown/` page missing | `templates/markdown-cheat-sheet.<lang>.md` was removed -- restore it from the repo (`git checkout templates/`). |
| A published post shows the wrong date | Publishing uses "now" and scheduling uses the date you entered, so a surprising date means a `date:` line was typed into the frontmatter by hand -- it's respected, including past dates (which skip the homepage -- by design). |
| sftp deploy hangs | It's waiting for a password -- the sftp backend needs key-based auth (see [install.md](install.md#sftp-hosts-with-neither-rsync-nor-git)). |

When in doubt: `ruby build/build_blog.rb` and
`./scripts/deploy-web.sh --dry-run` are both safe to run any time --
the build only writes into `public.nosync/`, and a dry run touches
nothing at all.
