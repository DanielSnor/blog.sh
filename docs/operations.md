# Operating blog.sh

Day-to-day usage of an installed site: writing, deploying, cron, backup
and what to do when something fails. For the zero-to-deployed path see
[install.md](install.md).

## Writing and publishing

`./blog.sh` with no arguments opens a numbered menu; every command also
works directly (`./blog.sh add`, `edit`, `publish`, ...). The flow is
built around drafts:

1. **`add`** opens `$EDITOR` with a frontmatter template (title, tags,
   type, date) -- the in-editor hint links to the `/markdown/` syntax
   reference on your own site. Saving always creates a **draft**: it
   builds and deploys immediately, but only onto a hidden
   `/draft/<token>/<slug>/` address with `noindex` -- invisible in every
   listing, shareable by URL (that's the point: open the preview on a
   phone or send it to someone before publishing).
2. The CLI then asks: **publish / keep as draft / back to editing.**
   Publishing sets the date (now, unless you edited the date field),
   moves the post to its real URL and -- with Mastodon configured --
   sends the comment toot.
3. **`edit <slug>`** round-trips the stored post back to Markdown in
   your editor. A save that would drop content markdown can't express
   (an imported embed, a link card) warns and asks before proceeding.
4. **`unpublish <slug>`** returns a post to draft and deletes its toot
   (a toot pointing at a dead URL helps nobody). The next publish gets a
   fresh date. **`delete <slug>`** moves the post and its media to
   `trash/` -- **`restore <slug>`** brings it back. Trash keeps only the
   most recent deletion per slug.
5. **`toot <slug>`** (re-)sends the comment toot for an already
   published post -- typically an imported one that never had a toot.
   An existing toot is never overwritten.

Publishing a **backdated** post (date edited to the past) skips the
auto-toot unless you confirm it, and lands in the archive rather than on
the homepage -- the CLI says so when it happens.

**Scheduled publishing:** edit a draft's date to the future, then
`./blog.sh schedule <slug>` -- the
[publish-scheduled cron](#cron-sidebar-widgets-and-post-stats) publishes
it (toot included) once the date arrives, keeping the scheduled date.
Running `schedule` again cancels; `list` shows such drafts as
`[SCHEDULED]`. The date must be deliberately set: an untouched
creation-time date is refused, since that would just mean "publish now".

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

`scripts/refresh-sidebar.sh` refetches the widget JSON (toots, Pixelfed,
commits) and per-post stats, then uploads **only those four files** --
no site rebuild:

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
| Sidebar widget disappeared from the page | Its fetch returned nothing repeatedly (`refresh-sidebar` logs say which) -- the widget card hides when its JSON is empty/unreachable. Check the instance/feed URL in `config/site.yml`. |
| `MISSING media: <slug> -> <file>` during build | A post references a file that isn't in `media.nosync/<year>/<slug>/` -- restore the file or edit the post. The build continues; the page just has a broken image until fixed. |
| `/markdown/` page missing | `templates/markdown-cheat-sheet.<lang>.md` was removed -- restore it from the repo (`git checkout templates/`). |
| A published post shows the wrong date | Publishing uses "now" only when the frontmatter date was left untouched; an edited date is respected, including past dates (which skip the homepage -- by design). |
| sftp deploy hangs | It's waiting for a password -- the sftp backend needs key-based auth (see [install.md](install.md#sftp-hosts-with-neither-rsync-nor-git)). |

When in doubt: `ruby build/build_blog.rb` and
`./scripts/deploy-web.sh --dry-run` are both safe to run any time --
the build only writes into `public.nosync/`, and a dry run touches
nothing at all.
