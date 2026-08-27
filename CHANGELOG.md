# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.

## 1.5 -- 2026-08-26

Two things happened here. The site learned to say what it holds -- a post
names itself out of its own words instead of standing under its address,
an archive of thousands gets a map, a site's subjects get a page -- and
the engine underneath was taken apart and put back together over four
days of adversarial review: a fleet over the 1.5 work, then a bug bounty
across thirty-six surfaces, 173 confirmed findings, every one of them now
closed and pinned by a test that fails on the old code.

The naming is the change a reader will notice. On the archive this was
measured against, 2754 posts of 4418 -- 62% of the site -- had no title
and were called by their slug: a date in the heading and
`burtiky-opekame-hipstamatic-oggl-jane` in the browser tab, on the link
card and in every feed item. A slug is an address, made by machine out of
the words; the words are the better name.

Nothing to migrate -- `git pull`, rebuild, deploy. Two things will look
different on an existing site the first time: posts that never had a
title now have one everywhere except their own heading, and `doctor` may
name a config key it never mentioned (see **Changed**).

### Added

- **A post that never said what it is called gets named from its own
  words.** Until now the slug stood in, so one post had two names: the
  date in its heading and a machine's address everywhere else. It takes a
  whole first sentence when one fits in four to twelve words -- a Czech
  sentence puts its verb and object at the end, and eight words stop just
  before the point -- and otherwise the first eight, which is what slugs
  have always been cut to, so a name and an address stay recognisably the
  same post. The heading is still the date it has been since 1.3.

- **A post can write its own invitation.** Asked for in issue #35 by
  somebody else running the engine: an announcement used to cut the
  opening off a post and put the title above it, and a machine cut rarely
  lands on a good sentence. A line reading `//--more--//` splits a post
  into what it says about itself and what it actually says. The listing
  card, the link card and the toot take the first half; the post's own
  page shows everything.

- **`/archive/` -- a map of the archive.** Nothing on the site could show
  the shape of one. Pagination is anchored from the oldest post, so
  `/page/128/` says nothing about whether it is 2009 or 2014, and the only
  complete list of anything lived in the terminal. `/archive/` is a row
  per year with a strip of twelve months; `/archive/<year>/` is one line
  per post, by month. An index, not another listing: no excerpts and no
  pictures. Two levels and no more -- a third would be some 280 month
  pages nobody asked for. Cheap by construction: a new post rewrites the
  map and the current year and nothing else, so a deploy that compares
  content has nothing to upload for 2014 and never will again.

- **`/tag/` -- every subject the site has.** The site built a listing per
  tag and nothing that showed them all, so a site's own list of its
  subjects lived in `browse` or in the top eight of `stats`. Sorted by the
  folded name, because Ruby sorts strings by bytes and that puts every
  accented tag after z: a reader looking for `škola` between `sirky` and
  `sport` would not find it. `stats` folds now too -- one question, one
  answer. Every tag that has a page and no others, so the list never
  points at an address the build did not write.

### Changed

- **Every listing of one kind of post says which kind, with an icon.**
  The tag, archive, search and series listings gained one; the seven
  listings by content type did not, which made them look unfinished
  beside the others -- noticed on a live site rather than in the code.
  There is one per content type now, drawn to the same rules as the four
  that had one: a 24-unit box, stroked in currentColor, the plainest
  shape that survives 20 pixels. The quotation mark is filled rather than
  stroked, because outlined at that size the pair closed up into
  something that read as the digits 99.

- **`/tag/` shows its tags as pills in wrapped lines rather than in
  columns.** Asked for by somebody else running the engine (issue #43),
  who wanted the overview a tag page cannot give: every tag at once, with
  the count beside each. The count now rides INSIDE the pill as a
  superscript -- one link, one target, and a number that cannot drift to
  the name after it when a line wraps -- and the letter band takes the
  width of the block, the way the archive's month does. A pill is the
  shape this engine already uses for a tag everywhere else, so the index
  looks like what it indexes.

- **An announcement budgets its link the way Mastodon charges for one.**
  Mastodon reserves a flat 23 characters for every link, whatever the link
  measures, and says so in its own API; the composer counted the address
  literally and spent a budget nobody was charging for. Honest about what
  this changes: at the shipped 500-character limit, nothing -- the excerpt
  is capped at 250 long before the budget binds, and that holds even for a
  234-character address. It shows on a site whose instance limit is low
  enough for the budget to bite first: at 300, with an 80-character
  address, the excerpt was cut at 198 characters instead of 246. The
  reserve is `mastodon.link_length` for a server that answers with a
  different number, and `doctor` checks it like its sibling. Bluesky is
  deliberately untouched: it charges an address what the address measures,
  so the same change there would make every long-address announcement one
  Bluesky refuses.

- **`doctor` says when `site.locale` and `site.lang` disagree.**
  `locale` is a second language switch, independent of the first, and
  only `./setup.sh` ever kept the two in step -- so a site set up by hand,
  or one whose language was changed in the file afterwards, announced
  `og:locale="en_US"` on every page of a Czech or German blog to
  everything that reads one, and nothing said so. It is a warning rather
  than an error and the value is NOT overridden: `en_GB` under `lang: en`
  is a real answer somebody wrote on purpose. **An upgraded install whose
  two disagree will hear one new sentence from `doctor`.**

- **`check` has two more things to say.** A `redirect_from` the build
  refuses to serve -- one whose first segment belongs to the site itself,
  or whose shape no directory can be made of -- is now a finding rather
  than one warning in the middle of a build log; and HTML entities are
  looked for in a post's TITLE and a link card's text, not only in the
  body, which is where an archive imported before 1.4 carries them and
  where they are worst. **An existing archive may report findings it did
  not report before.** They were always there.

- **A series listing pages from the part that will never change again.**
  The fixed `/page/N/` pages are cut from the front of a series rather
  than the back, so adding a part no longer re-cuts every page under it.
  A series long enough to paginate will have its `/page/N/` contents
  redistributed once.

- **A listing page no longer carries the posts' heading anchors.** A
  listing stacks ten posts' bodies into one document, so two posts with a
  section of the same name put the same `id` on the page twice -- 105
  pages of one real archive. The anchors stay on each post's own page,
  where they mean something.

### Fixed

Three days of adversarial review, most of it over real archives rather
than fixtures. The findings that matter to somebody deciding whether to
upgrade:

- **`./blog.sh edit` published the coordinates a photograph was taken
  at.** `add` stripped them, as the documentation promises; `edit` -- the
  path people use far more -- had grown a bare copy of its own and did
  not. The safe copy lives in one place now and both callers use it.

- **Choosing a palette in `./style.sh` deleted 34 documented lines from
  `config/site.yml`.** The last colour key is the last active key in its
  section, and the commented-out `fonts:` block underneath contains a
  line that uncomments to the same indentation as a colour -- so the
  writer claimed it and everything below it. The config was rewritten
  without them and the wizard reported success.

- **One cron tick with the archive out of reach blanked the live site's
  comments and counters.** `content.nosync` on a volume that had not
  mounted answers with an empty list and no error, which read as "every
  announced post was deleted": both public files were narrowed to nothing
  and uploaded. Exit 0, nothing said. An archive that cannot be seen is
  not an archive whose posts were deleted.

- **The scheduled-publish cron wrote back a snapshot taken before the
  run.** An edit made while it worked was silently overwritten with the
  older text, and a post deleted in the meantime was recreated from the
  snapshot, published, and announced to a timeline that cannot be
  recalled. Each post is re-read at the moment it is written now.

- **A `--prune` whose deletion failed was reported as a completely clean
  deploy** -- exit 0, "failed 0" -- whenever nothing needed uploading,
  which is the ordinary shape of "I removed one unused asset and
  redeployed". And `DEPLOY_TARGET_DIR` without a leading slash deployed
  the whole site into a directory of that name inside the installation.

- **`doctor` failed an install over a menu item that works.** A `url` with
  a `#fragment` or a `?query` was compared as a path, so an anchor on a
  page that exists was called dead and the fix text sent the owner looking
  for a post that was never renamed.

- **`check` vouched for a link whose only backing is a redirect the build
  refuses**, under a closing sentence that names redirects specifically.
  The same refusal was written out in four places and missing from the
  fifth; it has one home now.

- **Markdown stopped losing text it has no form for.** A code span holding
  a backtick came back with a visible backslash and its text cut short; a
  hard break was lost when the line before it ended with a backslash; a
  tree written on Windows stored a carriage return inside every paragraph;
  and a flat list indented by one to three spaces was read as a one-item
  list with everything else nested under it.

- **A post whose `title` is an empty string** -- what the feed, WordPress
  and Squarespace importers write for an item with no title -- **shipped a
  blank browser tab, an empty heading and archive links with nothing to
  click.** An empty string is truthy; the engine's word for untitled is
  nothing at all.

- **The export/re-import round trip lost posts.** A page slugged
  `changelog`, `index` or `tags` was dropped as a repository's own file; a
  post with an empty body was read back as an empty file and skipped; and
  `KEEP_PERMALINKS=1`, the one thing that saves a renamed address, wrote
  exactly the redirect the build throws away.

- **An imported embed's HTML is no longer rendered with its scripts, its
  style blocks or its stylesheet links.** The site's CSP already stopped
  the scripts from running, but the RSS feed carries the same HTML and has
  no CSP -- and a page's safety should not rest on one meta tag. The style
  block is the half that was never inert: `style-src` has to carry
  `'unsafe-inline'` for a post's own colour formatting, so an imported
  rule applied in full. Both Instagram embeds in the archive this was
  measured against carry `body > iframe { min-width: auto !important }` --
  a rule written for somebody else's page, reaching outside the embed to
  every iframe under this one's body. Stripped at render, so the archive
  keeps what it was given.

- **The sitemap and the feed describe the site as built.** A series
  listing was missing from the sitemap entirely; `lastmod` was chosen by
  comparing date STRINGS, which puts a post written "2026-08-22 10:00"
  above one written "2026-08-22T09:00+02:00"; and a site with nothing in
  the stream published an empty `<lastBuildDate>`, where RSS 2.0 requires
  a date.

- **The importers, all eleven adapters and the machinery under them.**
  The bounty confirmed 59 defects there and every one is closed, along
  with one reported from outside. What they cost, worst first:

  *WordPress, which is half of everything anyone migrates.* Titles and
  category names live in CDATA, so entities WordPress stored in them
  arrived verbatim while the BODY of the same post decoded them: on the
  real export this was measured against, two posts were called
  "#55: Reflection &amp; Mug" and a tag came out as "P&amp;S", pill,
  archive index, sidebar and feed alike, under the address
  /tag/p-amp-s/. A non-Latin blog fared worse: sanitize_title
  percent-encodes those slugs, so every address on the imported archive
  became hex -- "c4-8desk-c3-bd-titulek" -- matching no old address at
  all. And post_content is stored WITHOUT `<p>` (wpautop adds them when
  a page is rendered), so every post written in the classic editor --
  2003 to 2018, the bulk of any old blog -- collapsed into one
  paragraph, with the pictures that stood between the paragraphs
  appended after all the prose.

  *Posts nobody meant to publish were published.* A Mastodon archive is
  the whole account, not the public timeline: 141 of 2548 standalone
  toots in the archive this was measured against -- 132 of them direct
  messages -- were written as published posts, with pages, sitemap
  entries and feed items. A Ghost export ships the full body of every
  members-only and paid post, gated only when a page is served; they
  arrived published, untagged and uncounted. And `draft: true # not yet`
  -- a comment after the value -- made the flag a truthy STRING, so a
  Jekyll post its author was still writing went onto the open web.

  *Whole imports came to nothing, and said so as if it were the file's
  fault.* One empty column in a Wix CSV header -- what Excel writes as
  soon as any line in the file has a field too many -- marked every row
  misaligned, so an export imported as zero posts under a message about
  a quote that was never left open. A folder with no markdown in it, and
  a CSV that was not a Wix export at all, both answered "Done. 0 post(s)
  written" and exit 0.

  *Posts overwrote each other, or arrived twice.* Two feed items sharing
  a `<guid>` matched each other: the second overwrote the first in place
  and the summary counted two written. A Medium draft, a beehiiv issue
  that never went out, and a Pixelfed export in the newer wrapped shape
  each lost the account half of their identity, so re-running the
  identical command over the identical file wrote the archive a second
  time -- against the promise the tool prints itself.

  *And a long tail of quiet losses.* An Atom body written as
  `type="xhtml"` imported empty and counted as skipped; a multi-line
  TOML array turned every tag into `[`; Hugo's `static/` was looked for
  in the wrong place, so images that were on disk were reported missing.
  A Medium essay lost the section breaks its author typed; a Wix heading
  lost its links and a Wix table cell its words; a Ghost lead photo lost
  its caption. A Tumblr picture that would not download stayed behind as
  `<img src="">`, which `check` cannot see, and an NPF block type with
  no branch -- a poll, since 2023 -- vanished without a word. Facebook's
  own `<br /> `, tag plus a literal space, collapsed 190 posts of 1603
  into a single paragraph each. A permalink with one non-ASCII character
  lost its redirect. Pointed at the wrong folder, the Twitter importer
  answered with a Ruby backtrace where every sibling answers with a
  sentence. And the wizard -- the door this tool's own header calls the
  way in -- never printed what the HTML parser had thrown away, so a
  blog full of embedded video imported as "Wrote N post(s)" and nothing
  else. An address that answered 200 with an HTML page -- a parked
  domain, a soft 404 -- was saved as a picture, counted as a media file
  and called sound by `check`, leaving a permanently broken image on a
  published page; one adapter had that defence and eight carried a
  comment claiming it.

  *And the rescue of last resort learned to finish a sentence.* A feed
  that carried teasers was recognized as carrying teasers and the cut-off
  text written anyway -- page mode, which reads a whole page, was only
  ever tried for a blog with no feed capture at all. A truncated item is
  now completed from the post's own archived page, the newest capture of
  it, with the title, date and tags still the feed's; what could not be
  completed is said out loud. Reported by somebody rescuing a Drupal blog
  whose feed did exactly this.

- **A picture was lost to the difference between a Hash and a
  directory.** An importer keeps the source URL's extension exactly as it
  was, case and all, so `01.JPG` is an ordinary name in a real archive --
  Posterous served `IMG_2669.JPG`, and a decade of cameras wrote nothing
  else. The name allocator then looked for a free name with a byte-exact
  comparison and handed a newly arrived picture `01.jpg` believing it
  free, while the copy asks the VOLUME whether the destination exists --
  and on macOS, or any Windows share, `01.JPG` answers for `01.jpg`. The
  copy was skipped, the new picture's bytes were never written anywhere,
  and the post showed the OLD photograph under both names; `check`
  reported a reassuring "misnamed" and said nothing about a loss. Names
  are compared the way the filesystem compares them now, on every volume
  rather than only where it bites: an archive is carried between
  machines, and a name that is free on Linux and taken on macOS is a
  picture that disappears when somebody moves their site.

- **Smaller, and there were many.** A tag containing a comma became two
  tags on every save (six posts on one archive). `props` and `edit` died
  on a raw backtrace over a date `check` names cleanly. An unknown block
  type wrote raw JSON into the page and escaped its own `<pre>`. A post
  with a hero printed a link's borrowed title twice, and lifting that hero
  removed every block equal to it, so a post showing one photograph twice
  lost both. A post made of code or chat escaped the excerpt clip and was
  dumped whole onto the front page. A non-integer `page_size` built
  addresses like `/page/0.38095238095238093/` and exited 0. A comment's
  picture with no description was a link with no accessible name. Every
  `<nav>` on a page has a name now, and the narrow-screen menu no longer
  leaves a 40px link floating in a 60px row.

### Not fixed, on purpose

- **A listing card renders the whole post and lets CSS clip it.** On one
  real front page that is 49,312 of 50,659 characters inside the clip and
  33 of 154 focusable elements reachable by keyboard but invisible on
  screen. Nothing bounded fixes it -- `inert` would kill the visible half
  too, and where the cut falls is CSS's to decide. The honest answer is a
  card that renders a real teaser, which is a design decision rather than
  a bug fix.

## 1.4 -- 2026-08-25

The widest release since 1.0, and the most thoroughly tested one. Three
things arrived: the commits widget reads Gitea and Forgejo (the release's
reason to exist -- most of the Fediverse hosts its code there), comments
work on GoToSocial with the same favourite-moderation Mastodon has, and
the whole engine now speaks the site's language everywhere -- deploy,
build warnings, announcement failures, import errors, all of it, in en,
cs and de alike. Underneath sits a long audit over real archives: one
address guard that publish, edit, scheduling, restore and re-import all
ask before writing anywhere; a queue that can swap two same-slug posts
across years with their media and edit history riding along; deploy
backends that survive hostile filenames, rerouted targets and unreadable
manifests; and a check that never again calls an archive sound when the
build would refuse it. Nothing to migrate -- `git pull`, rebuild, deploy.

### Added

- **The commits widget reads Gitea and Forgejo, not just GitHub.** Asked
  for by one of the first people outside this project to run the engine:
  most of the
  Fediverse hosts its code on Codeberg or its own Forgejo, and the
  workaround was to mirror to GitHub for the sake of one sidebar card.
  `widgets.commits.instance` takes the server's address and that is the
  whole configuration -- an address already answers which kind of host it
  is, so there is no second key to keep in agreement with it. Without the
  key nothing changes. The forge path costs **one** request where GitHub
  costs one per commit, because a Gitea activity item carries the commits
  it is about, message and timestamp included; `doctor` refuses a handle and a bare
  host name outright, and flags an address with a path after it (a profile,
  a repository -- but also a forge that genuinely lives under one) as worth
  checking rather than wrong, pointing at `<instance>/api/v1/version` to
  settle it. Either way the answer arrives before the card turns out empty
  and indistinguishable from "has not pushed lately".
  Verified against two live servers before it was written.
- **Media are read from the year the post's FILE lives in.** A post whose
  date was corrected across a year boundary keeps its file (and its media)
  where they were, while its address follows the date -- and the build was
  the one place that looked media up by the date. It served the page with
  a hole in it and said "MISSING media", while `check`, which looks where
  the file is, called the archive sound. They agree now, and on the first
  build after this upgrade such a picture is copied for the first time.
  This one predates 1.4 by a long way; the repair pass is only what made
  it visible.
- **Letter case and unicode form of a filename no longer cost you the
  picture.** `File.exist?` asks the volume, and on macOS the volume
  resolves both -- so a post naming IMG_2043.JPG found img_2043.jpg and
  rendered, while anything comparing the strings called the same file a
  leftover. The engine now asks the directory what it actually writes: at
  build time (the copy is renamed rather than left for the prune to
  delete), in the markdown editor (the name from the disk is what gets
  written into the post), and at deploy time (an "orphan" that is only the
  old spelling of a file the build still has is not deleted). If your
  archive has such a pair, `check` now says so and `--repair` offers to
  write the name the directory uses.
- **The deploy manifest knows which target it describes.** Pointing the
  same backend at another target used to inherit the old manifest, which
  says everything is already there -- so the new target stayed empty and
  the run reported success. A manifest written for another target is now
  thrown away out loud. What counts as "another target" ignores the things
  that cannot move a connection: the order the switches are written in, and
  `-v` or `-q` added to watch a run. Reformatting a line in `env.sh` is not
  a move, and treating it as one would throw away the only record of what
  stands on the far end -- for `sftp` that record is what finds the files
  you have deleted since. Only a digest of those switches is stored, so the
  key path and jump host in `env.sh` stay in `env.sh`.
- **`./style.sh` can take a sidebar widget away again.** Adding one was the
  only direction on offer, so a widget switched on by mistake -- or one
  whose account no longer exists -- could be got rid of only by editing
  `config/site.yml` by hand. The widget menu offers the removal whenever
  something is switched on, and what it writes is the block commented out
  rather than deleted: the heading, the account id and the template's own
  prose stay in the file, so switching the widget back on later is one
  answer instead of typing it all again.

### Changed

- **`check` has a ninth kind of finding: two posts that would be served at
  one address.** The build refuses to run in that state -- one post would
  be written over the other and their media mixed -- so a check that
  called such an archive sound was telling you the opposite of what you
  were about to find out. It is an error, so `check` can now exit 1 where
  it used to say nothing.
- **`doctor` fails on a config the engine cannot use.** It knew about
  three list keys; it now reports the same set of complaints the build
  warns about -- a widget name nothing draws (which takes the whole
  sidebar off every page), a section written in a shape it cannot hold,
  a menu item with no label or no target, and prose written as a list.
  Configs that were quietly wrong will start saying so.
- **Renaming a post writes its redirect from the address the site actually
  served.** For a post whose date was corrected across a year, and for
  every page (which has no year in its address at all), the old address
  was derived from the folder -- so the redirect pointed at an address
  that never existed, and the build refused it with a warning nobody could
  act on. Editing, publishing, unpublishing and re-importing now answer
  that question in the same one place, which is what made the next entry
  visible.
- **Two pages sharing a slug stop being a silent loss.** A page is served
  at the root, so two of them with one slug collide however far apart
  their dates are -- and the build wrote both and served whichever came
  last, with nothing said anywhere. The build now names both files on
  every run, `check` calls it an error and reports it at `/slug/` rather
  than at an address with a year in it that no page ever had, and the
  paths that write a post refuse to create the pair in the first place.
  The build warns rather than stops on purpose: publishing runs from cron,
  where nobody is at the keyboard to read an abort, and a site that
  already has such a pair should keep being served while its author
  decides which page keeps the address.

- **`./blog.sh check --repair`: the checker's other half.** Until now
  `check` could say what was wrong with an archive and nothing more, so
  acting on it meant a hand-written script that re-derived what the checker
  already knew -- which is exactly what the sean.cz cleanup in August was.
  `--repair` walks the findings and offers, one at a time, the single
  repair each one allows; nothing is applied without a key press. Three
  rules hold throughout: **add rather than rewrite** (a dead link is
  repaired on the target post's `redirect_from`, one added line, the
  author's own text untouched, and every link to that address answered at
  once -- including the ones from outside that no check can see);
  **never delete** (an unreferenced file goes to the trash `restore` reads);
  and **nothing twice** (a repaired archive proposes nothing on the next
  run). Where the answer is a matter of judgement -- a collision between two
  posts, an image somebody has to look at, a link to something the archive
  never had -- it says so and passes over rather than guessing. Behind it,
  the same lookup that made the August cleanup possible: an exact slug, or
  a prefix when an import truncated one, and no proposal at all when two
  posts could both be meant.
- **`./blog.sh check --json`: the findings themselves, all of them.** A
  finding used to be a finished sentence and nothing else, and the lists
  were capped at twenty of a kind by the time anyone saw them -- so the
  rest was not merely unprinted but never built. Findings now carry the
  kind they are (`link_dead`, `media_stray`, `series_similar`...) and the
  data they are about (the post's slug, the address, the file), the cap
  belongs to the screen, and `--json` prints the whole list. This is what
  makes acting on a check possible at all: the archive cleanup that took a
  hand-written script over sean.cz in August could have read this instead.
  The screen is unchanged, built from the same objects, and the exit code
  is the same in both modes.
- **Icons for Gitea, Forgejo, Codeberg and GitLab** in the footer's set, so
  a site that hosts its code outside GitHub can say so with the same row of
  icons everything else uses.


- **A key that is written down speaks for itself.** `nav:` left standing
  with nothing under it used to fall back to the menu the engine picks,
  while the same emptiness under `links:` meant no links -- one editing
  accident, two opposite answers, and the one that looked unchanged was the
  menu. An empty `nav:` now means no menu, the way an empty `links:` has
  always meant no links. **Upgrading:** a site that deleted its menu entries
  but kept the key gets no menu now; write the entries back, or delete the
  key to ask the engine for its own menu again. A site without a `nav:` key
  is unaffected, which is every site that never set one.
- **The sidebar column goes with its last card.** A site with no about text
  and no widgets kept an empty `<aside>`, and the grid kept the 260px beside
  it: the article sat in a narrowed column with a blank strip alongside,
  space held for furniture that was never coming. The column is now drawn
  when there is something to put in it -- `layout.sidebar: false` still
  turns it off outright, and a site with an about text or a single widget
  renders exactly as before.

- **The whole engine speaks the site's language.** The wizards and the
  everyday commands were translated; the narration around them was not --
  a Czech or German site watched its own deploy, its build warnings, its
  announcement failures and its import errors go by in English, one line
  above a translated sentence. Sixty-odd sentences moved into the
  locales: the deploy's progress and closing tally, all eleven build
  warnings, every Bluesky and Mastodon failure, the import errors that
  surface through the interrupted-source report, the queue's repair
  instructions. What a server sent back (an HTTP code, a raw answer)
  stays as it arrived; the sentence around it is the site's. Counted
  lines are written label-then-number, so no language has to decline
  "1 posts".

### Fixed

- **Comments work on GoToSocial.** Two separate things were in the way,
  and the site they were found on -- arch-linux.cz, the install that
  prompted 1.3.2 -- had never shown a single comment under any post,
  silently. First, the address: GoToSocial writes a status as
  `/@user/statuses/<ULID>` and the engine knew only Mastodon's
  `/@user/<digits>`, so nothing was ever fetched. (The obvious repair is a
  trap: widening the Mastodon pattern alone makes it match first and read
  the literal word "statuses" as the status id, which turns an honest
  nothing into a request for a status that cannot exist. The patterns are
  ordered most-specific-first now, in the Ruby and in the browser alike.)
  Second, and worse: GoToSocial requires a token on every read of a
  thread, so the live mode -- where the visitor's own browser fetches the
  replies -- cannot work there at all, whatever the address looks like.
  `comments.approval: fav`, where a cron reads the thread with a token and
  only the replies you star reach the page, is the whole of what is
  available; `doctor --online` now asks the server whether an anonymous
  reader gets a thread and says which of the two you have. A Mastodon in
  secure mode is in exactly the same position, which is why the check asks
  about the capability rather than about the name of the software. An
  address the browser cannot read at all now leaves the "reply" link
  standing instead of an empty space.
- **An install in a folder called `blog [1]` no longer publishes an empty
  site.** Every listing the engine makes -- the archive, the built pages,
  the media, an unpacked export -- was built by pasting the directory's own
  absolute path in front of a pattern, and a path is not a pattern: `[1]`,
  which is what a second copy of a download gets called, reads as "one
  character, and it is `1`". The listing then described a directory named
  `blog 1`, nothing was there, and nothing said so. `build` reported 0
  posts over a full archive and wrote a site with nothing in it, `deploy`
  refused with "public.nosync/ is empty" -- and refusing was the lucky
  ending, because a backend that commits whatever it is handed would have
  pushed that emptiness live -- while `check` called the archive sound,
  since it could not see the posts either. An export unpacked into
  `Takeout [1]` was read as no export at all, for the same reason; `{`, `}`,
  `*` and `?` in a folder name did the same thing more quietly, and `*` did
  it while matching the WRONG directory rather than none. Directory names
  are read as names now, everywhere, and the import wizard's Tab completion
  offers such a folder instead of going silent over it. **Upgrading:**
  nothing to do -- if this was your install, the first build after the
  upgrade finds your archive again.
- **A post whose slug carries `[`, `{`, `*` or `?` is no longer invisible
  to the commands.** The other half of the same join: the post's own name
  went into the pattern. A post called `foto[1]` was published by `build`,
  shown by `list` and passed by `check` -- while `props` and `delete` said
  "post not found" over it, `restore` called the trash empty with its files
  sitting in there, and the guard that asks whether an address is taken
  reported it free, which is the answer that lets a new post be written
  over a live one. `--repair` was in the same position and could have set
  aside a picture the post was using. A `*` did worse than vanish: it
  matched the posts NEXT to it, so a command asked about `star*` offered
  `starec` as though the two were one name. The engine's own slugs are
  `[a-z0-9-]` and never carry any of this -- a file edited by hand does, an
  archive written by something else does, and so does an old address an
  import writes down, spelled the way the old site served it.
- **A bracket in an alt text no longer destroys the picture.** `![[es]
  W-ZERO3](...)` -- a real caption on a real photograph -- was a line the
  markdown reader could not parse, so the next `edit` turned the image
  block into a paragraph of literal markdown, the file was pruned as
  unreferenced a moment later, and the page then printed the author's
  absolute disk path as text. `check` said nothing about any of it, and the
  post could not be edited back into shape either.
- **`--prune` deletes what the deploy named, and nothing else.** On the
  `rsync` and `rclone` backends it did not prune, it MIRRORED: everything
  on the far end this build had not produced went with it -- the ACME
  challenge a certificate renewal was standing in, an old blog kept in a
  subdirectory, a hand-written robots.txt -- while the run reported
  "deleted 2", because two is what the manifest knew about. A static site
  generator is a guest on that directory, not its owner.
- **An interrupted sftp transfer resumes.** A run killed at file 48 of 159
  recorded nothing, so the next one started again from the first -- and on
  a slow line a deploy that always restarts is a deploy that never
  finishes. What landed is written down now, whether or not the run
  finished, and the summary says so.
- **A full disk ends a deploy with a sentence.** It used to be a raw
  traceback out of the state file's write, with nothing said about what had
  or had not been uploaded.
- **Announcing a page linked to an address the site does not answer at.**
  The toot (or Bluesky post) for a new page carried `/posts/<year>/<slug>/`
  -- and that same URL is what finds the announcement again later, to
  update or withdraw it.
- **A post taken back down keeps its discussion off the site.** `comments.json`
  and `stats.json` were merged and never narrowed, so a withdrawn -- or
  deleted -- post kept its whole approved discussion readable at a public
  URL, which is exactly what taking a post down is meant to prevent.
- **An import that loses an item says which one, and exits 1.** "1 skipped
  (error)" in a run that scrolled past a hundred lines of progress named
  neither the item nor the reason, and the exit code was 0, so a cron or a
  CI step saw a clean run. The sentence about pages that came across is
  also built from what was WRITTEN now: it used to announce a page the
  write had refused, and point the reader at somebody else's.
- **The Twitter import stopped leaving `&lt;` and `&amp;` in the text** --
  and, worse, in twelve permanent addresses, as `-gt-` and `-amp-`. The
  entities are decoded after the offsets that need them, so every link
  still lands on its own words.
- **The Facebook import says what it does not take.** Albums, uncategorised
  photos and videos sit beside the timeline in the export and this adapter
  reads none of them -- which is a decision, not an oversight, and one the
  summary now states instead of leaving somebody to discover it months
  later by missing a picture.
- **`doctor` stopped ticking three things that were not fine**: a queue
  whose posts are days past their date while the runner is alive and
  failing on every tick, a site that owes a deploy nothing else was
  reading, and a menu whose items lead to tag pages the build does not
  make. `check` no longer counts a tag page into existence from a draft.
- **The scheduler's quiet tick is quiet.** The documented crontab runs it
  every fifteen minutes and almost every one of those has nothing to do;
  saying so on stdout is ninety-six mails a day, which is how the ticks
  that matter get ignored. It also writes down that a deploy is owed
  BEFORE it publishes, so a run killed between the two -- a restart, a
  `docker stop` -- no longer leaves a post published, announced and never
  uploaded, with nothing anywhere saying so.
- **`./style.sh` can point the commits widget at a forge.** The card reads
  Gitea and Forgejo since this release, and the wizard went on asking for a
  "GitHub username" with no way to say anything else. A palette that leaves
  colours out no longer writes them as empty values (which took `doctor`
  down with twelve complaints); and a banner file that is not there says so
  out loud, instead of into a frame a piped run never paints and a terminal
  cuts in half -- with a green "Measured: 1880x600", the OLD banner, right
  underneath. A banner replaced by an image of the same name and the same
  size is installed at last -- and so is a stylesheet or a font file put
  back beside a `site.yml` that already names it: nothing in the config
  moved, so the run ended on "nothing changed" and dropped the copy it had
  promised a moment earlier, leaving the file in `incoming/`. Every file a
  run would copy in is listed in the review as the change it is, confirmed
  together with everything else, and copied in only after that -- nothing
  reaches the install before you say yes. Answering the banner question
  with the picture already installed, which is what you type to re-measure
  artwork you replaced by hand, says so and copies nothing, instead of
  ending the run on a Ruby backtrace.
- **Turning a post into a page (or back) no longer loses its address.**
  `type: page` typed into the frontmatter -- or deleted from it -- moves a
  post between `/posts/2026/slug/` and `/slug/` without touching the date,
  and nothing was recorded behind it: every existing link to the address it
  left died, and `check` called the archive sound. The redirect is written
  now, whichever direction the change goes, and a re-import that does the
  same thing behaves the same way.
- **The build and `check` read `unlisted` with one rule.** The build has
  always taken the hand-written spellings -- `"no"`, `"false"`, `"0"` keep
  a post IN the stream -- while the checker read bare truthiness, so the
  two disagreed about which tags and series have a listing page, and
  `check` reported a live page as a dead link, forever. One predicate now,
  in one place, asked by the build, the checker and the publisher alike.
- **A tag too long for a filename no longer stops the build.** The address
  of its listing page would not fit (`mkdir` died with a raw
  `ENAMETOOLONG`, partway through writing the site); such a tag now shows
  on its posts -- as a pill that is not a link -- and the build says in one
  sentence that no /tag/ page is made for it. A tag that is not text at
  all (a number, a leftover object out of a hand-edited file) is rendered
  as text instead of ending the build in `escapeHTML`. **Upgrading:** the
  cap is 200 bytes of address, which is under the 255 a filename is usually
  allowed -- so a tag between the two used to get its page and no longer
  does. The first rebuild takes that page out of `public.nosync` and the
  next deploy takes it off the server; a link to it from outside 404s from
  then on, and the engine itself stopped writing one.
- **The feed stopped naming categories nothing stands behind.** A tag that
  folds away to nothing -- emoji-only, punctuation-only, the kind an
  Instagram or Tumblr export hands over verbatim -- has no listing page and
  is drawn as no pill, and was still written into every `<item>` as a
  `<category>`. A reader that groups by category offered a subject this
  site does not publish under and cannot be sent to. The pills, the tag
  pages and the feed read one rule now.
- **The search box folds a word the way the index folded it.** The Ruby
  that writes `search-index.json` and the JavaScript that reads it had
  drifted apart on what counts as whitespace: the browser collapsed
  everything Unicode calls a space -- a no-break space, a line separator --
  and the index only what ASCII does, so a title carrying one could not be
  found by typing it out exactly. The browser now collapses what Ruby's
  `\s` collapses and no more. Both sides also fold the Greek final sigma
  `ς` onto `σ`, which is the same letter in the middle of a word: a query
  and a title spelling it differently used to be two different words to the
  search. The index is rewritten by the next build; no post file changes.
- **A draft's tags no longer link to pages that do not exist.** Tag listings
  are made from the stream, so a tag carried only by drafts, unlisted posts
  or pages never gets one -- and the pill for it was a link into a 404. On
  one real archive that was ten dead links across nine drafts, every one of
  them written by the engine itself. Such a tag is still shown, because it
  is what the post is about; it is simply not a link. Nothing changes for a
  published post, whose every tag has a page by construction.
- **Two posts sharing a slug in two years can trade places in the queue.**
  The engine has always treated a slug repeated in another year as
  ordinary. The queue did not: each half of the swap found the other
  standing exactly where it was going, and the screen ended with "resolve
  this manually" -- a thing there was nothing to resolve, since the two are
  each other's obstacle and neither can move first. Both halves are still
  checked before either is written, and a swap that would land two posts on
  one address is still refused. Everything keyed by year and slug trades
  together: the posts' pictures and their edit histories step aside with
  the files and land in the year each post moves to -- treated as leftovers
  of a move, one post ended with the other's picture on its page and the
  other's history deleted outright. A failure partway puts both posts back
  as they were found -- name and date together: the half that had already
  landed used to keep its new date in its old folder, which for a pair
  sharing a slug is the other post's address, so the recovery itself
  handed back an archive the build refused to run on until somebody
  repaired it by hand. Anything a hard crash still strands under a working
  name is reported by `check`, which asks whether the post inside it is
  still in the archive somewhere before it says what to do: a copy of a
  post that landed is named as a leftover to remove, a parked file that is
  the only copy of its post is named as exactly that, and neither is ever
  advised over the top of a post standing at the same name. The list a
  failure prints says what each post is really doing rather than sending
  you to a "see below" with nothing below it.
- **A media file nobody can read is now a finding, not a presence.**
  `File.exist?` said yes and a reader said no -- to a file of zero bytes
  (an interrupted download), to one without read permission, and to a
  folder sitting under a picture's name. The page shows a broken picture
  either way, and the copy to the server either carries the defect or
  stops the build. `check` reports all three as their own kind of error,
  with a sentence that says what is actually wrong -- not "missing from
  its media directory" about a file somebody is looking straight at.
- **The CSP for a Bandcamp player follows the stored player address.** The
  policy used to name the bare `bandcamp.com` for every such block; the
  engine's own lookup happens to store players on that host today, but the
  engine accepts a stored address on any artist subdomain -- and for those
  the fixed policy would have blocked the exact iframe the page had just
  written. The policy now names whatever host the block's player is on,
  and a block with no player asks the policy for nothing.
- **The wizard writes the `env.sh` line the shell actually reads.** `env.sh`
  is a shell script: every line runs, so a name written twice is decided by
  the last one. `./setup.sh` rewrote the first, said it had saved, and left
  the old value in force -- with the diff on screen to prove it had worked.
- **The import wizard's advice about the Wayback Machine now applies to
  itself.** `WAYBACK_DELAY` and `POST_PATTERN` -- which a run recommends by
  name when the Archive throttles it or its paths cannot be told apart --
  were read only by `scripts/migrate_wayback.rb`. Somebody followed the
  advice, started `./import.sh` again and nothing changed; an archive that
  needs `POST_PATTERN` had no way out of the wizard at all. Both paths read
  the same variables from one place now -- and both refuse nonsense with a
  sentence: a delay that is not a number used to mean *no* throttle at all
  (set by somebody trying to be gentler), an empty pattern matched every
  archived path, and an unusable one dumped a parser backtrace over the
  wizard.
- **A wizard import whose source died, or that failed to write items, ends
  with a non-zero status.** The scripted importers have carried exactly
  those two failures in the exit code since 1.2; `./import.sh`, which is
  what people actually run, returned 0 for both. (A missing media file
  alone stays exit 0 on every path, scripted and wizard alike: the posts
  were written and the report says which files were not.) The preview also
  claimed that media it could not fetch had had "their posts written
  without them" -- a preview writes nothing.
- **`check --repair` says whose archive it is and that it is working.** It
  walked thousands of posts with nothing on screen at all: no header naming
  the installation it was about to change, and no sign it was doing
  anything, for minutes. It opens the way `check` does and counts as it
  reads.
- **The "not understood" line in `props` names the keys the row offers.**
  The row grows `[v]` once a post has older versions and `[t]` on a site
  with a network, while the refusal was a second, hand-kept list that never
  learned either -- so the dialog offered a key and then denied knowing it.
  The sentence is read off the row itself.
- **A list key that held something else ended the build in a traceback.**
  A string under `social:` (a URL pasted where a list of them belongs), or
  anything but a list under `footer.links` or `nav:`, reached `.map` and
  stopped the build with a `NoMethodError` naming a line in the engine --
  while `doctor` called the same config healthy and exited 0. The build now
  reads a wrong shape as empty and carries on, and `doctor` names the key
  and fails the install, which is where a config mistake belongs. A key
  with nothing under it stays what it has always been: none of them, and
  no complaint.
- **Two markdown trees no longer overwrite each other.** A tree import
  identified its source by the name of the directory it was pointed at,
  and "content" is what Hugo calls that directory on every site there is
  (as `_posts` is for Jekyll). Import two blogs one after the other and
  the second one did not arrive beside the first: it matched it, post by
  post, and replaced it in place -- the same machinery that makes a
  re-import an update rather than a duplicate, aimed at the wrong archive.
  The identity is now the name the site gives itself -- `baseURL` or
  `title` out of Hugo's configuration, `url` or `title` out of Jekyll's
  `_config.yml` -- so two blogs are two, and the same one still recognises
  itself after it has been moved, renamed or unpacked on another machine.
  A tree that declares nothing (a bare `content/`, a converter's dump, a
  skeleton nobody has edited) falls back to the path it was imported from,
  which tells trees apart but only while each stays where it was;
  docs/importing.md says which is which. One consequence worth knowing
  before you upgrade: a tree imported under an earlier version and
  imported again under this one is no longer recognised as the same source
  and will come in a second time. Import first, upgrade after -- or expect
  to delete one copy.
- **A Hugo site root imports the site's content, not its machinery.**
  Pointing at `~/mysite` rather than `~/mysite/content` is what a person
  naturally does, and it went badly in a quiet way: with nothing at the
  top level of what was walked, nothing could be recognised as a page and
  nothing as the site's own furniture, so `content/_index.md` (the front
  page), `content/about.md` and even a template out of `layouts/` all
  arrived as articles dated the day of the import. A folder holding
  Hugo's own configuration next to `content/` is now read as the site it
  is -- content imported, the rest left alone, and the summary says so
  rather than leaving anything you keep outside `content/` to go missing
  without a word. It holds for a `content/` with no sections in it as
  well, which is where the first attempt at this stopped short: a flat
  one got the narrowed walk and none of the reading it is for. Without
  that configuration nothing is guessed at and the named folder is walked
  exactly as before -- and if the site folder keeps markdown of its own at
  the top, that is what happens and the summary now names the file that
  decided it, instead of leaving the whole decision unsaid. Separately, a
  section listing (`_index.md`) is furniture wherever in the tree it sits:
  one per section used to come in as a post called "index" whose body was
  the section's blurb. A branch bundle is not one of them -- a directory
  whose only markdown is its `_index.md`, carrying prose or files of its
  own, is the page somebody wrote that way, and it comes in under the
  directory's name.
- **The albums in a Facebook HTML export are counted.** The summary's
  sentence about what an import does NOT take -- uncategorised photos,
  albums, videos, all of which stay in the download -- counted albums by
  looking for `.json` files, which an HTML export does not have. It
  therefore said "albums (0)" over an export with a shelf of them, which
  is worse than not mentioning albums at all: it is an answer, and it is
  wrong. It counts in the format the export was actually downloaded in.

- **A link imported with an active-content address is defused.** An
  archive the author did not write -- a multi-author blog, a reblog, a
  scraped source -- can carry `<a href="javascript:...">`, and escaping
  quotes does nothing about the scheme: the link rendered live into every
  page and the RSS feed. An href now passes an allowlist (http, https,
  mailto, tel; no scheme at all is a relative link and always passes),
  the same stance embeds have always taken, and anything else becomes a
  dead anchor. The text of the link stays; only the trap is removed.
- **A broken colour cannot take the stylesheet down.** Colour values were
  written into `colors.css` verbatim, so a `;` or a comment marker in one
  -- a hand-edit typo, an imported palette -- silently ended the file
  mid-rule and the site rendered undressed. Colours now pass the same
  guard the fonts already did: a value that cannot go into CSS is named
  out loud and the shipped default stands in.
- **The git backend ships the bytes the build produced.** A user's global
  `core.autocrlf=true` rewrote the line endings of every text file on the
  way into the snapshot commit -- a served file no longer matched its own
  integrity hash, and a diff nobody made appeared on the site. The
  snapshot commit now pins `autocrlf=false`, alongside the existing
  defences against global ignore files.
- **rsync and sftp carry a filename their own tools would misread.**
  rsync reads a `--files-from` line starting with `#` or `;` as a
  comment, and an `--include-from` line starting with `-` or `+` as a
  rule -- so a file called `#draft.html` never uploaded (while the
  manifest recorded it delivered), and an orphan called `- old.html` was
  never pruned (while the manifest forgot it). sftp's own client read the
  leading dash of `- old.html` as a flag, whatever the quoting. Names are
  now written in forms the tools take literally -- `./` in front for the
  lists, explicit `+ /` rules for the filter -- and everything lands, and
  prunes, under its own name.
- **Rerouting a deploy no longer inherits the old target's manifest.**
  What `RSYNC_SSH` and `RCLONE_ARGS` carry -- a port, a key, an ssh
  config, an rclone `--config` -- is part of where the files go, and a
  manifest describing the old machine says everything is already there:
  the new target stayed empty while the run reported success. Both now
  fold their routing into the manifest identity, the same way sftp
  already did; a changed route means a full upload, which is always the
  safe direction.
- **A manifest the process cannot read or write degrades, it does not
  crash.** A manifest left root-owned by one sudo run -- the uid trap
  this project keeps walking into on its own servers -- killed every
  later deploy with a raw backtrace, and a full disk at the periodic
  mid-upload save killed a working transfer at the 25th file. Both now
  degrade with a sentence, the way the baseline always has: an unreadable
  manifest costs one full re-upload, an unwritable one costs the
  bookkeeping, and neither costs the deploy.
- **`doctor --online` keeps the token at home.** The favourite-visibility
  probe tested whatever announcement was newest -- and on an archive
  carrying a legacy or imported one, that could be a host the site does
  not run on, handing a foreign server a credential that can post as the
  author. The probe now refuses a foreign host with a sentence (the
  fetches always have), and doctor picks the newest announcement on the
  configured instance to test against instead.
- **`doctor` diagnoses a broken config in the site's language.** The one
  scenario doctor exists for -- a `site.yml` that will not parse -- was
  the one where it fell back to English, because reading the language
  used the very parse that had just failed. The language is now dug out
  of the raw file when parsing fails, so the syntax-error diagnosis
  arrives in the language the site was written in.
- **`check` refuses everything the build refuses.** Four ways an archive
  could be unbuildable slipped past it: a post file that is not valid
  UTF-8 (the build dies deep in the JSON parser, naming no post), a post
  whose text is not a list of blocks, a slug that is not one path
  segment (a `/` or a `..` in it walks the page out of the build tree),
  and an archive whose every file is unreadable -- reported as "empty",
  exit 0. All four are findings now, and check exits non-zero on each,
  because an archive check calls sound must be one the build will run on.
- **A crash in the middle of a queue move cannot cost a post.** The swap
  writes were already checked and parked; what remained was the
  aftermath. A recovery that ran after the second write failed could
  restore the partner into a collision with the mover's new date -- two
  posts on one address, build refused. And `check`'s advice about a
  parked leftover asserted "the post it belongs to is back in place"
  from the file's name alone -- when after a hard kill the parked file
  can be the only copy of a post there is, and following the advice
  destroyed it. The recovery now steps the finished mover back to its
  original bytes when keeping the new date would collide; the crash
  report lists what actually happened to every post; and check decides
  stale-or-not on the parked post's own identity: proven-stale names
  where the live copy sits, unproven says plainly this may be the only
  copy -- compare, rename back under a free name, never delete.
- **"Nothing was written" is true across both files.** setup writes
  `site.yml` and `env.sh` in turn, and a refusal on the second left the
  first already replaced -- the two out of step, under a message swearing
  nothing had changed. Every file is checked for writability before the
  first is written, the refusal names the actual obstacle (the directory,
  the file, or a genuinely present `.bak` -- not a `.bak` that is not
  there), and a refused or rolled-back write ends the wizard with a
  non-zero exit instead of a quiet success.
- **An answer of "y" means yes in every language, in every dialog.** The
  import wizard's keep-permalinks question compared the key against the
  localized yes-character alone, so on a Czech install -- whose prompt
  reads `[a/N]` -- a reader pressing `y` out of habit got "no" silently
  and lost every old address the flag exists to keep. Two dialogs in
  `props` did the same and were missed the first time round: renaming a
  slug answered "Cancelled" to anything but the local character, and so
  did dropping an old address, so on an English or German install the
  habit of pressing `a` read as a refusal. `y`, `j` and `a` all mean yes
  now, everywhere, out of one definition rather than four. And `FACEBOOK_CROSSPOSTS=yes` -- the obvious
  guess -- aborts with a sentence instead of silently meaning "no", the
  same guard `KEEP_PERMALINKS` already had.
- **Enter backs out of "add one" everywhere, and a pending copy is a
  listed change.** Answering nothing to a social icon crashed the whole
  style run with a backtrace (and every answer of the session with it);
  answering nothing to a footer link wrote an empty `<li>` onto every
  page. Both read as "never mind" now, like their sibling sections
  always did. And a banner -- or a stylesheet, or a font -- replaced by
  a file of the same size no longer vanishes into "Nothing changed":
  every pending copy is a line in the review, confirmed and installed
  with the rest, or dropped untouched on a "no".
- **Two examples in the markdown cheat sheet had stopped playing.** The
  audio one named a SoundCloud track that is gone, and SoundCloud answers
  a missing track with its app shell and a straight-faced 200 -- the same
  false success the Wayback importer already counts; the PeerTube video
  was gone as well, and its id still had the valid 22-character shape. So
  neither line looked wrong until somebody pasted it and got an empty
  player, which is the worst way for a cheat sheet to fail: it is where a
  reader goes to find out the gesture works at all. Both were replaced
  with addresses checked against the services rather than guessed at, and
  the Vimeo, Spotify and YouTube examples were checked the same way and
  are all still playing. **Upgrading:** `/markdown/` is built on every
  site, so this page is one of the files your next deploy carries.

## 1.3.2 -- 2026-08-21

A GoToSocial release, both fixes reported from the first blog.sh site
paired with one (arch-linux.cz). GTS speaks Mastodon's API but answers
with its own accents -- ULID account ids, and content negotiation on
Accept -- and two places in the engine assumed the Mastodon dialect was
the only one. It also carries one small thing for skins, from the same
site: a listing page now says whether it is the first one. Nothing to
migrate -- `git pull`, rebuild, deploy.

### Added

- **A listing page now says whether it is the first one.** `<body>` on a
  listing carries `page-first` or `page-cont`, so a stylesheet can tell the
  front page of a listing from its `/page/N/` continuations -- something CSS
  cannot work out on its own, since it cannot read an address. Both skins
  written against this engine wanted the same thing (a lead card on one, a
  profile block on the other) and neither could have it. Both sides are
  named rather than only the continuations, so a skin scopes its additions
  positively instead of writing them unconditionally and undoing each
  property further down. Post pages keep a bare `<body>`. Every listing page
  changes by those bytes, so the next deploy after this upgrade will carry
  them; nothing else moves.

### Fixed

- The feed widget (and the Pixelfed widget, and the feed importer) asked
  every host for `application/json` first, and a server that negotiates
  content by Accept -- GoToSocial's profile feed for one -- answered
  exactly as asked: with a JSON Feed the XML parser then reported as
  "Malformed XML". Feed readers now ask for RSS/Atom first, and keep
  asking for it across redirects; API callers keep JSON. The same GTS
  feed URL that failed now renders as a sidebar widget.
- `doctor` and `./style.sh` refused every GoToSocial account id: the
  check demanded digits only (Mastodon's shape), while GTS answers the
  same lookup endpoint with a 26-character ULID -- so the id the setup
  points you at was rejected by the very tool that asked for it, on a
  value the fetcher handles fine. Both gates now accept numbers and
  letter-and-digit ids (ULIDs, Pleroma flakes) while still catching the
  mistake they exist for: a pasted @handle or profile URL.

## 1.3.1 -- 2026-08-20

A bug-fix release about three things. The publishing queue: what the cron
may announce, what order it publishes in, and who may write the queue while
somebody else is reading it. The first hour of an install: what a site with
no deploy target yet is told about where it is, and in which language. And
what emptiness means: a config section emptied on purpose stops crashing
the build, failing `doctor` and leaving headings over nothing -- and `check`
now sees the links that resolve against the post instead of the site.
Nothing to migrate -- `git pull`, rebuild, deploy.

### Fixed

- **The scheduled-publish cron announced backdated posts as if they were
  news.** The recency window that keeps a post dated far from today from
  being announced automatically was a constant inside the interactive CLI,
  so only the path with somebody at a terminal ever honoured it. Putting an
  old post through the queue -- an archived thread given a page of its own,
  a release written up after the fact -- therefore dropped years-old pages
  into a live timeline, and an announcement cannot be recalled. The cron
  declines on the author's behalf now: the post is published, the skip is
  said out loud per post, and the line names `./blog.sh toot <slug>` for
  sending it by hand. A cron that has been down longer than a day is the
  deliberate cost of that -- those posts publish without announcements, and
  say so.
- **A post that had already been announced could be announced a second
  time.** The second toot does not replace the first: it stands beside it,
  live, while the URL stored on the post points at the new one and the
  original thread's replies stop being reachable from the page they belong
  to. A post reaches the cron in that state after being unpublished and
  re-scheduled, or re-dated by hand. Any post carrying an announcement of
  its own (`mastodon_url`, `bluesky_url`, `bluesky_uri`) is now published
  and left alone. This is the half the window above cannot cover: a
  backfilled post given today's date sits inside it.
- **Posts that came due in the same tick were published in alphabetical
  order.** The queue was read with `Dir.glob` and never sorted, so the
  order was the order of the file names. On an ordinary tick that is
  invisible -- one post is due. It shows after the cron has been down: a
  morning's worth of posts comes back at once and is published, and
  announced, backwards. They go out oldest first now, in the order the
  queue was arranged in.
- **The guard against a second announcement only covered the cron.**
  `unpublish` keeps a post's announcement address precisely so a later
  publish can see one exists -- and prints a promise to that effect --
  but the publish path never looked: a draft carrying its old URL was
  re-announced on publish without a question, the address overwritten,
  the original thread's replies stranded. Every manual path -- publish,
  `toot`, `bluesky` -- now asks the one question the cron asks, in the
  one shared place, and refuses while the post carries an address on
  either network. Wanting a second announcement is expressed by deleting
  the address field from the post's JSON: an edit deliberate enough to
  mean it. (The cron's skip message used to recommend `./blog.sh toot`
  here -- a command that would have refused; it now names the true way.
  And the old per-command checks had their own faults the shared one does
  not: an empty string in `mastodon_url` refused a first toot, and an
  announcement living on the other network was invisible.)
- **The cron read `unlisted` more narrowly than the site does.** The
  builder hides a post whose flag says anything but no; the cron kept
  its own list of yeses, so a flag written by a script as `"1"` or
  `"Yes"` hid the post from every listing and put its address on a
  public timeline anyway. One predicate now, shared by the cron, the
  manual announce and the properties screen, exactly as broad as the
  builder's.
- **Two queue writes still ran outside the lock.** The queue lock (below)
  covered the queue screen's moves; the [s] scheduling dialog and the
  [n]/`schedule` unscheduling kept relying on the byte compare alone,
  with the same microsecond window between the compare and the write.
  They take the same lock now and decline the same way when a publish is
  running -- a decline that is a real answer: the queue screen does not
  offer to compact slots behind an unschedule that never happened, and
  the standalone `schedule` answers a held lock with the same busy exit
  code `rebuild` has always used, instead of exit 0 pretending it wrote.
  And a lock held by a live but stuck process is named: once a
  holder has been going longer than any legitimate run takes, the busy
  message says since when, instead of promising "in a minute" forever.
- **`check` could not see a link written relative to the post.** It kept
  what starts with a slash as internal and what carries a scheme as
  external, so `./?item=another-post` or `photo/index.php?gallery=3` was
  neither, and no run looked at it -- `--online` included. These are not
  dead links, which is why they outlive audits: a static host ignores the
  query string, so the address answers 200 with the very post the reader
  is standing on. Nothing fails and nobody arrives. They are reported as
  errors now, with the rooted form to rewrite them to; a bare `#fragment`
  stays quiet, since resolving against its own page is what it is for.
  (Found on an archive that had just been declared sound: 73 of them, in
  61 posts.)
- **The example config had chosen Mastodon for you.** `mastodon:
  instance: "mastodon.social"` shipped as a live section while every other
  optional one ships commented out -- so the documented manual path (copy
  both templates, touch nothing) was a site that announces to Mastodon
  with no token to do it. The first scheduled post's cron tick then
  printed "MASTODON_ACCESS_TOKEN is not set... Check the token" to
  somebody with no token to check, and exited 1 -- cron failure mail on a
  healthy install, on every tick with a post due. Both networks now ship
  commented out like the rest: a network is a choice, and the loud exit
  is reserved for a choice somebody actually made. Sites that configured
  a network on purpose are untouched.
- **A `links:` key left standing without a list under it ended the build in
  a stack trace.** `Hash#fetch` answers its default for a key that is
  missing, not for one that is present and nil, so a footer written by
  hand -- or one whose last entry was deleted and the key left behind --
  reached `.map` on nil: `NoMethodError`, no page regenerated, and
  `./blog.sh doctor` calling the very same file healthy. An empty answer is
  an answer, and it is now read as one, the way `social:` always has been.
  The same held one level up: a deleted (or emptied) `about:` or `footer:`
  block aborted the build outright, over sections whose every key the
  templates guard individually. Both now read as empty, like `widgets:`
  always has.
- **`doctor` failed an install over states the templates support on
  purpose.** An emptied `footer.copyright` drops the copyright line and an
  emptied `about` drops its card -- both deliberate, both guarded in the
  templates -- and doctor answered them with "is missing from
  config/site.yml" and exit 1. A check that calls a supported state a fault
  teaches its reader to ignore the red. Neither goes unwatched: both are
  still flagged while they hold the template's own text, as something worth
  a look rather than as a fault.
- **An emptied `about` drew an empty card on every page.** The footer drops
  a heading whose content is gone and the five sidebar widgets appear only
  when configured -- but the about card was unconditional, so a site that
  had not written a bio (or had removed one) carried `<h3></h3>` over an
  empty box, site-wide. A site that HAS an about text renders byte for
  byte what it did before.
- **Four places promised that an empty menu leaves no bar.** `nav: []`
  removes the entries and the button that opens them, but the bar itself
  stays, because the search field is rendered inside it and there is no key
  to turn search off. `config/site.yml.example`, `docs/install.md` and the
  engine's comments in the build and in the nav template all said "no bar,
  no toggle"; they now say what happens.
- **A fresh install was told its site is at `example.com`.** Before a deploy
  target is chosen, the address in the config is still the template's, and
  both the draft preview line and the `Done:` line after a publish printed
  it -- a domain the author does not own, so the one thing a first post
  wants to do could not be done. The build is right there in
  `public.nosync/`, and `./blog.sh preview` serves it; both lines now say so
  underneath, with the address that actually opens. Only while the config
  carries the template's address: a site with a real one is not told twice
  where it is. The QR code under a draft preview is dropped in that state
  for the same reason -- it exists to carry the draft to a phone, and a
  phone that scans it would land on `example.com`.
- **The deploy said "the site goes nowhere" in English on a site that is
  not English.** `scripts/deploy_web.rb` was the one entry point that never
  loaded the translations, so the line printed after every single save on
  an install with no deploy target -- the state every install starts in --
  came out in English while the rest of the flow spoke the site's language.
  It is translated now, in the same words `doctor` uses for the same state.
  The language is read the way `doctor` reads it, tolerantly: a config too
  broken to parse still deploys the build that is already built.
- **The editor template's body was English on every site.** The header
  above it had been translated for releases; the one line under it,
  "First paragraph's text.", was written into the code. It is the first
  thing an author sees inside the editor.
- **The Instagram import's "no posts found" hint stopped one level too
  high.** It said to point at the directory holding
  `your_instagram_activity/` -- which is where the reader already was;
  the actual difference sits one level deeper, where the JSON export
  keeps `posts_*.json` under `media/` and the HTML one under `content/`.
  The message names the subfolders now, and importing.md says "trailing
  hashtag lines" where it said "trailing hashtags": only lines made of
  nothing but hashtags are cut, a hashtag inside a sentence stays.
- **The scheduling question worked against the person answering it.** The
  prompt never said that a bare "18:00" means today -- the fastest route
  to tonight was the one route nobody could see; a typo in the date ended
  the standalone `schedule` with exit 0 and the post untouched, while the
  draft dialog's [s] asked again, but only because its menu happens to
  loop -- one question, two behaviours; and scheduling rebuilt and
  deployed the whole site just to stamp a new date on a draft preview the
  publication throws away hours later -- the middle of three builds on
  the road to "post tonight". The prompt now advertises the bare time,
  the question re-asks until it gets a date or a cancel, and scheduling
  writes the queue without rebuilding anything.
- **`publishing.slots` existed only for whoever found it in the
  documentation.** The setup wizard explains the scheduler cron and then
  never mentioned the one key that makes the scheduler offer times by
  itself; the word "slots" did not appear in it. It asks now, right under
  the cron line, and empty still means what it always has -- no slots,
  the scheduler asks for a date.
- **A heading could not be turned off.** Emptying a footer section's
  content has taken its heading with it since 1.2 -- but emptying the
  HEADING over content that stays rendered a bare `<h3></h3>`, so a note
  without a title was not a thing a site could say. It is now: an empty
  heading over live content renders no heading at all, for the links, the
  note and the social column alike, and a site with headings renders byte
  for byte what it did. And `doctor` watches `footer.note_heading` with
  the other template texts -- the shipped English "Found something here?"
  sat over a Czech note on a live site for twelve days with every check
  green, because this one key was never on the placeholder list.
- **A Surfer nobody can reach arrived as a backtrace too.** The two
  likeliest beginner states -- the app is stopped, or SURFER_URL points at
  a machine where nothing listens -- landed in a raw `Errno::ECONNREFUSED`
  out of net/http, the only stack trace left on the deploy path. It is a
  sentence now, naming the address and the way forward, and the deploy
  bookkeeping still records the run as interrupted, so the next one says
  so in its header. Mid-batch drops were already handled per file; this
  was the connection that never opened at all.
- **A config the filesystem refused to write arrived as a backtrace.**
  `./style.sh` and `./setup.sh` copy the file to a `.bak` before they write
  it, so a backup left behind by a run made as another user -- root, most
  often -- blocks the write although the config itself is perfectly
  writable. The refusal was a raw `Errno`, and neither the wizard (which
  handles only a failed verification) nor its guard (only Ctrl-C) expected
  one: the run died mid-write with a Ruby stack trace and no hint of what
  to do. It says which file refused and that the backup is written first,
  and nothing is left half-written -- the refusal happens before any file
  is replaced.
- **Reordering the queue wrote without the lock the cron holds.** Every
  write the queue screen makes is guarded by a byte compare against what
  was read before the prompt, but the compare and the write were separate
  instructions, and the run that changes these files with nobody at the
  keyboard arrives every fifteen minutes. A tick landing in between
  published a due post and then had a draft's schedule written back over
  it: the state reverted to draft, the announcement URL dropped (so
  `unpublish` could no longer delete the toot), and the post queued to go
  out -- and be announced -- a second time. Moving a post now takes the
  same lock for the checks and the writes together, and a reshuffle that
  meets a running publish moves nothing and says why.

## 1.3 -- 2026-08-19

Dressing a site differently no longer means editing the engine -- your
own stylesheet, menu, sidebar and a lead image are settings now, and
`./style.sh` can write every one of them. Around that grew a release
about trusting the archive: `check` reads it and says what is broken,
`export` walks all of it back out as a markdown tree, `stats` counts it,
a media file's identity survives re-imports, and every edit is undoable
ten versions deep. Posts learned to be pages, series and unlisted
addresses; replies you star can become the only comments the page shows;
and a dead end got a page of its own, signpost included. Every default
is the layout the engine already had, with one deliberate exception: the
menu bar follows you down the page now, and it takes over from the menu
that used to be repeated under the content -- which only existed because
the bar didn't.

### New

- **`./blog.sh check`.** Walks the archive and reports what is broken in
  it: missing media, degenerate images the build drops caption and all,
  internal links nothing answers at, media directories no post owns, one
  old address claimed by two posts. It reads the content rather than the
  built site, only ever reports, and exits non-zero on errors alone, so
  it can hang off cron. `--online` also asks the web about the links
  that leave the site -- deliberately narrow, and nothing is called dead
  on a single request. The summary totals the archive, not the screen:
  long lists are capped at twenty lines, the counts are not. And a link
  to a one-post series is reported dead, because a series page only
  exists from the second published part on. Details in
  [operations.md](docs/operations.md#checking-the-archive).
- **`check` also sees the file a post no longer names.** An import only
  ever adds, so a source that drops a picture between runs leaves its
  file stranded in the post's own directory -- reported per post and per
  file now, as a warning. Answering that honestly meant counting a
  video's poster among the media a post uses: an existing poster is not
  a stray, and a missing one is finally reported like any other file.
- **`./blog.sh export`.** The other direction of the importers: the
  whole archive as a tree of markdown files with YAML front matter in
  Jekyll's layout, media included, redirects in the shape
  `jekyll-redirect-from` reads. What markdown has no syntax for travels
  as HTML carrying its definition in a comment `./import.sh` reads back,
  so export plus re-import moves an installation instead of merely
  leaving one. It reads only the archive on disk, so it works when the
  config no longer parses. Details in
  [operations.md](docs/operations.md#taking-your-content-elsewhere).
- **Media is fetched once, and a file's identity is its address.** Every
  media entry records where its file came from (`src`), so a re-import
  fetches only what the archive does not hold -- a second run of the
  same import makes no requests. An import only ever ADDS:
  `REFETCH_MEDIA=1` asks the source again but never overwrites, a
  returning file takes back the name it had here rather than landing on
  another file's bytes, and the post describes the file that is really
  in the archive. The post's kept versions remember an address the
  current copy dropped, identical bytes reunite a return with the copy
  already here, an entry with no address is recognised by its bytes --
  and a download the archive's copy outranks is counted in the summary,
  which is the one signal the source has drifted. The whole contract is
  in [importing.md](docs/importing.md#what-every-import-does).
- **Carrying a post through the publishing queue.** `[m]` picks the post
  up, the arrows carry it, Enter puts it down and Escape changes
  nothing; the times belong to the queue, so a long move is one
  confirmed write instead of one per slot. `[u]`/`[d]` remain for the
  single slot and for piped input. And the schedule prompt says so when
  the slot you want is taken: accept the offered time, carry the post to
  the front -- a full queue is a two-step, not a dead end. See
  [operations.md](docs/operations.md#working-the-queue).
- **Unlisted posts.** `unlisted: true` keeps a published post on its
  ordinary address and takes it out of every listing, feed and index,
  `noindex` included -- the draft's hidden address generalised to a
  finished post. Deliberately not a password. What it covers:
  [operations.md](docs/operations.md#properties-and-actions); why it
  goes no further: [decisions.md](docs/decisions.md#content).
- **`./blog.sh stats`.** The archive counted from the posts on disk:
  published, drafts, scheduled and pages, a bar per year, what the posts
  are made of, words with both mean and median (either alone would
  mislead on an archive of imported tweets), tags, media, platforms.
  `--json` prints the same numbers unrounded. No build, no network, no
  `env.sh`. Details in
  [operations.md](docs/operations.md#counting-the-archive).
- **Editing a post is undoable.** The previous text is kept before every
  overwrite -- an edit or a re-import -- and `[v]` in `props` puts one
  back. Ten per post, text only, travelling with the post to the trash
  and back. See
  [operations.md](docs/operations.md#properties-and-actions).
- **Pages.** `page: true` gives a post a permanent address at the root
  (`/about/`), out of the listings and feeds but in the sitemap and the
  search index. Ghost, WordPress, Squarespace and Substack import them
  as pages instead of skips, and the import says where they landed and
  that nothing links to them yet -- the engine will not write a `nav:`
  key on your behalf. Field reference in
  [architecture.md](docs/architecture.md#field-reference).
- **A 404 page**, built by the site rather than left to the host: the
  menu and the search field on a dead end, `noindex` -- and a signpost
  above the heading, drawn inline in the palette's own colors, its one
  accent arrow pointing the way on.
- **Series.** `series:` groups posts, `series_part:` orders the one
  published out of order; each series gets a listing, and every post in
  one links to the previous and next part -- within the series only. A
  draft's preview says whether its series name joins something or founds
  something new, so a typo is caught while it is free to fix; a series
  written as its own slug groups correctly and never retitles the
  listing away from a spelled-out name; and `check` warns about two
  series slugs a few characters apart -- but not about a series named
  after a release standing beside its own patch release, which differ by
  a separator and a digit and are two series on purpose. See
  [operations.md](docs/operations.md#writing-and-publishing).
- **Reading time and a table of contents.** The first on every post
  page; the second from four headings up, or whenever a post asks with
  `toc:`.
- **`fediverse:creator`.** Mastodon puts the author's account on a
  shared link's preview card. No new key -- it is the `social:` entry
  pointing at a profile on the instance the site already announces to.
- **A feed per tag, for the tags the menu names**, with autodiscovery on
  the tag's own page. Why only those:
  [decisions.md](docs/decisions.md#configuration).
- **`seo.block_ai_crawlers` and `seo.robots_extra`.** A maintained list
  of training crawlers for robots.txt, plus free text for the rest. Off
  by default; robots.txt is a request, not a fence. See
  [install.md](docs/install.md#2-configure-the-site----configsiteyml).
- **`site.extra_css`.** Stylesheets loaded after the engine's own, which
  is where a skin belongs -- previously the only way in was an edit that
  `git pull` took away. Paths on this site only, because of the site's
  own CSP; the build and `doctor` both name a line they had to skip. See
  [install.md](docs/install.md#the-menu-the-regions-and-a-stylesheet-of-your-own).
- **Your own menu (`nav:`).** Entries the site names -- a tag's listing
  or any address -- instead of the derived content types. Without the
  key nothing changes; an empty list turns the menu off. `./style.sh`
  edits it, offering your busiest tags and your pages by name, and
  `doctor` reports an entry whose target has since gone missing, plus
  the `url: "about"` spelling that only works from the front page. See
  [install.md](docs/install.md#the-menu-the-regions-and-a-stylesheet-of-your-own).
- **`layout.sidebar` and `layout.hero`.** The right-hand column can be
  switched off, the content taking the full width; a post's first usable
  image can run above the title, per site or per post (`hero:`), with a
  tracking pixel never promoted to lead picture. Same document as
  `nav:` above.
- **`./style.sh` can set everything about how the site looks.** A
  Layout section for the region switches and your stylesheets, plus the
  banner's filename, the claim text and self-hosted font faces -- a site
  can be dressed entirely from the wizard, which was the point of making
  all of this configuration. Enter through any section changes nothing.
- **Only the comments you star, if you want it that way.**
  `comments.approval: fav` publishes a reply once you favourite it, from
  the client you already have open -- no queue, no dashboard. It needs
  the sidebar cron; on Mastodon a token with `read:statuses` (`doctor
  --online` checks it); a favourite is public; and turning it on hides
  every existing comment until you star the keepers, with
  `./scripts/refresh-sidebar.sh --full` (new) settling old posts on the
  spot. A moderated post also stops making any third-party request: the
  comments arrive from the site's own domain and the page's CSP drops
  its grant to the instance. Operation and timings in
  [operations.md](docs/operations.md#cron-sidebar-widgets-and-post-stats);
  the decision and its price in
  [decisions.md](docs/decisions.md#publishing-and-comments).
- **A reply's pictures appear with it.** Both networks hand a reply's
  images over outside its text, so a picture reply used to render as
  just its words -- in the live thread and the moderated list alike.
  Thumbnails now sit under the words, linking out to the full image and
  loading from the commenter's own network the way their avatar always
  has. Images only, on purpose, and a reply marked sensitive keeps its
  pictures to itself. See
  [install.md](docs/install.md#8-comments-network-optional-mastodon-or-bluesky).

### Changed

- **A listing's heading marks what it is instead of saying it twice.** A
  tag heading is the tag itself and a search shows its query behind a
  magnifier; the word stays in the markup for a screen reader --
  clipped, not removed.
- **`config/site.yml.example` opens with an index** of every section and
  key, optional ones in brackets, in the order the page reads.
- **The publishing queue comes back to the post you just moved** -- by
  name, not by row, so repeating `[u]` carries the same post further
  instead of whichever post now sits in its old row.
- **Restoring an earlier version is a list you walk, not a number you
  type**, like every other list in the wizard; the row under the cursor
  shows that version's title or opening words, and confirming is one
  keypress -- a restore loses nothing, since the current text is kept as
  a version of its own. See
  [operations.md](docs/operations.md#properties-and-actions).
- **Action rows fold instead of wrapping mid-word** on a narrow
  terminal, breaking between items and keeping each one whole; nothing
  is dropped. And Page Up, Page Down, Home and End work in the pickers,
  as they already did on the browse screen.
- **Tab completes paths in the import wizard**, directories with spaces
  in their names included; questions asking for a handle or a URL do
  not complete.
- **The wizard holds still.** Every interactive screen repaints over
  itself instead of printing another copy per keypress, across all four
  entry points; anything long still gets the terminal to itself, the
  last screen stays in your scrollback, and piped runs are untouched.
  The three question-and-answer wizards keep the section and the answers
  already given above the question. See
  [operations.md](docs/operations.md#in-the-terminal).
- **"yes" is a keypress, not any word that starts with one.** Piped
  answers to the four confirmations are matched whole against the
  locale's yes key and the three shipped ones, so on a Czech site
  "abort" no longer means yes.
- **Moderation housekeeping.** `refresh_sidebar.rb` writes
  `comments.json` while moderation is on and deletes it when moderation
  is switched off; merged rather than replaced, so a failed fetch keeps
  a thread as last published. `doctor` names the three ways moderation
  can be configured into silence, and the comment count next to a post
  counts approved replies, so the number and the list agree.
- **A listing card says how long its post takes to read.** The deciding
  happens in the listing, and reading time is the one thing every post
  can report, so the meta row is constant now instead of appearing only
  under the few posts with an announcement. A post too short to time
  says "under a minute", on the card and on its own page alike. The
  reasoning is in [decisions.md](docs/decisions.md#content).

### Fixed

- **An announcement that does not happen says why.** `Publishing.announce`
  is a choice between the configured networks, so with neither section in
  `config/site.yml` it matched nothing and returned "no" -- and `toot`,
  which cannot tell "did not try" from "tried and was refused", printed
  *Failed to send the toot (see above)* with nothing above it. It now names
  the missing section, and says what a filled-in instance and token under a
  commented-out header actually do: they join the section before them.
  Refusing the backdating question is reported as the decision it is rather
  than as a failure, and the question is not asked at all when there is no
  network to announce to. The three ways this could end quietly were
  reported from the outside, by the first person to install this engine who
  had not written it.
- **`config/site.yml.example` says how to read itself.** The file uses `#`
  for two different jobs -- prose, and settings that are switched off --
  and the engine only copes because the wizards anchor on key paths they
  already know. A reader has no such anchor: a paragraph of documentation
  and a block of commented-out keys look exactly alike, and uncommenting
  half a section leaves the keys you did uncomment belonging to whatever
  section came before, with nothing to say so. The header now states the
  convention that was always there (one `#` before a key means uncomment
  me, two mean still optional), every switched-off section marks where it
  ends, and two sentences of prose that happened to begin with `profile:`
  and `url:` -- parsing as keys, which is the same trap from the other
  side -- are rewrapped. Suggested by the first person to set this engine
  up from the outside.
- **`doctor` stops agreeing with that mistake.** A missing network section
  used to be a green tick -- correct for a site that wanted none, and
  reassurance for the one whose owner had just filled in a token. A
  credential in `env.sh` with no section to use it is a warning now,
  pointing at the header. What a hand-edited config gets checked by is also
  said where hand-editing is documented, which it was not before:
  [install.md](docs/install.md#2-configure-the-site----configsiteyml).
- **A YAML error admits the line may not be the mistake.** The parser stops
  where things stop fitting, which for a commented-out section header with
  its keys left behind is *inside the section above it* -- on one real
  config, line 64 for a mistake on line 80. Both messages, the abort and
  `doctor`'s, now say the cause can be elsewhere and name the two shapes
  that do it.
- **The appearance toggle can find its way back to the system.** One
  click used to pin the choice in `localStorage` forever; the button now
  cycles system / light / dark and says which it is on, and the first
  click still flips to the opposite of what is on screen.
- **A markdown tree's pages arrive, and arrive as pages.** The importer
  read `_posts/` and `_drafts/` and nothing else, so a Jekyll site's
  `about.md` never arrived; and being a page depended on a front-matter
  key only this engine's own export writes. Root-level markdown is read
  now, minus the names that are never a page; where the file sits
  decides, Hugo's `_index.md` stays with the listings it describes, and
  no redirect is written from a page to itself.
- **A re-imported post no longer collects a platform tag it has already
  got**, so exporting and importing back does not pin a "jekyll" pill on
  the whole archive.
- **`hero:` survived a save.** An edit rebuilt the post without it, so
  opening an opted-out post silently gave it back the site's answer.
- **Keyboard focus can be seen again.** One `:focus-visible` ring for
  the whole site, in the accent, moved inside the control wherever what
  is underneath cannot be vouched for; a mouse click leaves nothing
  behind.
- **The site holds still for a reader who asked it to.**
  `prefers-reduced-motion` is honoured: transitions collapse to nothing
  and the back-to-top button jumps instead of scrolling.
- **The banner's two lines stop printing over each other on a phone.**
  Title and claim share one column now, and two things in a column
  cannot overlap however short it gets; the scrim keeping the claim
  readable is a band across the bottom. Nothing changes on a desktop.
- **The menu on a phone closes with Escape and with a tap on the page**,
  with Escape handing focus back to the button that opened it.
- **Search answers with its best results, not its most recent ones.**
  Results are scored -- a title over the text, a whole word over the
  same letters inside a longer one -- and ties keep their date order.
  The matching itself is unchanged.
- **A search no longer draws a card for every post it found.** Only the
  best-ranked results get cards, and the count above them still says how
  many there were -- a cap that is only honest because the list is
  ranked.
- **On a phone the search field is in the bar, not folded into the
  menu**, sized for a finger, and the bar hugs its contents instead of
  holding a fixed height that shifted the row as the menu opened.
- **The lightbox can be opened, walked and closed without a mouse.** The
  images that open it are buttons -- made so by the script, so a page
  without JavaScript keeps plain pictures -- the overlay is a dialog
  that keeps Tab inside itself, and closing returns to the image that
  was opened.
- **Small things, one sweep.** A passive scroll listener, comment
  avatars with their dimensions reserved, and two tap targets grown to
  what a finger needs.
- **A search has an address again.** `?q=` follows the query as it is
  typed, so a search can be sent, bookmarked and returned to -- and Back
  still leaves the page instead of walking the query backwards.
- **Every page has an h1.** Listing headings were level two; the front
  page had none and now carries the site's title, clipped by the
  stylesheet; a post with no title of its own is headed by the date
  every listing already calls it by; and the 404 page follows. A reader
  who moves through a page by its headings has a way in everywhere.
- **`check` no longer calls a working address dead.** The files every
  build writes, listing pages and series listings are known now, so a
  healthy archive no longer exits non-zero on cron.
- **Unlisted is unlisted the whole way round.** Publishing one no longer
  announces it -- on either path, and `--force` does not open this door;
  take the flag off first, so the decision is explicit. A re-import no
  longer quietly puts one back into every listing. And on a page the
  flag now also covers the sitemap and the search index, which had
  advertised the address the page itself noindexed.
- **`export` sees a directory that holds only dotfiles** -- a freshly
  cloned repository no longer reads as empty and written into without
  the `--force` the guard is there to require.
- **What a wizard prints is no longer erased by the screen it paints.**
  The repainting screens this cycle introduced were swallowing the
  reason above a confirmation, the state of the menu section and the
  banner's current filename -- and every hint was truncated rather than
  wrapped, which cost most of them their endings in all three languages.
  Reasons and hints travel inside the frame now, wrapped; the suite
  checks all three languages against wrapped rows, and that the frame
  wraps at all.
- **A series listing said "SérieNový Sean.cz".** The one listing that
  showed its kind as a word had no spacing rule of its own; it gets an
  icon like the others, the word stays for a screen reader, and the tag
  listing's oversized pill becomes an icon in the same pass.
- **The clock in the meta row was a fifth larger than the row it stood
  in.** Settled -- and the suite now reads the built page and the script
  together, so the two halves of that row cannot drift apart unseen.

The rest of this section comes from running the importers over four real
foreign archives rather than over fixtures -- a Ghost export of 118 posts
and 419 images, a Hugo tree of 77 files, a WordPress WXR of 194 items, and
this engine's own export read back in. Fixtures had agreed with the code
because both ends of them are ours.

- **A Hugo picture written as `{{< figure >}}` arrived as nothing at
  all** -- eaten as a Liquid tag before anything tried to fetch it, so
  nothing failed and nothing was reported. The shortcode is read first
  now, its alt, title and caption each landing where it belongs.
- **An article that showed Markdown in a code block had its example
  eaten.** Image and Liquid stripping ran over fences too; both now run
  inside the fence-aware pass, and the chunk-joining defect that had
  kept them out of it -- which read every fence below an inline image
  inside-out -- is fixed with them.
- **Four ways an import stayed quiet about what it did.** Two files
  claiming one address, a front-matter `image:` dropped, a caption left
  orphaned by a failed download, an author this engine has no field for
  -- each is now either kept or said out loud.
- **What the body could not keep is counted for everyone.** Elements the
  HTML converter has to drop -- players, iframes, forms -- were counted
  by exactly one of the eleven adapters that use it and thrown away by
  the other ten, so a WordPress import named its losses and a Jekyll
  import of the same body said "Done." The count lives in the converter
  itself now, and the summary says it whichever adapter was driving. See
  [importing.md](docs/importing.md#wordpress-or-any-rssatom-feed).
- **A percent-escaped filename was slugified character by character**,
  minting permanent addresses like `ef-bf-bc...`; the name is decoded
  first now, and the redirect still points at what the old site served.
- **A WordPress import's closing numbers described a different import.**
  Pages already at their address were blamed on `?p=` permalinks, pages
  were called posts, and the note listing where pages landed named slugs
  that later changed or never built -- it now asks where each page
  actually landed. A password-protected post losing its public address
  is said out loud, as are pictures whose linking wrapper the image
  block cannot carry.
- **A video uploaded to Ghost was lost, and three lines of its player
  were published in its place.** The adapter knew the embed card and not
  the uploaded file, which fell through to the HTML converter's drop
  list; uploaded video and bookmark cards become video and link blocks.
- **A second import took away what the first one brought.**
  `redirect_from` is written by several hands and was carried over only
  when the importer said nothing itself, so a re-import could overwrite
  every old address with its one. The addresses are merged now, old
  first. The merge also removes a page's own address from its redirects
  -- a loop the build complained about on every build -- including on
  sites that already have an import behind them.
- **Ten re-imports that changed nothing filled all ten version slots**,
  pushing out the hand-edited state they exist to protect; a version
  identical to the newest one stored is no longer written.
- **An AVIF image came in with no dimensions**, and some files carried
  extensions their bytes contradicted; the bytes decide now, and AVIF is
  measured.
- **`[](url)` -- what a WordPress-to-Markdown conversion leaves where a
  heading anchor used to be -- was printed to the reader as raw
  markdown, and heading ids were derived from it. An empty label is
  allowed and swallowed now: a link with nothing to click on is nothing
  a reader can use.
- **An attachment did not survive `export` and back.** Written with a
  path it stopped being an attachment on the way home -- label, size and
  block type gone, and the loss never counted. It goes out as HTML now,
  `download` and all.
- **"Images come from the tree itself -- no network" was true of a
  Jekyll site and promised about markdown trees in general.** A real
  Hugo archive pointed most of its images back at the WordPress it had
  left years earlier. All four places that said it now say which half
  needs the network, and that an image which never arrived leaves no
  block behind -- `./blog.sh check` finds nothing to report afterwards.
- **`props` stopped condemning a redirect a draft is holding.** The
  address list called an old address taken by a draft "a redirect that
  never happens" -- but the build writes the stub as long as the
  occupant is unpublished, so the redirect works, and dropping the
  address on that advice threw a working one away. The row now says the
  takeover happens when that draft publishes.
- **`./blog.sh rebuild` under a held lock exits non-zero**, as
  operations.md had promised all along -- with the lock's own code, so
  whatever invoked it no longer hears "a deploy happened". The cron
  paths keep their deliberate exit 0.
- **Five corrections to the tree import.** An alt text is no longer
  copied into a visible caption -- markdown renders no alt, so the copy
  printed a sentence the original site never showed, and broke the
  export round trip on exactly those images. A post whose only
  picture's file is missing from the tree keeps its place, name, alt
  and caption instead of vanishing whole, and the postscript counts the
  miss. A PERMALINK pattern never applies to root pages. A
  slug-collision pair hands its shared origin to the first file written
  instead of to both. And the site's own furniture (`_index.md`,
  `home.md`) shows up in the counts as skipped instead of vanishing
  from the total.
- **A nested `<a>` closes the open one**, as a browser reads the
  invalid markup some Ghost exports carry -- one run of text is one
  link span now, not two identical ones fighting.
- **A warning no longer outruns the output it belongs under.** The cron
  entry points sync stdout, so in the mail a piped run's warnings land
  where they happened instead of opening the report.

### Upgrading

- Nothing to migrate. One thing looks different without being asked for,
  and it is the only one: the menu bar at the top became sticky, and the
  menu repeated under the content went with it -- its one job is done
  the whole way down the page now, search field included. There is no
  key to put it back: two of the same menu on one screen is not a
  preference. The line it drew above the footer is drawn without it, and
  anything that scrolls a target into view stops short of the bar rather
  than under it.
- The next deploy is a full one rather than incremental: the banner's
  overlay moved inside a wrapper element in the layout every page
  shares, every listing heading became an h1, and post pages carry
  reading time and a contents list.
- The front page (and its `/page/N/` continuations) now carries the
  site's title as a clipped heading -- nothing is drawn, but a tool that
  reads the page as text will see the title where it saw nothing.
- A stylesheet of your own that positioned `.banner-title` or
  `.banner-claim` wants a look before you upgrade: the box around them
  (`.banner-overlay`) is the positioned one now, and they are items in a
  column inside it. To keep the old listing-heading wording, put the
  word back with one rule on `.listing-heading__kind`.
- Post versions live in `content.nosync/versions/`. They are part of
  your content, not of the engine -- a backup of `content.nosync/`
  already covers them.
- A script that wraps `./blog.sh rebuild` and reads its exit code sees
  a change: a rebuild that stepped aside for a held lock used to exit 0
  and now exits 3, the lock's own code -- "come back in a minute" told
  apart from "it worked". Cron paths are untouched.
- A markdown-tree re-import no longer copies an image's alt text into a
  visible caption, so a caption an earlier import invented that way
  disappears with the post's next re-import. If you liked one, it was
  always the picture's title: write it in the markdown as
  `![alt](file "title")` and it stays yours.

## 1.2.1 -- 2026-08-12

A bug-fix release with two things added to it: the site's own words are
Markdown now, and a photo no longer publishes where it was taken. The rest
came out of two rounds of review over the release itself. Nothing to
migrate -- `git pull`, rebuild, deploy.

### New

- **The site's own words are Markdown.** `about.html`, `footer.note_html`,
  `footer.copyright` and `banner.claim` were the only texts on a Markdown
  blog that had to be written in HTML. They go through the same parser a
  post does now -- links, emphasis, code, and in the two longer fields
  lists, quotes and as many paragraphs as you like. Raw HTML still passes
  through, so nothing has to be migrated and an `<img>` is still how a
  photo gets into a bio.
- **A photo no longer publishes the place it was taken.** A phone writes
  coordinates into every picture it takes and the engine copied media byte
  for byte, so a snapshot from a back garden put the back garden on the
  web. New photos are cleaned on the way into the archive -- on the copy,
  never on your own file -- which covers authoring and all twenty-two
  importers. Only the location goes: the camera, the moment and the
  orientation tag stay. `media.strip_location: false` keeps it.
- `./blog.sh doctor --strip-location` takes the location out of photos
  saved before that existed. It reads `media.nosync` and `assets/`, and the
  site follows on the next rebuild. The only thing doctor has ever written
  rather than reported, which is why it must be asked for by name.
- **A table can have no header row.** Written as a table that opens with
  the separator line, `| --- | --- |`, with every line after it data. A
  keyboard-shortcut list or a table used for layout has no heading, and
  until now the format could not say so.

### Changed

- **A new default banner**, shipped at twice its display size for dense
  screens; `banner.width`/`height` in the example move to 1880x600 to
  match. Only new installations see it -- `assets/images/header.png` is
  gitignored so a site's own artwork survives a `git pull`.
- `config/site.yml.example` writes `about.html` and `footer.note_html` as a
  literal block scalar (`|-`). A folded one turns a blank line into a
  single newline, which now reads as one wrapped paragraph rather than two
  and glues a list onto one line. Existing configs are untouched.

### Fixes

- **A continuation line under a nested list item crashed everything that
  read it.** `- a` / `  - b` / `    text` -- the ordinary way to give a
  list item a second line -- reached a comparison against nil. `blog.sh
  add` died with a backtrace and wrote no post; the same three lines in
  `about.html` killed the build and rendered no site at all. It parses as
  an ordinary paragraph now. Live in 1.2 as released.
- **Every imported table handed its first row of data to a `<th>`.** A
  table with no heading row -- shortcuts, figures, a layout table -- came
  out with its first line published as a column heading, which is a heading
  to a screen reader as much as to a reader. Wix reads `tableData.rowHeader`
  now and the HTML path its `<thead>` or a first row of `<th>`; the latter
  decides for fifteen sources and did not tell `th` from `td` at all.
- **A Tumblr ask read as if the blog's owner had asked themselves.** NPF
  keeps the question in `layout`, and the field was ignored -- so a
  stranger's question came out as the opening paragraphs of the post, in
  the owner's voice, and the asker's name never reached the archive at all.
  It is a quote with the asker under it now. Re-import to pick this up.
- **`doctor --strip-location` cleaned the archive and left the site
  alone.** The strip keeps a photo's byte length on purpose and the build
  skipped copying a media file whenever the sizes matched, so the
  coordinates stayed on the site while doctor called it clean. Media copies
  compare modification time as well as size now.
- **A GPS entry's data offset was trusted absolutely.** Nothing stops one
  from naming bytes that belong to the camera model, the MakerNote or the
  thumbnail, and written into by such a file the strip damaged the
  photograph and left the coordinates in it. It works out which ranges the
  other directories own and refuses to write over them.
- **`./style.sh` reported a held lock as a failed upload**, in yellow, with
  "the lines above say why" pointing at a line saying only that another run
  got there first. The publishing path has told the two apart since the
  exit code existed; the wizard does now too.
- **The palette preview promised more than it could keep.** It is uploaded
  to the site and printed with a QR code, and said nothing about how long
  it would answer -- the next build removes it, which a scheduled publish
  can start a minute later. The wizard says so now.
- **"Another run is still going" did not say to try again.** The message
  named the run holding the lock only while that process was alive, which
  is right, but suppressing it took the one useful fact with it: the run in
  the way is almost always the scheduled one.
- Smaller ones, all from the same two rounds of review: a bullet list whose
  first item was only pipes and dashes was read back as a headerless table;
  a pipe inside a code span in a table cell grew a backslash on every edit;
  ragged indentation under one bullet dropped an item; an image line in
  `about.html` published a stray `!` and a dead link; a Wix table whose
  `tableData` was not a mapping cost the whole post; a table with labels
  down its side lost its first row when one value cell was empty; a Tumblr
  ask made only of a picture lost the asker's name; a GPS entry with an
  undefined type left the coordinates in the file; `strip_file` read every
  file whole before checking it was a JPEG, and returned it with the
  temporary file's permissions.

### Upgrading

- Nothing has to change and nothing has to be rebuilt for the old behaviour
  to keep working. **Photos saved from now on lose their coordinates** --
  that is the one behaviour change that arrives unasked. `./blog.sh doctor`
  says how many already-saved photos still carry one, `--strip-location`
  cleans them (each gets a new checksum, so the next deploy uploads it
  again), and `media.strip_location: false` turns it off.
- If you want more than one paragraph or a list in `about.html` or
  `footer.note_html` and your config still writes them as `>-`, change that
  to `|-` first. `./style.sh` already writes the literal style for any
  value with a line break in it.

## 1.2 -- 2026-08-11

The import release. Eight sources became twenty-two -- every blog platform
worth naming, the whole social roster, podcasts, a plain markdown tree, and
the Wayback Machine for blogs whose platform no longer exists at all. Two
wizards arrived with it: `./setup.sh` walks a new install through the
settings it cannot run without, and `./style.sh` covers everything about how
the site looks, both writing your config as text so its comments survive.
Around those: a queue for scheduled posts, a searchable archive browser in
the terminal, a document post type, pinned posts, redirects from a blog's
old addresses, and `./blog.sh doctor` to say what an install is missing.

Nothing to migrate -- see Upgrading at the end.

### New

- **Eight import sources became twenty-two.** Ghost, Substack, Medium,
  Blogger, Squarespace, Wix, beehiiv, Movable Type/TypePad and
  LiveJournal joined the blog platforms, Facebook and Threads closed the
  social roster, and podcast feeds and markdown trees (Jekyll, Hugo, any
  `_posts/`) import too. Ghost's export carries no images at
  all, only references back to the running site, so import before the old
  site goes dark; Medium, Wix and beehiiv download theirs from the
  platform's CDN. Facebook and Threads read both formats Meta offers --
  Facebook skips with a count the posts it mirrored in from Twitter,
  Posterous and their era (95 % of the reference export;
  `FACEBOOK_CROSSPOSTS=1` includes them), Threads skips replies to other
  people's threads, and a Threads post carrying the crosspost flag is
  kept, because on real exports that flag marks posts written in the app
  too; LiveJournal talks to its XML-RPC API, having
  no export file to read; a markdown tree needs no network at all. Dead
  platforms are the Wayback Machine's job: it rebuilds a blog from the
  archived captures of its feed, or from archived post pages where there
  never was a feed (blog.cz and b2evolution packs built in,
  `POST_PATTERN` for the rest), and `WAYBACK_FROM`/`WAYBACK_TO` narrow a
  run to a date window. The source menu is two levels now -- blog
  platform, social network, dead site -- while scripted runs keep the
  flat numbered list.

- **`./setup.sh` -- setting a site up is now a conversation.** Instead of
  copying two files and editing 277 lines of commented YAML, it asks and
  checks each answer: the timezone against the machine's own zone
  database, the address written to **both** `config/site.yml` and
  `env.sh` (env.sh's copy overrides the other, and the shipped example
  points at `example.com`), the Mastodon token verified against the
  instance -- which also hands back the numeric account id the sidebar
  widget needs.

- **`./style.sh` -- the appearance half, and seven palettes to pick
  from.** The half you come back and fiddle with: palette, banner, about,
  footer, social icons, sidebar widgets, fonts, analytics. Whole palettes
  now ship in `config/palettes.yml` -- default blue, warm, monochrome and
  high contrast, each in both light and dark, and sunflower, garden and
  ocean from the TangerineUI Classic family the engine's own palette grew
  out of -- so picking one is a keystroke -- and a candidate can be looked at before it is
  kept: your own site rendered with the new colors, opened locally, or on
  a deployed site uploaded to `/palette-preview.html` and answered with a
  QR code, so a palette picked at an SSH prompt can be judged on a phone.
  The banner section copies the image into place and measures it, so the
  declared width and height stop going stale.

  Both wizards open with the same identity banner `./blog.sh` prints, so
  several installs in one shell never leave you guessing which one is
  being reconfigured. Every question is skippable, nothing is written
  until you have seen the diff with secrets masked and confirmed it once,
  the config keeps every comment it had, and editing it by hand still
  works.

- **`./blog.sh doctor` -- everything wrong with a configuration, at once.**
  Engine aborts name only the first problem; doctor reports the lot, each
  with a fix line, and concentrates on what fails *silently*: an unknown
  timezone (Ruby quietly falls back to UTC), a widget that can never show
  anything, a scheduled queue that nothing is publishing -- the
  scheduled-publish run leaves a heartbeat on every tick, including the
  ones with nothing due, and doctor reads it: a queue waiting on a runner
  nobody set up is a note, a post already late with nothing having run is
  an error. `--online` also
  checks that the feeds, the analytics script and the access token still
  answer. It runs on configs too broken for anything else to load,
  unparseable YAML included, and exits non-zero for errors only.

- **The queue got its own screen.** `./blog.sh queue`, and a matching wizard
  menu entry, lists every scheduled post in publish order and acts on the one
  you pick: move it a slot earlier or later, publish it right now, give it a
  different time, or return it to the drafts. Moving exchanges times with the
  neighbouring post, so the set of occupied slots never changes -- a
  hand-picked 14:17 stays a 14:17, it just gets a different post. When a post
  leaves the queue, the screen offers -- never forces -- to let the rest step
  one slot forward into the gap.

- **The archive is something you can walk through, not just a list that scrolls
  past.** `./blog.sh browse` shows the same posts as `list` as a screen you stay
  in: arrow keys through the whole archive, filters by type, state and tag with
  counts, and a search that filters as you type in the site's own query language
  -- words ANDed, `"a quoted phrase"` as one, `-word` excluding, diacritics never
  deciding a match. The selected row shows the line of full text that matched;
  space previews the post read-only, Enter edits it and comes back to the same
  row. `list` is unchanged, and `browse` falls back to it down a pipe.

- **Six more platforms play in a post, from their address alone.** A
  `!![caption](url)` line -- the gesture YouTube has always used -- now
  recognises Vimeo, PeerTube and archive.org as video, and Spotify,
  SoundCloud and Mixcloud as audio; the engine stores a provider and an
  id, never the platform's own embed code, and each page asks its
  Content-Security-Policy for exactly the players it carries, which is
  what lets a PeerTube video work at all. Funkwhale and Bandcamp play by
  asking once instead: their page address does not contain the player's,
  so saving a post that embeds one asks the service where its player is
  -- the only moment writing a post touches the network -- and stores the
  answer, so editing never asks again and the build stays offline.

- **A migrated blog can keep its old addresses.** Posts carry a
  `redirect_from` list -- the paths they answered at before -- and the build
  serves a redirect at each; importers that know their posts' original URLs
  write it on request -- the wizard asks whether the site will answer on
  the same domain, `migrate_feed.rb` and `migrate_tumblr.rb` take
  `KEEP_PERMALINKS=1`, Movable Type/TypePad take `URL_PATTERN`, and a
  markdown tree takes a `PERMALINK` pattern and `scripts/backfill_redirects.rb
  <old-domain>` fills it in for archives imported earlier. Blogger-style
  `.html` addresses become real files, no server configuration needed;
  WordPress `?p=123` permalinks cannot be kept and are counted in the import
  summary instead. `[a]` in `./blog.sh props <slug>` gives up an address.

- **More of the look comes from the config: the header's type, and two
  more social icons.** `fonts.banner_title` and `fonts.banner_claim` take
  a CSS font stack, the matching `_size` keys any CSS length, and a site's
  own web font is one `.woff2` in `assets/fonts/` plus an entry under
  `fonts.faces` away -- the build writes the `@font-face` into the same
  generated stylesheet the palette uses (see `./style.sh`). Say nothing and
  nothing changes: JetBrains Mono at 45px/20px, exactly as before.
  `icon: facebook` and `icon: x` join the built-in footer set in
  `site.yml`; `icon_svg` remains the escape hatch for everything else.

- **An interrupted post is offered back instead of just kept.** Text from an
  aborted editor session still survives in `.last-edit.md`, but now the next
  `add`/`edit` finds it, says when it was written, and offers `[r]` reopen,
  `[d]` discard, `[c]` continue -- no blank-Enter default, and only back to the
  command that wrote it, so an interrupted `edit <slug>` stays one post.
- **A phone video says what it is.** Saving a post with a video reads the codec
  from the file and warns once about HEVC or a `.mov` container, with the
  `ffmpeg` command that fixes it -- without refusing the save.

- **Post pages now carry the metadata crawlers and phone browsers look
  for.** `article:published_time` and one `article:tag` per tag fill out
  the previously bare `og:type=article`, a schema.org BlogPosting block
  ships as JSON-LD -- the shape rich results actually read -- and every
  page names a `theme-color` per colour scheme, taken from the palette's
  own background, so browser chrome on a phone stops banding against the
  site. Drafts get none of the article metadata; their pages stay
  noindex. Theme-color touches the layout, so the first deploy after this
  rewrites every page once.

- **Builds and deploys take a lock, so two runs can no longer rewrite
  `public.nosync` at the same time.** The scheduled publish runs every
  quarter of an hour and the sidebar refresh every half, and on a large
  archive a build plus a deploy takes longer than a tick -- so a deploy
  could walk a tree being rewritten under it, or prune as an orphan a page
  the other run had just published. A run that finds the lock held does not
  queue: a cron tick says so and leaves without mailing, a run you started
  reports it and exits non-zero. Where the filesystem cannot lock, nothing
  changes.

### Changed

- **Configuration the engine writes keeps its comments, and a broken
  `config/site.yml` now reads as a sentence.** Both wizards substitute
  values into the documented template at the text level instead of loading
  the YAML and dumping it back, so the ~200 lines of explanation, the
  commented-out blocks you uncomment for a widget and the folded scalars
  real sites keep HTML in all survive the write; every write is read back
  and restored from its backup if it did not land as asked. The diff shown
  before writing is a proper LCS diff -- line-for-line comparison made a
  four-line addition read as "everything from here to the end of the file",
  which is precisely the impression a tool asking permission to edit your
  config must not give. A syntax error used to surface as a Psych exception
  from whichever entry point read the file first; it now names the line and
  column, the three usual causes (a tab where spaces belong, a missing
  quote, a colon inside an unquoted value) and points at `doctor`.

- **Every screen says which blog you are in, and the layout gives the width
  to the text.** The wizard's identity block -- version, site name, address,
  with the mode on its own line -- now tops `help`, `doctor` and every other
  screen-bound command, because on a machine with more than one install
  "which blog am I in" is the first thing they should answer; the wrapper's
  bare `== blog.sh ==` banner is gone and piped output stays data-only, so
  `./blog.sh list | wc -l` counts posts, not banner lines. The "what next?"
  menu after a save reads in flow order -- `[d] keep as draft  [e] edit
  [p] publish  [s] schedule  [x] delete` -- with the keys unchanged. In the
  layout the sidebar track is fixed at 260px and the post column takes every
  pixel the viewport gives or takes, about 40px more text at full width;
  gutters are uniform and both page edges are the layout's own 1rem, which
  on a phone turns the sidebar's lopsided 40/24 insets into 16 on both sides.

### Fixes

- **An export could hand over its posts and leave you without them.** Every
  published Medium article was skipped for want of an id, one stray quote lost
  a whole Wix CSV, all 77 posts of a Hugo tree died on one image inside a line
  of text, an Instagram export requested in Czech imported a silent zero, a
  Substack run under cron wrote nothing, and a feed whose CDATA sits on its own
  line imported as twenty posts with no body. Forty WordPress portfolio and
  recipe articles hid in the same `not a post` count as the menu items, a
  number the docs called normal. Feeds name their own faults now, from a 404
  to XML that is not a feed at all.
- **A post that did arrive came without its pictures and its links.** A
  WordPress featured image sits outside the body and went unread: half the
  posts in a large export lost their only picture; a picture inside a
  blockquote was dropped, and a quote holding nothing else went with it;
  Bluesky carousels of up to twenty images fell through; Wix quotes and code
  were thrown away; and WordPress's classic editor printed `[caption]`,
  `[gallery]` and `[audio]` as text, 119 posts of a 969-post export. A classic
  Blogger body has no paragraphs at all, so the reader made a block per
  fragment -- one post split into 105 of them, 29 links in it down to 8 --
  while LiveJournal entries failed the other way, every old one collapsed
  into a single paragraph.
- **A post nobody was meant to read went onto the open web.** WordPress gives a
  password-protected post the status `publish`, so the body it holds back went
  out in full -- 17 in their own large test export; it arrives as a draft now.
  A Tumblr reblog was published as your own writing, WordPress drafts landed
  under the year `-1`, Medium and Movable Type posts under the day of the
  import, 221 post formats became tags, and a video podcast arrived as sound.

- **One unescaped `&` in an export no longer costs the whole archive.**
  WordPress prints raw query strings and Squarespace bare ampersands,
  which a conforming parser refuses outright: one character in one item
  of a thousand ended the run before anything was written. A failed parse
  now gets one more attempt with those characters escaped, and says how
  many there were. Post bodies are never touched, and a file that is not
  UTF-8 is refused rather than quietly transcoded.

- **A feed whose address the reader could not find had no identity, and
  every re-import then wrote the whole archive again.** Re-import matches
  posts by their source, and a source's identity starts with the host in
  the channel's own address -- which came out empty when the `<link>` sat
  on its own line, when the feed linked only to itself, for a bare domain,
  for an internationalised one, for a channel declaring no address at all,
  and for Buzzsprout and Simplecast, whose redundant namespace on an
  `<atom:link>` hid every element after it. A fallback that took the first
  address offered was worse than none: it gave a feed declaring Creative
  Commons first the licence's identity, so unrelated archives shared one
  and overwrote each other. A Wayback rescue reading many captures of one
  feed duplicated every post many times over in a single pass; a podcast's
  second run duplicated every episode and re-downloaded the audio to do
  it, gigabytes of it. The whole feed family reads addresses correctly now.

- **Media filenames depend only on the order a post references them.** A
  failed download used to hand its number to the next image, so filenames
  depended on which fetches succeeded -- and since the copy step never
  overwrites an existing name, a re-import after the source recovered
  could leave a post showing its second image where its first belongs.
  The number stays spent now, and a file referenced twice keeps its first
  filename instead of going missing. See *Upgrading*.
- **A failed download says why, retries when that helps, and never leaves
  half a file behind.** Any unsuccessful HTTP status used to pass silently
  as missing media; 5xx and 429 are retried, a 404 reported once. Media is
  renamed into place after copying, so Ctrl-C or a full disk cannot leave
  a truncated photo. Diacritics in a filename, a relative redirect
  `Location`, an inline `data:` image and an oversized archive no longer
  fail either.

- **A busy or throttling Archive no longer reads as a blog that was never
  archived.** The Wayback Machine rate-limits exactly the traffic a rescue
  makes, and refuses connections rather than answering with a status, so
  every refusal was reported as a fact about the blog -- one run called 81
  of 82 captures unreadable, every one a clean RSS file, and lost 36 of 37
  pictures. Requests now wait a busy Archive out (four attempts, fifteen
  seconds longer between each) for queries, captures and images alike, and
  an unanswered query is kept apart from one that came back empty.

- **A rescue says up front what it can and cannot recover.** The preview
  counts truncated feed items -- by where an item's last link points, so a
  "Permalink" footer is not a truncation -- and reports by year how many
  images the Archive holds of that host; one rescue promised sixty-four and
  delivered none. Capture dates read as the UTC they are, and a
  commented-out `<div>` no longer unbalances the b2evolution reader.

- **The import preview and the summary now tell the truth about what
  arrived.** A preview downloads nothing, so its media number is what the
  run will go after, not what it will come back with -- one real archive
  promised 64 files of which the source had kept none. The preview is
  worded that way now, and adds, where media are involved at all, that
  only the real run can say how many actually arrive. In the summary, a
  file missing from a post that was written is counted apart from one
  missing from a post that was skipped entirely; the single line for both
  had been claiming posts had been written that never were. A dateless
  Substack row imports by its send time or is skipped under its own name
  instead of vanishing. And every skip reason is translated again: eleven
  of them -- `crosspost`, `retweet`, `no_content` and the rest -- printed
  as their internal English names in the middle of a Czech or German
  summary, worst on a Facebook export, where skipped crossposts are
  usually the largest number in the run.

- **An imported Wix table came back as a paragraph of pipes the first time
  its post was saved.** The block was built without column alignment, so the
  separator row came out `|  |`, which is no longer a table in markdown --
  the parser refused it on the way back in and returned the lot as one
  paragraph. Tables written with HTML5's optional end tags nested every cell
  inside the previous one and emitted each row twice.
- **A paid post imported looking exactly like a free one.** Substack's now
  carry a `substack-paid` tag and a line in the summary, so you find them
  before you publish them; beehiiv's premium editions arrive as drafts with
  a tag of their own.
- **A pair of imported redirects could stop the site building at all.** One
  address being a directory of the other (`/x.html/sub/`, then `/x.html`)
  crashed the build with EISDIR; the second stub skips out loud now, like
  every other collision.
- **A `<lj user>` mention pointed at somebody else's journal.**
  `<lj user="james_nicoll">` linked to `jamesnicoll.livejournal.com`, which
  exists and belongs to another person: LiveJournal spells an underscore in
  a name as a hyphen, and the reader dropped it instead.
- **A large export says what it will cost before it takes it.** A WXR is
  held in memory whole -- 188 MB for WordPress's own 9.5 MB test export --
  so past 20 MB the line above the run says so.

- **Editing a post can no longer silently corrupt it.** `edit` turns stored
  blocks into markdown and back, and on a real 4840-post archive that trip
  quietly damaged 147 posts: overlapping bold and italic duplicated text,
  a code block demonstrating fenced code closed at its own
  example and lost everything after it, a code span gained a layer of
  backslashes with every edit -- and one demonstrating image syntax aborted
  the editor outright -- a URL with parentheses lost its tail into the
  visible text, a `|` or a quote or a bracket broke
  the line it sat in, a paragraph starting `>`, `#` or `1) ` changed type, a
  comment stripper reached inside a ```js fence, and a video's poster image and
  a Funkwhale player vanished. A post now round-trips with its text intact and
  is byte-stable from the second write on.

- **The editor holds on to what you typed.** The buffer is written atomically,
  after a write that ran out of disk truncated it to nothing; a save writes the
  post before pruning its media; a quotation with nothing above its attribution
  no longer hangs the save; and a frontmatter date that will not parse is a
  sentence naming the buffer, not a backtrace.

- **Deleting one post threw away another post's only backup, and the trash
  it went to could not be opened.** The trash was keyed by slug alone, but the
  same slug in two years is two posts -- backdating makes that ordinary -- so
  deleting the older one silently wiped the newer one's trashed copy and its
  whole media directory. `./blog.sh restore` with no argument, and the wizard's
  whole Trash entry, reported an empty trash over a full one, still looking for
  the layout used before posts were filed by year: the engine's only undo,
  effectively dead. It is keyed by year and slug now, `restore` offers both
  posts and still finds a flat `trash/<slug>/` from an older install, and
  restored media no longer land inside an older directory of the same name.
- **A post that moves across a New Year keeps its old link, and its own
  pictures.** The address carries the year, so editing a post's date moves it
  from `/posts/2019/slug/` to `/posts/2020/slug/` -- and the redirect a rename
  would have left behind was never recorded, so every link to it died. The same
  went for a re-import that moved a published post across a New Year; a source
  that starts reporting its dates in another timezone is enough. The media
  directory moves whole now too: a directory already standing at the
  destination made the move skip every file whose name was taken, and since
  `01.jpg` is `01.jpg` in every post, the post then served another post's bytes
  under its own filename.
- **Publishing again after a re-import redirects the old address.** A
  re-import publishes without going through publishing, so the note to
  redirect the address the post had vacated sat unread in its own file and
  the old address answered 404.

- **A file you add to a post is measured and identified by what it is.** A
  video whose header declares an HEVC image *sequence* was taken for an
  HEIC photo, and the converter would have answered with a single frame
  and called it the file -- detection now looks for the box that decides
  it, and a movie box means a movie whatever the brand says. Dimensions
  came from the frame header and ignored the EXIF orientation every
  browser obeys, so a portrait phone photo reserved a landscape box and
  the page jumped exactly where the reservation was meant to stop it.
  And 99,999,999 bytes printed as "100 MB", so an allowed file and a
  refused one read identically and the warning contradicted itself out
  loud -- "(100 MB) -- under the 100 MB limit"; sizes now round down,
  which also means a printed size is never larger than the file.

- **Scheduling a post works again -- every route into it was dead.** A name
  collision inside the scheduling dialog fed the "has this file changed
  underneath you" guard the date you had just typed instead of the post file's
  bytes, so the comparison could never match: the `schedule` command, `[s]` on
  a draft, `[s]` in the properties dialog and the queue screen all aborted with
  "changed on disk". The guard has its real evidence back, and `schedule` now
  carries the same protection the other paths already had.
- **A post the cron published while you were deciding can no longer be
  overwritten by a dialog you left open.** The queue screen, the properties
  dialog, `[s]` in the draft preview and the `schedule` command read a post
  and then wait at a prompt, while the scheduled-publish cron runs every
  fifteen minutes; writing that captured copy back reverted the post to a
  draft, dropped its announcement URL and let the next tick announce it a
  second time. The check now runs as the last instruction before each write.

- **The queue acts on the post you picked, and a reorder is all or nothing.**
  `[p]` and the draft dialog's actions looked the post up by name, so with the
  same slug in two years they could publish, edit or delete the other one; a
  reorder whose second write was refused left two posts on one slot, or one
  published months early. Both halves are checked before either is written,
  and a reorder that dies anyway says which posts moved. A draft that has lost
  its `draft_token` is named and skipped, not built at a guessable address.

- **An announcement could be left hanging in public with nothing pointing
  at it, and nothing said so.** `unpublish` dropped the toot's address
  whether or not the delete had worked, so an expired token left the
  announcement standing there, and publishing again simply added a second
  one alongside it. The cron failed the other way round: announcing answered
  the same "nothing" whether there had been nothing to send or the send had
  failed, so the post was published, the run exited 0, and nothing anywhere
  recorded that an announcement was still owed. The
  address is kept when the deletion fails, a failed send exits non-zero and
  names the post, and `toot` and `bluesky` no longer read a missing address
  as "nothing was sent" and send a second copy. In the text itself a link
  keeps a bracket that belongs to it while a sentence's full stop stays
  outside, the ellipsis of a shortened preview stays out of the address and
  inside the limit, and a long title with a pile of tags -- which between
  them fill Bluesky's 300 graphemes, and an over-long record is refused
  whole -- is shortened rather than left to silence the announcement.
  `delete` retracts its announcement now, the way `unpublish` always has.

- **Enter means "leave it alone", the way the wizards document it.** Menus
  opened on their first row instead of the current value -- on the language
  menu, where Czech sorts first, that alone switched an English site to
  Czech and rebuilt it in the other language -- and `./style.sh`'s banner
  questions were `[y/N]`, so Enter turned both overlays off. The yes key now
  comes from the language the wizard is speaking.

- **Nothing is touched before you confirm, and one bad line no longer costs
  the session.** `./style.sh` copied your new banner the moment you typed its
  path, overwriting a per-install file that has no backup even when you then
  declined the write; `env.sh` lost its 0600 on every save, its `*.bak` of the
  previous live tokens is gitignored now, and the mask over the review diff
  had never hidden a single token. A footer list written level with its key,
  or two spaces after a period in a prose answer, used to fail the write and
  roll back every answer of the run; a half-written palette in
  `config/palettes.yml` is named and skipped instead of crashing; "Nowhere
  yet" unsets the deploy backend instead of leaving `rebuild` shipping to the
  old target; and a re-run stops rewriting hand-edited lines whose values did
  not change.

- **The wizards work on Ruby 2.7 and 3.0 again.** On Debian 11's system Ruby
  -- inside the "Ruby 2.7 or newer" the engine promises -- `setup.sh` and
  `style.sh` could not write a config at all, and blamed the file for it.

- **The archive browser draws and reads the terminal properly now.** In raw
  mode a newline is not turned into a carriage return plus a newline, so the
  screen painted as a diagonal staircase, and a line break or a tab in a post
  title walked the frame down with it. Rows are measured in display columns --
  emoji and CJK count two -- so such a row no longer wraps and corrupts the
  repaint, and raw mode is held for the screen's whole life rather than per
  keystroke, so fast typing during a repaint no longer echoes stray characters
  into the frame. Search rebuilds its index on return from a post, keys it by
  year and slug so two posts sharing a slug stop answering with each other's
  text, and explains the current query rather than the previous one.

- **Page Up (and Home, End, Insert, Delete) left a stray key behind in every
  menu in the CLI.** Only the first character after the escape bracket was
  read, so the `~` that ends those sequences arrived a moment later as a
  keypress of its own -- a `~` in a text box nobody typed. The whole sequence
  is read now.

- **An imported archive is text somebody else wrote, and several places
  wrote it into the page unescaped.** A media file's name comes from
  whoever wrote the archive: one carrying a quote and an angle bracket
  closed the `src="..."` it sat in and opened a tag of its own, on your
  own domain, where your own policy trusts it. A video address the engine
  cannot play printed raw the same way, in the post and in the feed, and
  a post carrying `]]>` -- an imported `embed_html` can -- ended the
  feed's CDATA early and could hand a reader a headline and link of its
  own choosing. All escaped now, a media name is reduced to its basename
  so `../` cannot write outside the post's directory, the structured-data
  block no longer renders a post blank, and an unterminated `<script>` in
  a truncated capture no longer leaks code into a post.
- **Each page's Content-Security-Policy is computed from what that page
  actually carries**, so comment threads survive a change of network, a
  pinned post's player works on the front page, and listing pages get no
  permissions they never use.

- **The menu no longer runs under the search box.** A site using every
  content type has nine items in the bar, and nine did not fit in any of
  the three shipped locales -- Czech overflowed the 908px available
  outright, English and German had single-digit slack and collided anyway.
  The bar now sizes itself: it may wrap to a second row, the search box
  never shrinks or gets overlapped, and tighter gaps between items
  recovered 80px without shortening a single label.
- **Nothing empty is drawn any more.** An emptied social list left its
  heading -- "Find me on", pointing at nothing -- on every page, and the
  links and note columns had the same habit; each footer block now appears
  only when it has something to show. A `banner.claim` that is only markup
  left a lone middle dot in the CLI header. And a plain draft shows no date
  in listings and pickers, the rule the properties dialog already follows:
  a draft's time is set by publishing or scheduling, so the timestamp in
  its file describes bookkeeping, not the post.

- **The crons could not be trusted to say what happened.** The sidebar cron
  reported every failure as success -- a monitored job saw clean runs for weeks
  while the sidebar had not refreshed once -- and a busy skip it had handled
  correctly as a failed job; a local deploy logged every file as failed while
  copying it fine. Both crons died on every tick once an accented filename
  reached the deploy, the one entry point that does not load the site config
  and with it the rule that files are read as UTF-8. They check the Ruby
  version now, like everything else does, and one unreadable post file no
  longer stops the sidebar from ever refreshing again.

- **The deploy guards hold, and a busy lock reads as a collision.** `--only`
  stood them down on git pages, which force-pushes the whole build whatever it
  is handed -- and `refresh-sidebar.sh` is such a run, every half hour: a build
  that had lost its content replaced the live site, leaving a branch with no
  posts. A publish the lock arrived in the middle of now leaves the marker that
  makes the next run finish it, the "deploy failed" line no longer advises a
  retry that cannot work, an unusable lock path says it is running unlocked,
  and a redirect chain that never lands is reported.

- **The commands that exist for a broken install now survive one.**
  `clear` fails on ghostty, kitty, wezterm and `TERM=dumb`, and took
  every entry point down with it before a word was printed. `help` and
  `version` loaded the configuration they exist to explain, and the
  banner above `help` raised a YAML error on it; both have their own
  entry point now. `doctor` crashed on a `site.yml` a sudo-run wizard
  left owned by root; that is finding number one now, with the
  `chmod`/`chown` to run, and the rest of the checkup still happens.
- **`doctor` and the engine now agree on what counts as configured.** A
  revoked Bluesky app password read as healthy; `--online` opens a
  session now and calls a refusal an error. A site that declined a deploy
  target was told its Surfer backend was unconfigured -- a product it had
  never heard of. The schedule check takes the `9:30` slots the engine
  takes, stops calling empty titles "filled in", and a `colors:` section
  written as a list falls back to the default palette, not a TypeError.

- **`./blog.sh preview` no longer serves your archive to the local
  network, and what it does serve now matches the deployed site.** It
  bound every interface while printing "localhost" -- and what it exposed
  was the built archive, which after an import is a personal history that
  has never been public. Two smaller disagreements with the real site are
  gone as well: a Range request got a 200 back, which Safari reads as
  "this server cannot stream" and refuses to play the media element at
  all, and which breaks seeking in a video or audio post everywhere else
  (the answer is now 206, or 416 past the end of the file, and files are
  streamed rather than read whole into memory); and audio, `.m4v` and all
  nine attachment extensions went out as `application/octet-stream`, so
  the browser downloaded what the deployed site plays or displays.

- **A consistency pass over everything the interface says, in all three
  languages.** Czech counts now read correctly for every number
  ("Publikačních slotů: 4", not "4 publikačních slotů"), Czech quotes
  close typographically („…“), the yes/no prompts read [a/N], and the
  language settles on one word for building a site where it had three.
  The wizard's menu entries lead with the thing rather than the verb
  ("The archive -- filters, search, preview"), and the hints under them
  stop offering what the menu ignores -- a slug typed at a menu that
  takes no letters, or a fixed 1-9 range where the real rows differ.
  Two documentation corrections: the markdown cheat sheet now names the
  video extensions (`.mp4`, `.mov`, `.m4v`), as its audio and attachment
  sections already did, and the README and guide stop promising Tumblr
  drafts, the queue and private posts -- those sit behind endpoints that
  want a full OAuth handshake, so the import gets the published posts.
  `config/site.yml.example` also explains what the `rel: "me"` key on a
  social link is for.

### Upgrading

- **Nothing to migrate.** `git pull`, rebuild, deploy. Verified against a
  1.1 installation whose config was left exactly as it was: the same site
  comes out, page for page, with no warnings -- every new config section
  (`fonts`, palettes, the wizards) is optional, and `doctor` runs on a 1.1
  config without complaining about their absence. Expect the first deploy
  to be a long one: every page carries a `theme-color` now, so all of them
  are rewritten once and the smart sync has the whole site to upload.
- **The one caveat: media numbering, and only for posts whose downloads
  failed under 1.1.** 1.1 gave a failed fetch's number to the next image;
  1.2 leaves it spent, so filenames depend only on the order a post
  references its media, never on which downloads happened to succeed. That
  makes re-importing over a tree the 1.1 importer wrote the single upgrade
  path that needs care: if a post reported failed media back then its
  numbering shifts, and the copy step's "skip files that already exist" can
  leave it showing the neighbouring image. Before re-importing those posts
  -- the 1.1 run's summary named them -- delete their media directories, or
  import into a fresh tree. Trees both written and re-imported by the same
  engine version are unaffected either way.
- **Menu positions moved, so stop piping numbers at them.** The wizard menu
  grew to six entries with the queue screen, and its fourth entry is the
  archive browser rather than the flat listing; the import wizard's source
  menu is two levels now (blogs / social networks / dead sites). A scripted
  `printf "N\n" | ./blog.sh` or `| ./import.sh` may therefore land somewhere
  else than it did in 1.1. The CLI commands are the stable interface --
  `./blog.sh queue`, `./blog.sh list` -- and the non-interactive import path
  is unchanged: a piped run still gets one flat numbered list, and
  `migrate_*.rb` scripts are unaffected.
- **Builds and deploys take a lock now.** The publishing cron, the sidebar
  cron and a person at the CLI can no longer walk into each other's
  half-written `public.nosync`. A run that finds the lock held does not
  queue: a cron tick says so and leaves (exit 0, no mail), a run you started
  reports it and exits non-zero rather than let its caller think a deploy
  happened. On a filesystem that cannot lock, everything behaves exactly as
  it did before.
- **Three more working files** sit next to the ones from 1.1:
  `.last-edit.meta` (which command wrote the editor buffer),
  `.blog-sh.lock`, and `.last-scheduled-run`, the heartbeat that lets
  `doctor` tell a waiting queue from one nothing is serving. All three
  are gitignored and none needs backing up.
  `*.bak` is gitignored now as well -- the wizards keep a backup of the file
  they rewrite, and for `env.sh` that copy holds your previous tokens.
- **Going back to 1.1 builds, but do not write under it.** The 1.1 engine
  reads everything 1.2 has written without choking -- no build fails, no post
  is dropped, `former_slugs` redirects come out byte for byte -- it simply
  cannot render what it never knew about. Audio posts lose the recording's
  address and not just its player, coming out as a bare "[audio unavailable]"
  with nothing to click; comment threads go quiet on posts announced anywhere
  but the network your config names now; and re-saving a 1.2-written post
  under 1.1 can lose text, because it does not escape a `|` in a table cell,
  a `"` in a link title or a `*` inside inline code. Rebuilding is safe, so
  treat the archive as read-only until you come forward again -- nothing has
  to be undone first, and coming forward re-renders all of it correctly.

## 1.1 -- 2026-08-05

Six things a site can now do that it couldn't, and one class of defect
removed from the deploy. Nothing to migrate: `git pull`, rebuild, deploy.
Three changes are worth knowing about before you upgrade, all at the bottom.

### New

- **A post can be pinned to the front page.** `pinned: true` in a
  published post's header holds a copy at the top of the first listing
  page -- only there, because a pin is a statement about the front page,
  not about the archive: type and tag listings, the feeds and the sitemap
  stay chronological. Once the post has aged onto page 2 it appears both
  at the top of page 1 and in its own place on page 2; while it is still
  on page 1 it appears exactly once. Anchored pagination is untouched, so
  toggling a pin costs one or two files in a deploy. The pinned copy
  carries a small mark in the corner of its date badge, using the same
  neutral colour pair the badge already inverts to on hover.
- **Publishing slots turn `[s]` into a queue.** `publishing.slots: ["mon
  09:30", "wed 09:30", "fri 09:30"]` (or a single `"daily 09:00"`) says
  when posts usually go out, and scheduling then offers the next slot no
  other scheduled post occupies -- three drafts written in one evening go
  out on three consecutive slots instead of together. It only ever
  suggests: typing a date overrides it, a post hand-scheduled for 14:17
  blocks nobody, and nothing ever moves a post that already has a time.
  Without the key, the prompt is the one that was there before. The offer
  names the slots it walked past and who holds them, and a scheduled
  draft's properties print the whole queue -- an offer of Sunday on a site
  with a Saturday slot otherwise reads as a queue that skips Saturdays,
  when the truth is that Saturday was taken.
- **Posts can carry files.** A line that is nothing but
  `[label](handbook.pdf)` with a bare filename is an attachment, the same
  way a bare filename in an image line is a photo -- staged through
  `incoming/`, stored with the post, rendered as a card with the label,
  the extension and the size, because a download deserves to say what it
  costs first. A URL stays a link, and only whitelisted extensions count.
  A short line plus a file makes a *document* post, and DOCUMENTS appears
  in the nav once the first one exists.
- **One dialog for a post's properties and actions.** `./blog.sh props
  <slug>` (in the wizard: pick a post, then `v`) shows a post's state,
  type, tags, pin and announcement in one place, and offers the guarded
  actions -- publish or schedule for a draft; unpublish, (re-)announce,
  pin/unpin and delete for a published post. Type and tags stay editable
  where they always were, in the frontmatter of `edit`, prefilled with
  their current values; the pin, being a switch rather than a value,
  toggles right in the dialog with `[c]` (the header line keeps working
  too), and the pinned post is marked `[PINNED]` in every list and
  picker. The wizard menu shrank to five activities as a result:
  publish, schedule, unpublish, delete and the announcement are reached
  through the post now instead of being menu items of their own.
- **A slug can be renamed without breaking a link.** Renaming (the `[r]`
  action in that dialog) records every old address in the post itself and
  the build keeps a one-page redirect standing at each -- so the URL in
  an old toot keeps resolving. The redirects live and die with the post:
  unpublishing takes them off the site, republishing brings them back.
- **HEIC photos are refused with instructions, or converted on request.**
  The iPhone default renders in Safari and nowhere else, so attaching one
  now stops the save and prints the exact conversion command for the
  machine you are on, leaving the file where it is. Set
  `media.convert_heic: true` and the engine converts it instead, using
  whatever it finds (sips, heif-convert, magick, vips) and falling back to
  the refusal when it finds nothing. Detection is by content, so a HEIC
  smuggled in as `.jpg` is caught too.

### Deploy safety

- **The guards could be switched off permanently, silently.** They
  compared the build against the manifest -- the state of the *target* --
  so every failed upload knocked their reference out of true, and the
  patch for that was a marker that stood them down until a clean run came
  along. When the failure was permanent (a file the host refuses, expired
  credentials, a target that is gone) no clean run ever came, and both
  guards stayed off for good: a build collapsing from 7500 files to a
  handful would have been mirrored, `--prune` included. They now measure
  the build against the last build they accepted, recorded before the
  first byte moves, so there is nothing left to switch off.
- **They also fired when they shouldn't.** 20% of a 32-file build is six
  files, so publishing two posts at once aborted a flow that `./blog.sh`
  runs for you and which cannot pass `--force`. The percentages carry
  absolute floors now.
- **Total bytes are guarded too**, in both directions -- the same file
  count with every page nearly empty was invisible before. A byte drop
  stops the deploy; a byte increase only says so, because attaching media
  is authoring.
- **An empty build is refused.** With an empty manifest as well, it used
  to pass every check.
- **A failing deploy explains itself.** The previous run's outcome is
  reported at the top of the next one, and three unfinished runs in a row
  say so explicitly.

### Fixes

- A re-import minted a **duplicate post** whenever the text behind the
  slug changed at the source -- a fixed typo in an RSS title was enough.
  Matching is on the source id across the whole archive now, updating in
  place and keeping the published slug. Two follow-on holes from that same
  change: a matched post moving across a year boundary could **overwrite a
  different post** that already owned the path, and two feeds with no
  readable channel link could collapse onto one identity and overwrite
  each other.
- An import whose **source died mid-paging** crashed with a raw backtrace
  and no summary, so there was no way to know what had already been
  written.
- **Imported drafts** landed on the live site at a guessable
  `/draft//<slug>/` address, without the token that exists to prevent
  exactly that.
- The interactive picker **could not be given a slug that starts with a
  digit**, and the first keypress silently acted on a different post.
- The pin, the slots and the document type each shipped with a defect
  found by attacking them rather than testing them: a pin did nothing on
  any site with fewer than twenty posts, slots could **double-book across
  a DST change**, and an attachment was **lost on edit** when the repo
  path contained a space. A second pass then found four more that those
  fixes had introduced -- among them an attachment losing its size on the
  first edit and permanently, and `[Handbook](file.pdf "title")` being
  turned into an upload.
- The wizard banner showed the site's description where its own header
  shows a claim, and a bare domain that terminals turned into a punycode
  guess.
- A final review pass, attacking the finished features rather than
  testing them, found a handful more before the release: the properties
  dialog could **revert a post the cron had just published** -- it acted
  on the post it read when the dialog opened, and a scheduled publish in
  between would be undone, its announcement URL dropped, on the next
  keypress (the same guard `edit` already had, now on the dialog's four
  actions too); a re-import **dropped a post's pin and its created_at**,
  which the source has no notion of; a date edit across a year boundary
  left the post's own new address in its redirect list, producing a
  **build warning on every build**; a deploy read a manifest that was
  valid JSON of the wrong shape and **crashed with a raw backtrace**
  instead of the promised "treat it as empty", and a corrupted baseline
  of the wrong shape was swallowed in silence; and a rename to an
  enormous slug failed with a filesystem error rather than a plain
  "too long".

### Upgrading

- **The wizard menu was renumbered.** It lists five activities now, so a
  scripted `printf "4\n" | ./blog.sh` picks a different entry than it did
  in 1.0. The CLI commands are the stable interface and none of them
  changed -- pipe `./blog.sh unpublish <slug>` instead of navigating the
  menu by position.
- **A single file over 100 MB is now refused** -- when a post is saved, so
  you can still do something about it, and again before a deploy sends it.
  One limit for every backend, deliberately, so the site stays portable:
  the strictest supported target (git pages) refuses anything larger, and
  a post that saves today shouldn't become undeployable the day the site
  moves. `--force` does not lift it. Files between 50 MB and 100 MB are
  named but allowed, and one already on the target from before the limit
  is reported rather than refused.
- **A new state file, `.deploy_baseline.json`**, holds what the guards
  measure against. It is gitignored, needs no backup, and losing it costs
  one deploy with the growth guard standing down. A leftover
  `.deploy_manifest*.json.incomplete` from 1.0.1 is read once and removed.

## 1.0.1 -- 2026-08-02

A bug-fix release, from a systematic audit of every flow: authoring,
publishing, both cron jobs, the build, deploy and the importers, asking of
each step what happens if it fails there. Nothing to migrate -- `git pull`,
rebuild, deploy.

### Data that could be lost

- `edit` with a date in another year **destroyed the post**: its JSON was
  deleted before its media moved, and moving into a year with no media
  directory yet raised `ENOENT` in between -- the post survived in neither
  year, was not in `trash/`, and the editor's temp file was already gone.
  The replacement is written before anything is removed now.
- A failed write **truncated the post it was rewriting**. `File.write`
  empties the file first and only then finds out it cannot write, so a full
  disk left a saved post at 0 bytes. Every post write, and the deploy
  manifest, now writes a sibling file and renames it into place.
- A new photo could **overwrite an existing one**: media files are numbered
  per post, but an image kept from a previous save did not consume its
  number, so a second photo of the same type was handed the kept one's name.
- A new post could land on a **leftover media directory**, show its photos,
  and have its own upload deleted from `incoming/` uncopied.
- A source file missing for even a moment made the build drop the copy
  already in `public.nosync/`, and the `--prune` that every publish runs
  then **deleted it from the live site**.

### Flows that could not finish

- The **scheduled-publish cron could wedge permanently**: publishing a post
  with photos into a year nothing had been published into yet raised
  `ENOENT`, took the whole batch with it -- including posts already
  published *and announced* in that run -- and repeated on every tick.
- **One imported post could stop the site from building at all.** Inline
  formatting offsets were counted against the raw HTML text but stored
  against a whitespace-collapsed copy, so ordinary pretty-printed markup
  pushed a span past the end of its text and the build died naming no post.
- **The sidebar refresh never uploaded anything** on a site that does not
  configure all five widgets: the file list was built with `ls`, whose
  non-zero exit under `set -euo pipefail` killed the script one line before
  the upload. Silently, every half hour.
- **An interrupted deploy locked out every later one** -- the partial
  manifest made the file-count guard read the next ordinary deploy as an
  explosion in size, including the deploys the CLI runs itself, which cannot
  pass `--force`.
- **A closed stdin spun at full CPU**: the wait-for-photos loop treated
  end-of-input as "not yet" and re-checked until someone killed the process.
- **One unreadable post file took down the build, `list`, every picker and
  the cron at once**, with a parser error that named no file.

### Correctness

- An edit saved across the cron tick that published the post reverted it to
  a scheduled draft and dropped its announcement URL, so the next tick
  announced it again. Such a save is refused now, with the text kept.
- An ambiguous slug was resolved again at every internal step, so one
  command asked "which year?" two or three times -- and an inconsistent
  answer retargeted it, up to and including deleting the other post.
- GIF and WebP images were silently dropped from every page, caption and
  all, because their dimensions could not be read and that was treated as a
  1x1 tracking pixel. Both are read now, and an image whose size cannot be
  determined renders instead of vanishing.
- An import preview promised more posts and media than the real run wrote; a
  WordPress export with an unusual `post_name` could write an invisible post.
- Feed fetches had no total deadline, so a host that answers slowly forever
  could hold the build and the sidebar cron. 30 seconds now, redirects
  included.
- An emoji-only tag rendered as a link to `/tag//`, which goes nowhere.
- `--force` deploy forgot files pending deletion on the target, which could
  then never be pruned; an unreadable manifest was silently read as "nothing
  was ever uploaded".

### Added

- `./blog.sh version` (also `--version`), the version in the wizard banner
  and in the engine's User-Agent -- which used to be the literal `1.0` and
  would have stayed that way through every later release.
- The backup checklist in [operations](docs/operations.md#backup) now names
  `assets/images/header.png` and `favicon.png`: they are gitignored on
  purpose, so nothing else keeps a copy and a restore would have brought the
  site back with the shipped default artwork.

### Upgrading

`git pull`, then rebuild and deploy. On an existing site the only visible
change is that images the engine could not previously measure now appear --
on the 3280-post archive this was developed against that was exactly one
photo, and old and new engine output differed in 14 files in total.

## 1.0 -- 2026-07-31

The first stable release: a file-based blog engine where posts are JSON
files, the site is a static build, authoring happens in a terminal and
comments live on the Fediverse. No database, no admin server, Ruby stdlib and
bash -- no gems, no npm (one asterisk: the optional Pixelfed/RSS widgets need
`rexml`, a default gem some distributions package separately).

- **Content model** -- one post is one JSON file of typed blocks (text,
  headings, quotes with attribution, lists, task lists, tables, code, chat,
  images, video, audio, links, rules), with inline formatting stored as
  offsets into plain text.
- **Authoring** -- an interactive CLI wizard: `add`, `edit`, `publish`,
  `schedule`, `unpublish`, `delete`/`restore`, `toot`, `rebuild`, `preview`,
  `list`. Drafts deploy to hidden preview URLs with a QR code in the
  terminal; `incoming/` stages photos for writing from a phone over SFTP.
  Degrades to plain prompts in a pipe, respects `NO_COLOR` and `TERM=dumb`.
- **Markdown** -- a deliberate subset, with a cheat sheet generated by the
  parser itself and a section on what is deliberately not supported.
- **Build** -- static HTML via ERB. Tag and type archives, anchored
  pagination, RSS, sitemap, client-side search (phrases, `-exclusion`,
  diacritics-insensitive), memoized rendering that writes only what changed.
- **Comments and announcements** -- each published post announces on Mastodon
  *or* Bluesky; replies are the comments, loaded client-side from the public
  API. `unpublish` deletes the announcement too.
- **Deploy** -- six backends (Surfer, local, rsync, git-pages, rclone, SFTP)
  behind one manifest-driven diff with SHA-256 checksums, `--dry-run`,
  opt-in `--prune`, and shrink/growth guards.
- **Import** -- eight sources (Bluesky, Instagram, Tumblr, Mastodon,
  Pixelfed, Twitter/X, WordPress, RSS/Atom), verified against real archives.
- **i18n** -- English, Czech and German; a language is one YAML file with
  per-key fallback.
- **Appearance** -- a complete theme from seven colour keys per mode, config-
  compiled CSS, banner with corner-scoped scrim, photo grids with lightbox.
- **Security by subtraction** -- CSP meta, self-hosted assets, no third-party
  requests from the engine, `noindex` drafts, escaping everywhere.
