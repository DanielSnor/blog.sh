# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.


## 1.7 -- 2026-09-03

The release about finishing a post rather than sending one. 1.6 got a post from a phone to the
blog and left it there as a draft, so the last step still wanted a terminal; this one publishes
from the page and lets it find out what happened. Beside that, the other half of the same idea:
changing what a post IS -- its series, tags, type and flags -- without opening what it says.

### Added

- **A post's properties, without opening the post.** `props`, key `[e]`.
- **Publishing from the phone.** The answer card gains a Publish button.
- **`publish <slug> --yes --json`.** One object, zero either way.
- **A receipt the page can ask about.** It polls instead of waiting to be told.
- **A link card in the front matter.** `link:`, `link_title:`, `link_description:`.
- **About fifty drawings for `tag_icons`.** Named, on the engine's own grid.
- **`media: remux_video: true`.** Moves a video's index to the front on the way in.
- **`check` names a video whose index is at the end.** With the command that fixes it.

### Changed

- **A stylesheet is no longer part of the engine's fingerprint.** Editing one rebuilds no pages.
- **`/write/` carries a content policy.** It is published as a file, not rendered.
- **`NOTICE`.** The fonts and brand marks the engine ships, and their licences.

### Fixed

- **A tag written `[release]` or `#foto` kept the punctuation.** So did a YAML list.
- **`tag_icons:` written as a mapping drew nothing and said nothing.**
- **The `ffmpeg` command could name its own input.** An HEVC video already in an `.mp4`.
- **The docs said a draft was deployed "only" to its hidden address.** The whole build goes.
- **A bullet wrapped onto a second line stopped being a bullet.** Silently, on every site.
- **The cheat sheet's last list rendered as a run-on paragraph.** Same reason.
- **A page called "Write" took the writer app off the site.** `write` is reserved now.
- **A link card's address could reach a live `href`.** In a post with no title of its own.
- **A second video could be written over the first.** With `media.remux_video` on.
- **`hero: false` did not survive the next edit.**
- **An `icon_svg` that was not a drawing was printed as words.** On every badge.
- **A tag icon could miss the tag it was written for.** Matched on the name, grouped on the address.
- **`check` called an archive sound while `config/site.yml` would not parse.**
- **A fresh install answered the phone with a bare exit code.** The five setup refusals.
- **The build answered an unreadable config with a backtrace.** Now it names the file.
- **A part number sent its post to the front of its series.** Instead of to that position.
- **A draft's series preview said it would be last.** Whatever number it carried.

## 1.6 -- 2026-09-03

A release about the time between deciding to publish and the site saying so. The build stops
rebuilding what nobody changed, a photograph is stored once rather than twice, and a post can arrive
as a file from a phone shortcut or a script. Beside those: share controls, tag icons, a way out of
the trash, and an engine that behaves the same down a pipe as on a terminal.

### Added

- **A page already on disk is not built again.** `rebuild --full` renders everything.
- **`add <file>` writes a post without asking anything.** It stops at the draft.
- **A post can be sent from a phone.** `scripts/receive.sh`, over the SSH the server already has.
- **And a page to write it on: `/write/`.** `write: true`; off by default.
- **The page wears the blog it writes to.** The build puts `site.js` beside it.
- **A preview, a row of marks, and video.** In the editor.
- **`publish: yes` in a file's front matter publishes it on arrival.** Anything else is a draft.
- **`add <file> --untrusted`.** A picture reference may name only a bare filename.
- **`publish <slug> --yes` and `publish --no-announce`.** The slug must be spelled out.
- **A row of share controls under a post.** Off unless `share:` names what you want.
- **A tag can carry an icon.** `tag_icons`, replacing the badge's content-type icon.
- **`empty trash` and `empty versions`.** Each asks for the count back before it removes anything.
- **`doctor` says what is in the trash.** As a note rather than a fault.
- **`check` says when a post asks for a `type:` the engine does not know.**

### Changed

- **A published picture is the archive's own file, under a second name.** A hardlink, not a copy.
- **`browse --drafts` shows scheduled drafts.** As `list --drafts` always has.
- **Esc backs out of the palette preview instead of accepting it.**
- **A relative path is read against where you are standing.** `add sub/post.md`.
- **`doctor` checks the footer's `social:` icons as it has the tag icons.** And the `share:` list.

### Fixed

- **Two posts written at the same instant left one post.**
- **A byte-order mark swallowed the whole frontmatter.** Three bytes before the opening `---`.
- **Attaching a photo through a symlinked directory in `incoming/` deleted the original.**
- **`./setup.sh | tee setup.log` echoed the access token in clear text.** Rotate it if you did.
- **A script that asks now flushes before it blocks.** All five of them.
- **The QR code for a palette preview was trimmed to unscannable thirds.** The address with it.
- **A letter outside ASCII in a tag or type crashed on a terminal.** Down a pipe it matched nothing.
- **An embed could still smuggle a script past the sanitiser.**
- **A list item under a list item could not be found from the search box.** Rebuilding reindexes.
- **One file that would not go took the whole build with it.**
- **Turning the sidebar off left yesterday's widget JSON on the site.**
- **A page was written straight through a symlink.** One left in `public.nosync/`.
- **The queue's `[m]` was offered on a terminal and accepted everywhere.**
- **Ctrl-C on the import wizard's first screens printed a stack trace.**
- **The About and footer questions lost their labels on a terminal.**
- **"Nothing changed, no post" read as though recovered text had gone with it.**

### Not fixed, on purpose

- **Backdating still costs four fifths of a full build.**
- **A nested list item is not in a post's excerpt.** Search reaches it.
- **There is no `pixelfed` in `share:`.** Pixelfed has no address a page can hand a post to.

## 1.5 -- 2026-08-30

The release about a site saying what it holds. A post that never had a title takes its name from
its own words rather than standing under its slug; an archive of thousands gets a map at
`/archive/`, and every subject the site covers gets a page at `/tag/`. Underneath, four days of
adversarial review closed 173 findings, every one pinned by a test. Nothing to migrate.

### Added

- **A post that never said what it is called gets named from its own words.**
- **A post can write its own invitation.** A line reading `//--more--//` splits it.
- **`/archive/` -- a map of the archive.** A row per year, a page per year.
- **`/tag/` -- every subject the site has.** Sorted by the folded name, or by count.
- **A listing card is cut before it is written, not hidden afterwards.** At a block boundary.
- **A code block carries a copy button.** Where the clipboard can be reached.

### Changed

- **Every listing of one kind of post says which kind, with an icon.**
- **`/tag/` shows its tags as pills in wrapped lines rather than in columns.**
- **The page is framed on all four sides, not two.** Off below 700 pixels.
- **A search result marks where one paragraph ends and the next begins.** A middle dot.
- **An announcement budgets its link the way Mastodon charges for one.** `mastodon.link_length`.
- **`doctor` says when `site.locale` and `site.lang` disagree.** A warning, not an error.
- **`check` has two more things to say.** An existing archive may report new findings.
- **A series listing pages from the part that will never change again.**
- **Posts are ordered by the moment they happened, not by the text of their timestamp.**
- **A listing page no longer carries the posts' heading anchors.**

### Fixed

- **The appearance button was dead in a browser that refuses storage.**
- **`./blog.sh edit` published the coordinates a photograph was taken at.**
- **Choosing a palette in `./style.sh` deleted 34 documented lines from `config/site.yml`.**
- **One cron tick with the archive out of reach blanked the live site's comments and counters.**
- **The scheduled-publish cron wrote back a snapshot taken before the run.**
- **A `--prune` whose deletion failed was reported as a completely clean deploy.**
- **`doctor` failed an install over a menu item that works.** A `url` with a `#fragment`.
- **`check` vouched for a link whose only backing is a redirect the build refuses.**
- **Markdown stopped losing text it has no form for.** Code spans, hard breaks, flat lists.
- **A post whose `title` is an empty string shipped a blank tab and an empty heading.**
- **The export/re-import round trip lost posts.**
- **An imported embed's scripts, style blocks and stylesheet links are stripped at render.**
- **The sitemap and the feed describe the site as built.**
- **The importers, all eleven adapters and the machinery under them.** 59 defects closed.
- **A picture was lost where `01.JPG` and `01.jpg` resolved to one file.**
- **Smaller, and there were many.** Tags, heroes, excerpts, pagination, the narrow menu.

### Not fixed, on purpose

- **Wayback's CDX paging.** Following `resumeKey` through a second request was not written.
- **The shortened link in an announcement.** Bluesky charges for a link by its length.

## 1.4 -- 2026-08-25

The widest release since 1.0, and the most thoroughly tested. Three things arrived: the commits
widget reads Gitea and Forgejo, comments work on GoToSocial with the favourite moderation Mastodon
already had, and the whole engine speaks the site's language -- deploy, build warnings,
announcements, imports alike. Under that sits a long audit over real archives. Nothing to migrate:
`git pull`, rebuild, deploy.

### Added

- **The commits widget reads Gitea and Forgejo, not just GitHub.** `widgets.commits.instance`.
- **Media are read from the year the post's file lives in.** Not by the post's date.
- **Letter case and unicode form of a filename no longer cost you the picture.**
- **The deploy manifest knows which target it describes.**
- **`./style.sh` can take a sidebar widget away again.** The block is commented out, not deleted.

### Changed

- **`check` has a ninth kind of finding: two posts at one address.** An error, so it can exit 1.
- **`doctor` fails on a config the engine cannot use.**
- **Renaming a post writes its redirect from the address the site actually served.**
- **Two pages sharing a slug stop being a silent loss.** `check` calls it an error.
- **`./blog.sh check --repair`: the checker's other half.** Nothing applied without a key press.
- **`./blog.sh check --json`: the findings themselves, all of them.**
- **Icons for Gitea, Forgejo, Codeberg and GitLab join the footer's set.**
- **A key that is written down speaks for itself.** An empty `nav:` now means no menu.
- **The sidebar column goes with its last card.** No about text and no widgets, no column.
- **The whole engine speaks the site's language.** Deploy, build warnings, imports alike.

### Fixed

- **Comments work on GoToSocial.** `comments.approval: fav` is all a token-gated server allows.
- **An install in a folder called `blog [1]` no longer publishes an empty site.**
- **A post whose slug carries `[`, `{`, `*` or `?` is no longer invisible to the commands.**
- **A bracket in an alt text no longer destroys the picture.** `![[es] W-ZERO3](...)` parses.
- **`--prune` deletes what the deploy named, and nothing else.** On `rsync` and `rclone`.
- **An interrupted sftp transfer resumes.**
- **A full disk ends a deploy with a sentence, not a traceback.**
- **Announcing a page linked to an address the site does not answer at.**
- **A post taken back down keeps its discussion off the site.**
- **An import that loses an item says which one, and exits 1.**
- **The Twitter import stopped leaving `&lt;` and `&amp;` in the text.**
- **The Facebook import says what it does not take.** Albums, uncategorised photos, videos.
- **`doctor` stopped ticking three things that were not fine.**
- **The scheduler's quiet tick is quiet.** Nothing to do, nothing on stdout.
- **`./style.sh` can point the commits widget at a forge.**
- **Turning a post into a page (or back) no longer loses its address.**
- **The build and `check` read `unlisted` with one rule.** `"no"`, `"false"` and `"0"` alike.
- **A tag too long for a filename no longer stops the build.** The cap is 200 bytes of address.
- **The feed stopped naming categories nothing stands behind.**
- **The search box folds a word the way the index folded it.** The Greek final sigma `ς` included.
- **A draft's tags no longer link to pages that do not exist.**
- **Two posts sharing a slug in two years can trade places in the queue.**
- **A media file nobody can read is now a finding, not a presence.** Zero bytes, no permission.
- **The CSP for a Bandcamp player follows the stored player address.**
- **The wizard writes the `env.sh` line the shell actually reads.**
- **The import wizard's advice about the Wayback Machine now applies to itself.**
- **A wizard import whose source died, or that wrote no items, exits non-zero.**
- **`check --repair` says whose archive it is and that it is working.**
- **The "not understood" line in `props` names the keys the row offers.**
- **A list key that held something else ended the build in a traceback.**
- **Two markdown trees no longer overwrite each other.** Import first, upgrade after.
- **A Hugo site root imports the site's content, not its machinery.**
- **The albums in a Facebook HTML export are counted.**
- **A link imported with an active-content address is defused.** http, https, mailto, tel pass.
- **A broken colour cannot take the stylesheet down.** The shipped default stands in.
- **The git backend ships the bytes the build produced.** The snapshot pins `autocrlf=false`.
- **rsync and sftp carry a filename their own tools would misread.** `#draft.html`, `- old.html`.
- **Rerouting a deploy no longer inherits the old target's manifest.** `RSYNC_SSH`, `RCLONE_ARGS`.
- **A manifest the process cannot read or write degrades, it does not crash.**
- **`doctor --online` keeps the token at home.** The probe refuses a foreign host.
- **`doctor` diagnoses a broken config in the site's language.**
- **`check` refuses everything the build refuses.**
- **A crash in the middle of a queue move cannot cost a post.**
- **"Nothing was written" is true across both files.** `site.yml` and `env.sh`.
- **An answer of "y" means yes in every language, in every dialog.** `y`, `j` and `a`.
- **Enter backs out of "add one" everywhere, and a pending copy is a listed change.**
- **Two examples in the markdown cheat sheet had stopped playing.** SoundCloud and PeerTube.

## 1.3.2 -- 2026-08-21

A GoToSocial release. GTS speaks Mastodon's API but answers with its own accents -- ULID account
ids, and content negotiation on Accept -- and two places in the engine assumed the Mastodon dialect
was the only one. Both fixes came from the first blog.sh site paired with one, arch-linux.cz, which
also asked for the one small thing here for skins. Nothing to migrate -- `git pull`, rebuild, deploy.

### Added

- **A listing page now says whether it is the first one.** `page-first` and `page-cont` on `<body>`.

### Fixed

- **The feed widget, the Pixelfed widget and the feed importer asked for `application/json` first.**
- **`doctor` and `./style.sh` refused every GoToSocial account id.** Pleroma flakes too.

## 1.3.1 -- 2026-08-20

A bug-fix release about three things: the publishing queue -- what the cron may announce, in what
order, and who may write it while somebody else is reading; the first hour of an install, where a
site with no deploy target is told where it is and in which language; and emptiness, where a section
emptied on purpose stops crashing the build. Nothing to migrate -- `git pull`, rebuild, deploy.

### Fixed

- **The scheduled-publish cron announced backdated posts as if they were news.**
- **A post that had already been announced could be announced a second time.**
- **Posts that came due in the same tick were published in alphabetical order.** Oldest first now.
- **The guard against a second announcement only covered the cron.** `toot` and `bluesky` too.
- **The cron read `unlisted` more narrowly than the site does.**
- **Two queue writes still ran outside the lock.** The [s] and [n] dialogs.
- **`check` could not see a link written relative to the post.** `./?item=another-post`.
- **The example config had chosen Mastodon for you.** Both networks ship commented out.
- **A `links:` key with no list under it ended the build in a stack trace.**
- **`doctor` failed an install over states the templates support on purpose.**
- **An emptied `about` drew an empty card on every page.**
- **Four places promised that an empty menu leaves no bar.** `nav: []` keeps the search field.
- **A fresh install was told its site is at `example.com`.**
- **The deploy said "the site goes nowhere" in English on a site that is not English.**
- **The editor template's body was English on every site.**
- **The Instagram import's "no posts found" hint stopped one level too high.**
- **The scheduling question worked against the person answering it.**
- **`publishing.slots` existed only for whoever found it in the documentation.**
- **A heading could not be turned off.** An empty heading now renders none at all.
- **A Surfer nobody can reach arrived as a backtrace too.**
- **A config the filesystem refused to write arrived as a backtrace.** `./style.sh`, `./setup.sh`.
- **Reordering the queue wrote without the lock the cron holds.**

## 1.3 -- 2026-08-19

The release about dressing a site without editing the engine: your own stylesheet, menu,
sidebar and lead image are settings now, and `./style.sh` writes every one of them. Around
that grew a release about trusting the archive -- `check` says what is broken, `export`
walks it back out as markdown, `stats` counts it, and every edit is undoable ten versions
deep.

### New

- **`./blog.sh check`.** Missing media, dead links, an address two posts claim.
- **`check` also sees the file a post no longer names.** A warning, per post and per file.
- **`./blog.sh export`.** The archive as markdown in Jekyll's layout, media included.
- **Media is fetched once, and a file's identity is its address.** `REFETCH_MEDIA=1` asks again.
- **Carrying a post through the publishing queue.** `[m]` picks it up, the arrows carry it.
- **Unlisted posts.** `unlisted: true` keeps the address and leaves every listing.
- **`./blog.sh stats`.** The archive counted from the posts on disk; also `--json`.
- **Editing a post is undoable.** `[v]` in `props` puts a version back: ten per post.
- **Pages.** `page: true` gives a post a permanent address at the root.
- **A 404 page**, built by the site rather than left to the host.
- **Series.** `series:` groups posts, `series_part:` orders them.
- **Reading time and a table of contents.** From four headings up, or with `toc:`.
- **`fediverse:creator`.** The author's account on a shared link's preview card.
- **A feed per tag, for the tags the menu names.** With autodiscovery on the tag's page.
- **`seo.block_ai_crawlers` and `seo.robots_extra`.** Off by default.
- **`site.extra_css`.** Stylesheets loaded after the engine's own; this site only.
- **Your own menu (`nav:`).** Entries the site names; an empty list turns the menu off.
- **`layout.sidebar` and `layout.hero`.** The sidebar off, the first image above the title.
- **`./style.sh` can set everything about how the site looks.**
- **Only the comments you star, if you want it that way.** `comments.approval: fav`.
- **A reply's pictures appear with it.** Images only, never from a reply marked sensitive.

### Changed

- **A listing's heading marks what it is instead of saying it twice.**
- **`config/site.yml.example` opens with an index** of every section and key.
- **The publishing queue comes back to the post you just moved** -- by name, not by row.
- **Restoring an earlier version is a list you walk, not a number you type.**
- **Action rows fold instead of wrapping mid-word** on a narrow terminal.
- **Tab completes paths in the import wizard**, directories with spaces included.
- **The wizard holds still.** Every screen repaints over itself.
- **"yes" is a keypress, not any word that starts with one.** Piped answers are matched whole.
- **Moderation housekeeping.** `comments.json` is written only while moderation is on.
- **A listing card says how long its post takes to read.** Too short to time says "under a minute".

### Fixed

- **An announcement that does not happen says why.** A missing network section is named as one.
- **`config/site.yml.example` says how to read itself.** One `#` before a key means uncomment me.
- **`doctor` stops agreeing with that mistake.** A credential with no section is a warning.
- **A YAML error admits the line may not be the mistake.** Both messages name the two shapes.
- **The appearance toggle can find its way back to the system.** It cycles system / light / dark.
- **A markdown tree's pages arrive, and arrive as pages.** Root-level markdown is read now.
- **A re-imported post no longer collects a platform tag it has already got.**
- **`hero:` survived a save.** An edit no longer rebuilds the post without the key.
- **Keyboard focus can be seen again.** One `:focus-visible` ring for the whole site.
- **The site holds still for a reader who asked it to.** `prefers-reduced-motion` is honoured.
- **The banner's two lines stop printing over each other on a phone.**
- **The menu on a phone closes with Escape and with a tap on the page.**
- **Search answers with its best results, not its most recent ones.** Ties keep their date order.
- **A search no longer draws a card for every post it found.** The count still says how many.
- **On a phone the search field is in the bar, not folded into the menu.**
- **The lightbox can be opened, walked and closed without a mouse.**
- **Small things, one sweep.** A passive scroll listener, avatar dimensions, bigger tap targets.
- **A search has an address again.** `?q=` follows the query as it is typed.
- **Every page has an h1.** The front page carries the site's title, clipped.
- **`check` no longer calls a working address dead.** A healthy archive stops failing on cron.
- **Unlisted is unlisted the whole way round.** The sitemap and the search index too.
- **`export` sees a directory that holds only dotfiles.** A fresh clone is not empty.
- **What a wizard prints is no longer erased by the screen it paints.**
- **A series listing said "SérieNový Sean.cz".** It gets an icon like the other listings.
- **The clock in the meta row was a fifth larger than the row it stood in.**
- **A Hugo picture written as `{{< figure >}}` arrived as nothing at all.**
- **An article that showed Markdown in a code block had its example eaten.**
- **Four ways an import stayed quiet about what it did.** Each is kept or said out loud now.
- **What the body could not keep is counted for everyone.** Whichever adapter was driving.
- **A percent-escaped filename was slugified character by character**, minting `ef-bf-bc...`.
- **A WordPress import's closing numbers described a different import.**
- **A video uploaded to Ghost was lost, and three lines of its player published in its place.**
- **A second import took away what the first one brought.** `redirect_from` addresses are merged.
- **Ten re-imports that changed nothing filled all ten version slots.** A duplicate is not written.
- **An AVIF image came in with no dimensions.** The bytes decide the type now.
- **`[](url)` was printed to the reader as raw markdown**, and heading ids came from it.
- **An attachment did not survive `export` and back.** It goes out as HTML, `download` and all.
- **"Images come from the tree itself -- no network" was only ever true of Jekyll.**
- **`props` stopped condemning a redirect a draft is holding.** The takeover waits for that draft.
- **`./blog.sh rebuild` under a held lock exits non-zero**, with the lock's own code.
- **Five corrections to the tree import.**
- **A nested `<a>` closes the open one**, as a browser reads what some Ghost exports carry.
- **A warning no longer outruns the output it belongs under.** The cron entry points sync stdout.

### Upgrading

- **Nothing to migrate.** The top bar is sticky and the menu repeated under the content is gone.
- **The next deploy is a full one rather than incremental.** The shared layout changed.
- **The front page carries the site's title as a clipped heading.** Nothing is drawn.
- **A stylesheet of your own that positioned `.banner-title` or `.banner-claim` wants a look.**
- **Post versions live in `content.nosync/versions/`.** A backup of `content.nosync/` covers them.
- **A rebuild that stepped aside for a held lock now exits 3, not 0.** Cron paths are untouched.
- **A markdown-tree re-import no longer copies an image's alt text into a visible caption.**

## 1.2.1 -- 2026-08-12

A bug-fix release on top of 1.2, with two things added to it: the site's own words are
Markdown now, and a photo no longer publishes the place it was taken. The rest is repair --
parsing, imported tables, the location strip itself, and what the wizard says when a run is
already going. Nothing to migrate: `git pull`, rebuild, deploy.

### New

- **The site's own words are Markdown.** Raw HTML still passes through.
- **A photo no longer publishes the place it was taken.** `media.strip_location: false` keeps it.
- **`./blog.sh doctor --strip-location`.** Takes the location out of photos saved earlier.
- **A table can have no header row.** Open it with the separator line, `| --- | --- |`.

### Changed

- **A new default banner, at 1880x600.** Only new installations see it.
- **`config/site.yml.example` uses a literal block scalar (`|-`).** Existing configs are untouched.

### Fixes

- **A continuation line under a nested list item crashed everything that read it.**
- **Every imported table handed its first row of data to a `<th>`.** Wix and the HTML path.
- **A Tumblr ask read as if the blog's owner had asked themselves.** Re-import to pick this up.
- **`doctor --strip-location` cleaned the archive and left the site alone.**
- **A GPS entry's data offset was trusted absolutely.**
- **`./style.sh` reported a held lock as a failed upload.**
- **The palette preview promised more than it could keep.** The next build removes it.
- **"Another run is still going" did not say to try again.**
- **Smaller ones.** Nine: four in the parser, three in the importers, two in the location strip.

### Upgrading

- **Nothing has to change.** Photos saved from now on lose their coordinates.
- **`about.html` and `footer.note_html` still written as `>-` need changing to `|-`.**

## 1.2 -- 2026-08-11

The import release. Eight sources became twenty-two -- every blog platform worth naming, the whole
social roster, podcasts, a plain markdown tree, and the Wayback Machine for blogs whose platform is
gone. Two wizards come with it, `./setup.sh` for the settings an install cannot run without and
`./style.sh` for how the site looks, plus a queue screen, an archive browser, redirects and
`./blog.sh doctor`.

### New

- **Eight import sources became twenty-two.**
- **`./setup.sh` -- setting a site up is now a conversation.** Every answer is checked.
- **`./style.sh` -- the appearance half, and seven palettes to pick from.**
- **`./blog.sh doctor` -- everything wrong with a configuration, at once.** `--online` goes further.
- **The queue got its own screen.** `./blog.sh queue`.
- **The archive is something you walk through, not a list that scrolls past.** `./blog.sh browse`.
- **Six more platforms play in a post, from their address alone.**
- **A migrated blog can keep its old addresses.** `redirect_from`, served by the build.
- **More of the look comes from the config: the header's type, and two more social icons.**
- **An interrupted post is offered back instead of just kept.**
- **A phone video says what it is.** HEVC or a `.mov` container, warned once.
- **Post pages now carry the metadata crawlers and phone browsers look for.**
- **Builds and deploys take a lock.** Two runs can no longer rewrite `public.nosync` at once.

### Changed

- **Configuration the engine writes keeps its comments.** A syntax error names line and column.
- **Every screen says which blog you are in, and the layout gives the width to the text.**

### Fixes

- **An export could hand over its posts and leave you without them.**
- **A post that did arrive came without its pictures and its links.**
- **A post nobody was meant to read went onto the open web.**
- **One unescaped `&` in an export no longer costs the whole archive.**
- **A feed's own address was misread, so every re-import wrote the archive again.**
- **Media filenames depend only on the order a post references them.** See *Upgrading*.
- **A failed download says why, retries when that helps, and never leaves half a file behind.**
- **A busy or throttling Archive no longer reads as a blog that was never archived.**
- **A rescue says up front what it can and cannot recover.**
- **The import preview and the summary now tell the truth about what arrived.**
- **An imported Wix table came back as a paragraph of pipes on the first save.**
- **A paid post imported looking exactly like a free one.**
- **A pair of imported redirects could stop the site building at all.**
- **A `<lj user>` mention pointed at somebody else's journal.**
- **A large export says what it will cost before it takes it.** Past 20 MB.
- **Editing a post can no longer silently corrupt it.**
- **The editor holds on to what you typed.**
- **Deleting one post threw away another's only backup, and the trash would not open.**
- **A post that moves across a New Year keeps its old link, and its own pictures.**
- **Publishing again after a re-import redirects the old address.**
- **A file you add to a post is measured and identified by what it is.**
- **Scheduling a post works again -- every route into it was dead.**
- **A dialog left open can no longer overwrite a post the cron published.**
- **The queue acts on the post you picked, and a reorder is all or nothing.**
- **An announcement could be left hanging in public, and nothing said so.**
- **Enter means "leave it alone", the way the wizards document it.**
- **Nothing is touched before you confirm, and one bad line no longer costs the session.**
- **The wizards work on Ruby 2.7 and 3.0 again.**
- **The archive browser draws and reads the terminal properly now.**
- **Page Up (and Home, End, Insert, Delete) left a stray key behind in every menu.**
- **An imported archive is text somebody else wrote, and several places left it unescaped.**
- **Each page's Content-Security-Policy is computed from what that page carries.**
- **The menu no longer runs under the search box.**
- **Nothing empty is drawn any more.**
- **The crons could not be trusted to say what happened.**
- **The deploy guards hold, and a busy lock reads as a collision.**
- **The commands that exist for a broken install now survive one.**
- **`doctor` and the engine now agree on what counts as configured.**
- **`./blog.sh preview` no longer serves your archive to the local network.**
- **A consistency pass over everything the interface says, in all three languages.**

### Upgrading

- **Nothing to migrate.** `git pull`, rebuild, deploy -- but expect a long first deploy.
- **Media numbering, for posts whose downloads failed under 1.1.** Delete their media directories.
- **Menu positions moved, so stop piping numbers at them.** `queue` and `list` are stable.
- **Builds and deploys take a lock now.** A run that finds it held does not queue.
- **Three more working files.** `.last-edit.meta`, `.blog-sh.lock`, `.last-scheduled-run`.
- **Going back to 1.1 builds, but do not write under it.**

## 1.1 -- 2026-08-05

Six things a site can now do that it couldn't, and one class of defect taken out of the deploy: the
guards measure a build against the last build they accepted rather than against the target, so
nothing can switch them off. Nothing to migrate -- `git pull`, rebuild, deploy -- but three changes
are worth reading before you upgrade, at the bottom.

### New

- **A post can be pinned to the front page.** `pinned: true`, first listing page only.
- **Publishing slots turn `[s]` into a queue.** `publishing.slots`; a typed date overrides.
- **Posts can carry files.** A line that is nothing but `[label](handbook.pdf)`.
- **One dialog for a post's properties and actions.** `props <slug>`, seven actions under `[c]`.
- **A slug can be renamed without breaking a link.** `[r]` keeps a redirect at every old address.
- **HEIC photos are refused, or converted on request.** `media.convert_heic: true`.

### Deploy safety

- **The guards could be switched off permanently, silently.**
- **They also fired when they shouldn't.** The percentages carry absolute floors now.
- **Total bytes are guarded too.** A drop stops the deploy, an increase only says so.
- **An empty build is refused.**
- **A failing deploy explains itself.** The previous run's outcome opens the next one.

### Fixes

- **A re-import minted a duplicate post.** When the text behind the slug changed at the source.
- **An import whose source died mid-paging crashed with a backtrace.**
- **Imported drafts landed at a guessable `/draft//<slug>/` address.** Without the token.
- **The interactive picker refused a slug that starts with a digit.**
- **The pin, the slots and the document type each shipped with a defect.**
- **The wizard banner showed the site's description, and a punycode guess for the domain.**
- **The properties dialog could revert a post the cron had just published.**

### Upgrading

- **The wizard menu was renumbered.** A scripted `printf "4\n" | ./blog.sh` picks another entry.
- **A single file over 100 MB is now refused.** `--force` does not lift it.
- **A new state file, `.deploy_baseline.json`.** Gitignored; losing it costs one deploy.

## 1.0.1 -- 2026-08-02

The first release after 1.0, and all of it repair. Every flow was walked end to end -- authoring,
publishing, both cron jobs, the build, the deploy, the importers -- asking of each step what
happens if it fails there. What came back was mostly failures partway through: a post half moved, a
batch half published, a deploy half uploaded. Nothing to migrate.

### Data that could be lost

- **`edit` with a date in another year could destroy the post.** Neither year, nor `trash/`.
- **A failed write truncated the post it was rewriting.** Every post write, and the deploy manifest.
- **A new photo could overwrite an existing one.** An image kept from a previous save.
- **A new post could land on a leftover media directory and lose its own upload.**
- **A source file missing for a moment could be deleted from the live site.**

### Flows that could not finish

- **The scheduled-publish cron could wedge permanently.** A post with photos into an empty year.
- **One imported post could stop the site from building at all.** With an error naming no post.
- **The sidebar refresh never uploaded anything.** On a site without all five widgets.
- **An interrupted deploy locked out every later one.** Including the ones the CLI runs itself.
- **A closed stdin spun at full CPU.** The wait-for-photos loop.
- **One unreadable post file took down the build, `list`, every picker and the cron at once.**

### Correctness

- **An edit saved across the cron tick that published the post reverted it to a scheduled draft.**
- **An ambiguous slug was resolved again at every internal step.** "Which year?", more than once.
- **GIF and WebP images were silently dropped from every page.** Caption and all.
- **An import preview promised more posts and media than the real run wrote.**
- **Feed fetches had no total deadline.** 30 seconds now, redirects included.
- **An emoji-only tag rendered as a link to `/tag//`.**
- **`--force` deploy forgot files pending deletion on the target.** They could never be pruned.

### Added

- **`./blog.sh version`, also `--version`.** In the wizard banner and the engine's User-Agent.
- **The backup checklist names `assets/images/header.png` and `favicon.png`.**

### Upgrading

`git pull`, then rebuild and deploy. On an existing site the only visible change is that images the
engine cannot measure now appear rather than vanishing.

## 1.0 -- 2026-07-31

The first stable release: a file-based blog engine where posts are JSON files, the site is a
static build, authoring happens in a terminal and comments live on the Fediverse. No database,
no admin server, Ruby stdlib and bash -- no gems, no npm (one asterisk: the optional
Pixelfed/RSS widgets need `rexml`, a default gem some distributions package separately).

- **Content model.** One post is one JSON file of typed blocks.
- **Authoring.** An interactive CLI wizard, with hidden preview addresses for drafts.
- **Markdown.** A deliberate subset, with a cheat sheet the parser generates itself.
- **Build.** Static HTML via ERB, memoized so that only what changed is written.
- **Comments and announcements.** Announced on Mastodon or Bluesky; the replies are the comments.
- **Deploy.** Six backends behind one manifest-driven diff.
- **Import.** Eight sources, verified against real archives.
- **i18n.** English, Czech and German. A language is one YAML file.
- **Appearance.** A complete theme from seven colour keys per mode.
- **Security by subtraction.** CSP meta, self-hosted assets, no third-party requests.
