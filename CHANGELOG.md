# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.

## 1.3 -- unreleased

Dressing a site differently no longer means editing the engine. Four
things that used to require a modified template are settings now: your own
stylesheet, your own menu, the sidebar, and a lead image above the post's
title. Every default is the layout the engine already had, with one
deliberate exception: the menu bar follows you down the page now, and it
takes over from the menu that used to be repeated under the content --
which only existed because the bar didn't.

### New

- **`./blog.sh check`.** Walks the archive and reports what is broken in
  it: media a post asks for and does not have, images of 1px or less
  (which the build drops *with* their captions, so the page loses both
  without a trace), internal links to addresses nothing answers at, media
  directories no post owns, and one old address claimed by two posts. It
  reads the content rather than the built site, so it works before a build
  has ever run and every finding names a post to go and fix. It only
  reports -- nothing is deleted -- and exits non-zero when it found
  something, so it can hang off cron. On a 4400-post archive it takes
  under a second. `--online` additionally asks the web about the links
  that leave the site: only a host that no longer resolves and a page
  answering 404/410 are reported, because a timeout or a 5xx means "not
  right now" and forty findings that are fine tomorrow would cost the
  tool its credibility. Answers are cached for a fortnight, or nobody
  would ever run it twice. A HEAD that says the page is gone is never
  believed on its own -- some servers answer 404 to HEAD and 200 to GET
  for the same address -- so anything fatal is confirmed with a GET.
- **`./blog.sh export`.** The other direction of the twenty-two
  importers, and the answer to the question anyone should ask before
  moving in: the whole archive as a tree of markdown files with YAML
  front matter, in Jekyll's layout -- `_posts/`, `_drafts/`, pages at the
  root, media copied under `assets/<year>/<slug>/`. `--dry-run` counts
  and writes nothing, `--no-drafts` leaves unpublished work at home, and
  a directory with something already in it is refused until the command
  is repeated with `--force`; nothing is deleted at either end. Like
  `check` it reads only the archive on disk, so it still works on an
  installation whose `env.sh` is gone or whose config no longer parses --
  the day you need to leave is not the day the configuration is at its
  best. The front matter carries `redirect_from` in exactly the shape the
  `jekyll-redirect-from` plugin reads, merging both kinds of old address,
  so on a Jekyll site every URL a post ever had goes on answering. What
  markdown has no syntax for -- video, audio, a link card -- is written
  as HTML and *counted in the summary*, because the destination gets
  HTML where the rest of the post is markdown. Each one carries its own
  definition in an HTML comment above it, which other engines ignore and
  `./import.sh` reads back, so nothing is lost in either direction. Video and audio go out as HTML even
  though the authoring markdown has a form for them: `!![caption](url)`
  is this engine's own, and every other markdown parser reads it as an
  exclamation mark followed by an image. Verified over a real 118-post
  archive -- 118 posts and 420 media files out and back with every field
  identical, which is also how that video defect was found. Everything else the engine keeps and no other engine has a word
  for travels under one `blogsh:` key, which `./import.sh` reads back:
  posts keep their identity, series, redirects and announcement URLs, so
  export plus re-import moves an installation instead of merely leaving
  one.
- **Carrying a post through the publishing queue.** `[m]` in the queue's
  action row picks the post up: the arrows then move the post itself
  through the queue on screen, Enter puts it down and Esc leaves everything
  as it was. The times belong to the queue rather than to the post, so
  carrying one from the eighth slot to the second steps the six in between
  back one slot each -- the same instants are occupied before and after,
  and the whole move is one confirmed write instead of one per slot. `[u]`
  and `[d]` are unchanged for a move of a single slot, and remain the only
  way when the input is piped, where there is no screen to carry anything
  across. A post whose time has already passed is off limits at both ends,
  as it is for `[u]` and `[d]`: the cron owns it now.
- **Unlisted posts.** `unlisted: true` keeps a published post on its
  ordinary address, with its date and its redirects, and takes it out of
  the homepage, the tag and type archives, the feeds, the sitemap and the
  search index; the page is `noindex`, so a crawler arriving from a link
  does not index it either. It is the draft's hidden address generalised
  to a finished post -- for something meant for the handful of people you
  send the link to. It is deliberately not a password: a static host
  serves what it is asked for, and encrypting in the browser would put
  the key on the same page. The frontmatter line shows its current value
  when you edit a published post, and `props` says so.
- **`./blog.sh stats`.** What the archive actually is, counted from the
  posts on disk: how many there are split into published, drafts,
  scheduled and pages (the four add up, and a page that is also a draft
  counts once), a bar per year, what the posts are made of, words with
  both the mean and the median, tags, media, and which platforms the
  archive came from. The pair of averages is the point -- sean.cz reads
  55 words per post on average and 19 in the middle, because half of it
  is imported tweets, and either figure alone would mislead. `--json`
  prints the same numbers unlocalized and unrounded for a cron job or a
  graph. Like `check` it needs no build, no network and no `env.sh`, and
  it answers in under two seconds on 4,400 posts.
- **Editing a post is undoable.** The previous text is kept before an
  overwrite, by an edit or by a re-import, and `[v]` in the `props` dialog
  puts one back. Ten per post, oldest dropped; they travel to the trash
  with their post and come back with it. Not configurable -- a safety net
  with a switch is off exactly when it is needed. Only the text is
  versioned, not media.
- **Pages.** `page: true` takes a post out of the listings, the tag and
  type archives and the feed, and gives it a permanent address at the root
  (`/about/`) with no date on it -- while leaving it in the sitemap and
  the search index, because being findable is the whole point of one.
  **Ghost, WordPress, Squarespace and Substack import them as pages**
  instead of counting them as skips -- a migration that quietly left the
  About page behind was the worst kind of loss, because the new site
  looked complete. Where the source served a page at the same address
  this engine now does (Ghost, WordPress), no redirect is written: it
  would point the page at itself. A page in a WordPress trash stays in
  the trash, like any trashed post. The import then SAYS how many pages
  came across and where they are, and that nothing links to them yet --
  a fresh site derives its menu from content types, and the engine will
  not write a `nav:` key on your behalf, because its absence is what
  means "derive the menu": adding two entries would replace the whole
  thing with a hand-written list.
- **A 404 page.** Built by the site rather than left to the host's
  default, so a mistyped address lands somewhere with the menu and the
  search field on it. noindex.
- **Series.** `series:` groups posts and `series_part:` overrides the date
  for one published out of order; each series gets a listing in reading
  order, and every post in one links to the previous and next part.
  Deliberately only within the series: on an archive assembled from
  twenty-two sources the chronological neighbour is usually unrelated.
- **Reading time and a table of contents.** The first above the length at
  which the engine already stops calling a post a photo with a caption;
  the second from four headings up, or whenever a post asks with `toc:`.
- **`fediverse:creator`.** Mastodon reads it off a shared link and puts
  the author's account on the preview card. No new key -- it is the
  `social:` entry pointing at a profile on the instance the site already
  announces to, and a profile on any other instance is not passed off as
  the account.
- **A feed per tag, for the tags the menu names.** With autodiscovery on
  the tag's own page. A site using the derived type menu gets none: it has
  not named a subject yet.
- **`seo.block_ai_crawlers` and `seo.robots_extra`.** A maintained list of
  training crawlers written into robots.txt, plus free text for the ones
  no list will be current about. Off by default. Worth saying plainly:
  robots.txt is a request, not a fence.
- **`site.extra_css`.** Stylesheets loaded after the engine's own, which is
  where a skin belongs -- previously the only way in was a `<link>` added
  to `layout.html.erb`, and `git pull` took it away again. Paths on this
  site only: every page carries `style-src 'self'`, so a stylesheet on
  another host is discarded by the browser with no error in any place you
  would look, and the site just renders undressed. The build says which
  line it skipped and why; `doctor` reports that plus a local path that
  isn't there, which fails equally quietly.
- **Your own menu (`nav:`).** Entries the site names -- `tag:` for a tag's
  listing, `url:` for anywhere at all -- instead of the content types the
  engine derives, for sites whose subjects map them better than their
  media types do. Without the key nothing changes. An empty list is an
  answer too: no items and no toggle button, which is how a site turns the
  menu off without a second key for it. The bar itself stays if the site
  still has search, because that is where the search field lives; with
  search off as well, nothing is left to draw and the bar goes too. `./style.sh` has a section for it, and it
  is the one section where doing nothing writes nothing -- walking in to
  look at a derived menu must not turn it into an empty one. Adding an
  entry offers your busiest tags and your pages by name, and questions a
  tag or an address the archive does not produce before it is written
  rather than after.
- **`doctor` reads the menu.** A menu item is written once and then
  outlives what it points at -- a post renamed, a tag whose last post was
  unpublished -- and until now nothing said so: the build rendered the
  link, the deploy shipped it, and the reader found the 404. It names the
  item and what is missing, for entries on this site only; an address
  somewhere else is `check --online`'s business. Sites without a `nav:`
  key are not read at all, so nothing pays for a menu they do not have.
  It also names an entry written as `url: "about"` instead of
  `url: "/about/"` -- without the slashes that is not an address but a
  name read against whatever page the menu is standing on, so the item
  leads somewhere different from every page and may well work from the
  front page, which is how it survives being looked at. `./style.sh`
  offers the corrected form rather than just warning.
- **`layout.sidebar`.** The right-hand column -- about, widgets, per-post
  stats -- can be switched off, and with it gone the content takes the full
  width rather than leaving a gap where it used to be.
- **`layout.hero`.** A post's first usable image, lifted out of the text
  and shown above the title with the byline under it. Off unless asked
  for, since it reshapes every post page; a single post overrides the site
  in either direction with its own `hero:` line, the same two doors
  `pinned` has. A 1x1 tracking pixel out of an old import is skipped
  rather than promoted to lead picture, and a post with nothing suitable
  keeps the ordinary layout.
- **`./style.sh` can set everything about how the site looks.** It grew a
  Layout section -- the three region switches above and the list of your
  own stylesheets -- and learned four settings that until now had to be
  written into the YAML by hand: the banner's *filename* (it could replace
  the image, but only onto whatever path the config already named), the
  claim text painted over it, and self-hosted font faces. A site can now
  be dressed entirely from the wizard, which was the point of making all
  of this configuration in the first place.

  Both lists say which of their entries has no file on disk, and refuse a
  stylesheet on another host: every page carries `style-src 'self'`, so
  the browser would discard it without a word and the site would simply
  render undressed. Pressing Enter through any of these sections changes
  nothing -- the current answer is always the default.

- **Only the comments you star, if you want it that way.** Until now a
  reply written to wound was published like any other, and the only
  recourse was on the network. `comments.approval: fav` in
  `config/site.yml` inverts it: a reply appears under the post once you
  favourite it, from whatever Mastodon or Bluesky client you already
  have open. There is no queue and no dashboard -- the moderation
  interface is the app on your phone, and approving is one tap where you
  were reading anyway. Your own replies need no star, and a reply is
  shown only when everything between it and the announcement is shown
  too, so an approved answer never hangs under a rejected question.

  What it costs, in the open:
  - **It needs `scripts/refresh-sidebar.sh` in cron.** "Did *I*
    favourite this?" is a question only an authenticated request can
    ask, and a token cannot be shipped to a browser -- so cron reads the
    thread and writes `comments.json`, and the page renders from that.
    Without that job nothing new ever appears.
  - **On Mastodon the token needs `read:statuses`** as well as
    `write:statuses`. One without it is not refused; it gets a perfectly
    good answer with the `favourited` field left out, which would read
    as "approved nothing". `./blog.sh doctor --online` now says outright
    whether the token can see your favourites, because that failure
    looks like success from every other angle. On Bluesky the existing
    app password is enough.
  - **A favourite is public** on both networks: approving is also
    endorsing, and stars handed out over the years count retroactively.
  - **Approval is not instant** -- one cron interval, or up to a week for
    a post older than ~90 days, which `./scripts/refresh-sidebar.sh
    --full` (new) settles on the spot.
  - **Turning it on hides every existing comment** until you go and star
    the keepers.
  - It keeps a reply off the blog. It cannot remove it from the network,
    where the thread stays public and the post still links to it.
- **A moderated post makes no third-party request at all.** Reading the
  thread server-side removes the last one a visitor's browser made: the
  page's CSP drops its `connect-src` grant to the instance and the
  comments arrive from the site's own domain. This was the one
  deliberate exception to "no third-party requests from the visitor's
  browser", justified by the thread being the live discussion -- which
  moderation ends, so the exception ends with it. Avatars are still
  loaded from the instance hosting them; that one is not fixed.
- `./scripts/refresh-sidebar.sh --full` forces the weekly full pass
  rather than waiting for it. Useful on its own, and necessary with
  moderation on: a comment starred under an old post would otherwise
  wait for that pass.

### Changed

- **A listing's heading marks what it is instead of saying it twice.**
  "Tag: archive" is now the tag itself, wearing the pill shape tags wear
  everywhere else on the site; a search shows the query behind a
  magnifier. The word is still in the markup and still read aloud -- it is
  clipped, not removed, because `display: none` would take it out of the
  accessibility tree and leave a screen reader announcing a bare name with
  no hint of where it is. Content-type listings are untouched: they never
  had a prefix, which is what suggested this. The window title still says
  "Tag: ...", where there is no stylesheet and no pill to say it instead.
- **`config/site.yml.example` opens with an index.** Every section and
  every key it accepts, optional ones in brackets, so the answer to "what
  can I set?" is the first thirty lines rather than the whole file.
  Nothing was missing from it -- the keys were all there, some of them
  commented inside a section, which is easy to read past in four hundred
  lines of explanation. The sections are also in the order the page reads
  now, the order its own header had been describing since before `layout`,
  `seo` and `nav` were added in the middle of the appearance ones.
- **The publishing queue comes back to the post you just moved.** Moving a
  post several slots means pressing `[u]` several times, and the queue used
  to reopen on the first row after every one of them, so each slot cost
  another walk down the list to find the post again. The cursor now returns
  to the post it acted on -- by name, not by row number: `[u]` and `[d]`
  trade the post's place with its neighbour's, so its old row now holds a
  different post, and coming back by number would carry off the wrong one
  on the next keypress. A post that has *left* the queue (published with
  `[p]`, returned to drafts with `[n]`) leaves the cursor on its old place,
  which is where the post behind it has just moved up to.
- **Restoring an earlier version is a list you walk, not a number you
  type.** Every other list in the wizard -- the queue, the old addresses,
  the tags, the posts themselves -- is an arrow menu in a terminal and a
  numbered list only when piped. This screen asked for a number even in a
  terminal, so an arrow key landed in the prompt as `^[[B`. It now behaves
  like the rest, and keeps the numbered prompt for piped input the way they
  all do. The note about images not being versioned moved above the list,
  where it is read before the choosing rather than after it.
- **Action rows fold instead of wrapping mid-word.** The row of keys under
  a post runs to 137 characters in German and 134 in Czech, so on an
  80-column terminal -- or a phone over SSH -- it wrapped wherever the width
  ran out, which is *inside* an item: the bracket naming a key ended up on
  the line above its own words. It now breaks between items and keeps each
  one whole. Nothing is dropped, unlike the keys line on the browse screen:
  there they are ways to move around, here they are the actions themselves,
  and hiding `[x] delete` from the narrowest terminal would hide it from the
  reader least able to guess it is there.
- **Page Up, Page Down, Home and End work in the pickers.** They already
  worked on the browse screen; the arrow menu read the very same keys and
  threw them away, so a picker over a long list -- the publishing queue, a
  tag with hundreds of posts -- could only be walked one row at a time.
- **Tab completes paths in the import wizard.** Every question that asks
  where an export is completes file and directory names, including inside
  directories whose name contains a space, which is where readline's own
  defaults would otherwise give up. Questions asking for a handle, a blog
  name or a URL do not complete. Readline ships with Ruby and installs
  nothing; where it is genuinely absent the prompt behaves exactly as
  before.
- **The wizard holds still.** Every keypress in a dialog used to leave
  another full copy of it in the terminal: walking three rows down the
  publishing queue, opening the actions and moving a post three slots
  scrolled the view by 37 lines, and the screen you were working on was
  buried under identical copies of itself. Screens are now painted over
  themselves from the top, so the same sequence scrolls it by none. This is
  every interactive screen in all four entry points -- the `./blog.sh`
  wizard menu, the queue, the archive, a post's properties and all sixteen
  pickers, plus the questions in `./import.sh`, `./style.sh` and
  `./setup.sh`. Actions that print more than a screen can hold (a build, a
  publish, a reschedule) get the terminal to themselves and hand it back
  when they are done. It is deliberately **not** the alternate screen that
  `less` and `vim` use: that discards everything on exit, and this CLI
  prints things worth keeping. The last screen stays where it was drawn and
  the scrollback above it is untouched. Resizing the window repaints it,
  even mid-question, and a window too short for a screen drops list rows
  rather than the line telling you how to get out. Piped and cron runs are
  untouched, as ever.
- **The three question-and-answer wizards keep a record.** `./setup.sh`,
  `./style.sh` and `./import.sh` ask one thing at a time, and on a screen
  that repaints each question would have replaced the last with no sign of
  what had already been answered. Each question now stands under the
  section's name and the answers already given in it, so a run you are
  halfway through says where you are and what you have said.
- **A version list says what each version said.** Restoring an earlier
  version offered timestamps and nothing else, so the choice was made by
  time and hope on the one screen whose point is recognising a text you
  wrote. The row under the cursor now shows that version's title, or its
  opening words when it has none. Confirming a restore is also one
  keypress now instead of a word typed out: it loses nothing (the current
  text is kept as a version of its own), and this engine keeps typed
  confirmations for what disappears -- deleting a post and unpublishing one
  still ask for the slug.

- **"yes" is a keypress, not any word that starts with one.** Three
  confirmations in the authoring CLI tested their answer with
  `start_with?`, which on a terminal is the same as testing the whole thing
  -- one key is all there is. Down a pipe it is not: the answer is the
  whole line, so on a Czech site "ahoj" meant yes, and so did "abort",
  which is the exact opposite of what the person typing it meant. The three
  it reached were restoring an old version over the text being worked on,
  compacting the publishing queue, and announcing a backdated post -- and
  that last one cannot be taken back. All four places that ask now share
  one rule, the one the setup and style wizards were already using: the
  locale's own yes key, plus the three shipped ones so habits carried
  between languages keep working. A scripted run that piped a whole word
  where a key was asked for has to pipe the key.

- `refresh_sidebar.rb` writes `comments.json` beside `stats.json` while
  moderation is on, and **deletes it** when moderation is switched off --
  a file left behind would keep a since-rejected comment readable at a
  public URL after the page stopped showing it. Both files are merged
  rather than replaced on every run, so a failed fetch keeps a thread as
  last published instead of blanking a discussion.
- `doctor` names the three ways moderation can be configured into
  silence: an unknown `approval` value, moderation without a network to
  announce on, and moderation without the cron job that feeds it.
- The comment count next to a post counts approved replies while
  moderation is on, so the number and the list under it agree.

### Fixed

- **The appearance toggle can find its way back to the system.** One click
  on the sun/moon button wrote a theme into `localStorage` and nothing ever
  removed it, so a reader who tried the other mode once was pinned to that
  choice on every later visit -- and the only way out was to clear the
  site's stored data, which nobody thinks to do. A phone or a Mac set to
  change appearance during the day stopped reaching the site at all. The
  button now cycles through three states -- follow the system, light, dark
  -- and says which one it is on, both in the symbol it shows and in its
  label, so "the system decides" is finally distinguishable from a choice
  that was made once and forgotten. The first click still flips to the
  opposite of what is on screen: a fixed light-then-dark cycle would have
  done nothing visible for a reader whose system is already light, and a
  button that does nothing on its first press reads as broken.
- **A markdown tree's pages are no longer walked past.** The importer
  read `_posts/` and `_drafts/` and nothing else, so a Jekyll site's
  pages -- `about.md`, `colophon.md`, which live in the root by
  convention -- were the one thing a tree could hold that never arrived.
  Root-level markdown is now read too, minus the names that are never a
  page (`index`, `404`, `feed`, `sitemap`, and friends). It also means an
  archive exported from this engine comes back a page short of nothing.
- **A re-imported post no longer collects a platform tag it has already
  got.** The tag is skipped for a post whose front matter carries its own
  `blogsh:` history, so exporting and importing back does not pin a
  "jekyll" pill on the whole archive -- or worse, one naming the platform
  the post left years ago, which is what `source.platform` would have
  provided.
- **`hero:` survived a save.** It shipped in this cycle as a post-level
  override and an edit threw it away: `edit_post` rebuilds a post from its
  frontmatter and then carries over a named list of fields that cannot be
  expressed there, and `hero` was in neither place. Opening an opted-out
  post in the editor silently gave it back the site's answer. It is a
  frontmatter attribute now, next to `pinned`.
- **Keyboard focus can be seen again.** The stylesheet had nothing to say
  about focus -- not one `:focus` rule in eleven hundred lines -- so a
  reader moving through a page with Tab got whatever the browser draws by
  default: a thin ring in the browser's own colour, landing on grounds it
  was never picked for. On the four controls this engine draws itself it
  was as good as invisible -- the appearance toggle is a saturated fill on
  a photograph, the magnifier sits inside the search box, the hamburger and
  the back-to-top button carry the menu bar's own shade. There is one ring
  for the whole site now, in the accent, held 2px clear of the control so
  it reads as a ring around it rather than a border on it. It goes inside
  the control, in white, wherever a ring around it would land on something
  this stylesheet cannot vouch for -- the banner photograph, the lightbox's
  black -- or on the accent itself, which is what the listing you are
  already in and the date badge are filled with right to their edge. Menu
  items take it inside for a third reason: they stand 5px proud of the bar
  at top and bottom, so a ring around one would start outside the bar. It
  is `:focus-visible` rather than `:focus`, so a mouse click leaves nothing
  behind -- the pointer has already said where the click went, and a ring
  that outlives it is why so many sites turn focus off altogether.
- **The site holds still for a reader who asked it to.** Nothing consulted
  `prefers-reduced-motion`, the setting a phone or a Mac offers under
  "reduce motion" and the one thing a reader who gets motion sickness from
  a moving page can do about it. Every hover faded, and the back-to-top
  button scrolled the whole page past them to get there. Both are off for
  anyone who has asked: the transitions collapse to nothing and the button
  puts them at the top rather than travelling there. The scroll had to be
  handled in JavaScript, where it is asked for -- `scroll-behavior` in CSS
  governs only the scrolling the browser decides on. Nothing changes for a
  reader who has not asked.
- **The banner's two lines stop printing over each other on a phone.** The
  site name went in the top left corner of the picture and the claim in the
  bottom right, and the only thing that had ever kept them apart was there
  being enough picture between them. On a phone there is not: a banner
  scaled to a 375px screen is about a hundred pixels tall, and a title at
  30px with a claim wrapped onto two lines fills that on its own. On
  blogsh.app the two ran across each other for 79 pixels -- both of them
  unreadable, with the claim reaching under the appearance toggle as well.
  They share one box now, laid out as a column, and two things in a column
  cannot overlap however short the column gets. The corners are where they
  were. The phone also gets its insets back (10px and 14px instead of 20
  and 24) and lets the claim use the full width instead of 65% of it, which
  is what had it wrapping onto that second line in the first place; and
  because the claim is a band across the bottom now rather than a corner,
  the scrim that keeps it readable is a band too, so a claim over a bright
  photograph no longer fades into it halfway along. Nothing changes above
  700px: same corners, same insets, same picture.
- **The menu on a phone closes with Escape and with a tap on the page.** It
  covers 700 of the 812 pixels a phone has, and the only way back out was
  the same button that opened it -- so a reader who had decided against the
  menu had to go and find that button again, and one on a keyboard had no
  way out at all. Escape hands focus back to the button on the way out,
  since that is where the reader was before they opened it. A tap inside
  the menu is left alone, the search field in there included.
- **Search answers with its best results, not its most recent ones.** The
  index carries one folded blob per post -- title, text and tags run
  together -- so all the search could tell was that the words were in there
  somewhere, and what came back came back in index order, which is by date.
  A search of sean.cz for "mastodon" opened with four posts from this
  summer that mention it in passing; the three articles actually called
  "Tipy pro Mastodon", "Velký test Mastodon aplikací" and one more sat
  below them, where their dates had put them. Results are now scored: a
  word in the title counts for more than a word in the text, and a whole
  word counts for more than the same letters inside a longer one, so "art"
  no longer answers with everything about a "start". Everything else is
  unchanged -- the same AND matching, the same quoted phrases and the same
  `-excluded` words -- and ties keep the order they had, so among equally
  good answers the recent one still comes first. On a personal archive that
  is usually the right tiebreak, and it is only ever a tiebreak now.
- **A search no longer draws a card for every post it found.** Two letters
  match most of an archive: on sean.cz, "a" is in 4371 of 4400 posts, and
  the page built a card for each one -- 21 855 elements in a single
  innerHTML, a results page 868 metres tall, and 619ms of work on every
  keystroke. Fifty cards are drawn now (41ms, 250 elements), and the count
  above them still says how many there were. The cap is only honest because
  the list is ranked: the fifty shown are the fifty best answers rather
  than the fifty that happen to be newest. Ranking the whole 4400 costs
  16ms the first time and 6ms after that, measured on that archive.
- **On a phone the search field is in the bar, not folded into the menu.**
  It was hidden with the menu items behind a button that says nothing about
  search -- on an archive of four thousand posts, the wrong thing to put
  out of sight, and it was hidden in the emptiest bar on the site: one
  button and the rest of the width doing nothing. The field now sits beside
  that button and takes the room, at 40px tall rather than the desktop's 30
  so a finger has something to land on. Opening the menu drops the items
  underneath it and moves nothing that was already on screen. The bar also
  stops standing 60px tall regardless of what it holds: that floor made
  sense when it held one hamburger, and it was what made the row shift as
  the menu opened. It hugs its contents now and comes out 70px -- the same
  height it has always had on a desktop.
- **The lightbox can be opened, walked and closed without a mouse.** Escape
  and the arrow keys worked inside it, which was of no use to anybody: the
  only way in was a click, because an image is not a focusable thing. The
  images it can open are buttons now -- a tab stop, Enter or Space to open,
  named by their own alt text (and where a picture has none, by a label of
  its own, since a button with no name is announced as nothing at all).
  They are made buttons by the script rather than in the built markup, so a
  page whose JavaScript never arrives has pictures again instead of things
  that claim to be pressable and are not. Once open, the overlay says what
  it is (`role="dialog"`, `aria-modal`), takes focus to its close button,
  and keeps Tab inside itself -- it used to walk off into the article
  underneath, which is still there, still focusable, and entirely hidden
  behind a black screen. Closing puts the reader back on the image they
  opened. No gestures and no counter: this is a lightbox, not a gallery.
- **Small things, one sweep.** The scroll listener behind the back-to-top
  button is declared `passive`, so a phone no longer waits to see whether
  it cancels the scroll before scrolling. Comment avatars carry the 40x40
  the stylesheet gives them, so a thread stops shuffling downwards as the
  pictures land. And two tap targets reach the 44px a finger needs: the
  hamburger grows from 40 (it has no background, so nothing looks any
  different), and the appearance toggle keeps the size it paints and gains
  6px of reach above and below instead -- it sits on every banner this
  engine builds, and a corner nobody asked to have redecorated is not the
  place to spend 12px of height.
- **The menu bar follows the reader down the page.** It was at the top of
  the page and stayed there, so on a post read to its end the way out was
  a scroll back to the beginning. Only the top bar: a site with the
  repeated bottom menu has two of them, and sticking both would slide the
  second up over the first at the end of every page. Anything that scrolls
  something into view now stops short of the bar rather than under it -- a
  heading reached from the contents list, a link reached with Tab, an
  anchor followed from anywhere.
- **A search has an address again.** `?q=` was read on the way into the
  page and never written back, so a search existed only on the screen of
  whoever ran it: there was nothing to send anybody, nothing to bookmark,
  and -- the one that stings -- nothing to come back to. Following a
  result and pressing Back landed on an empty search box with the query to
  type all over again. The address now follows the query as it is typed,
  and drops `?q=` entirely when the box is empty. It replaces the current
  history entry rather than adding one, so Back still leaves the search
  page instead of walking the query backwards a letter at a time.
- **Every page has an h1.** A post had one and the cheat sheet had one;
  every listing in the archive started its outline at level two. Tag,
  series, content-type and search listings had a heading already -- it was
  simply an h2, the same level as the post titles it introduces, so it read
  as their sibling rather than their heading; it is an h1 now, and looks
  exactly as it did. The front page had no heading at all, being the one
  listing with nothing to announce, so it gets the site's own title, taken
  out of sight by the stylesheet the way the "Tag" and "Search" labels are.
  Nothing is drawn on it that was not drawn before -- the heading is out of
  flow, and the first post still begins at the top of the page to the pixel
  -- but a reader who moves through a page by its headings now has a way
  into the front page, which until now was the one page that offered none.

- **A post with no title of its own now has a heading.** Two thirds of a
  real archive can be untitled -- 2,754 of sean.cz's 4,418 posts are
  imported tweets and photographs, and a photograph with a caption has
  nothing to call itself. Their pages carried no `h1` at all, so the
  promise above held everywhere except on most of the site. The date is
  what those posts are called: it is the first thing on the page and what
  every listing identifies them by, so the tile already saying it is the
  heading now. Nothing was added to achieve that and nothing moved -- a
  clipped heading repeating the date, which is how the front page carries
  the site title, would have had a screen reader announce it twice in a
  row. With a lead image the date does move, from the byline up to where
  the title would be, because that is where the heading belongs and a
  heading cannot live inside the byline's paragraph. A titled post is
  untouched.
- **The 404 page is built from the same heading as every other listing.**
  It was written out by hand and kept the `h2` that listings had before
  this cycle, which made the one page 1.3 adds the one page "every page has
  an `h1`" was not true of.
- **`check` no longer calls a working address dead.** It knew the posts,
  the tags, the redirect stubs and three fixed pages -- and nothing else,
  so a post linking to its own site's feed, to a later page of any listing,
  or to a series it belongs to was reported as a dead link, with the advice
  that it was probably a permalink left over from an import. On a site
  using series that made `check` exit non-zero over a healthy archive,
  which on cron is the difference between a report worth reading and one
  worth filtering. The files every build writes are known now, series
  listings are derived from the posts the way tag listings already were,
  and a page N is judged by the listing it belongs to -- so `/tag/x/page/2/`
  passes where the tag exists and is still reported where it does not.
- **An unlisted post is not announced.** It is out of the listings, the
  feeds, the sitemap and the search index by the author's own instruction,
  and publishing it put its address into a public timeline anyway: by hand
  without a word, and from cron without anyone to ask. There is no
  half-measure worth having, since an announcement cannot be recalled once
  a server has it, so the rule holds on both paths and `--force` does not
  open this door the way it opens the backdating one. To announce such a
  post, take the flag off first -- one edit, and the decision is then an
  explicit one rather than a side effect of publishing. The properties
  dialog says which it will be instead of promising a toot that is never
  coming, and the cron run says it skipped one, as a skip rather than a
  failure so the exit code still means what it meant.
- **An unlisted post stays unlisted through a re-import.** No source has a
  notion of the flag, so no importer ever sets it, and it was in neither of
  the two lists of fields carried across when a post is matched again by
  its source id -- which put a post the author had taken out of the
  listings back into every one of them, silently, and against the promise
  the import summary makes out loud that re-running is safe. It is carried
  by presence rather than by truth, next to `hero` and `toc`, so an
  `unlisted: false` written on purpose is not read as nothing to carry.
- **`export` sees a directory that holds only dotfiles.** The guard against
  writing a whole Jekyll tree into somebody's existing work listed the
  target with a glob, and a glob does not show entries whose name begins
  with a dot -- so a freshly cloned repository, holding `.git` and
  `.gitignore` and nothing else, read as empty and was written into without
  the `--force` that is supposed to be required. That is the most likely
  destination anyone types here.
- **Questions in `./style.sh` asked without saying why.** The reason --
  that the address a menu item points at answers nothing, that a
  stylesheet or a font file is not where you said it was, that what was
  typed is not an address at all -- was printed just before the question,
  and the frame the question is drawn in paints from the top of the screen
  and erases below it, so the sentence was gone before it could be read.
  What was left was "add it anyway?" with nothing to answer it against,
  and a confirmation with its reason removed is the one thing a
  confirmation must not be. Five of them, plus the hint explaining what
  `rel="me"` is for.

  The same repaint was swallowing two things that are not questions: which
  of its three states the menu section is in, so a menu derived from
  content looked exactly like one switched off at the moment of choosing
  between them, and the line naming a malformed palette, which the code
  comments promise is "named once". All of it travels inside the frame
  now.

  This is a defect this cycle introduced: the screens are new, and
  anything printed just before one is painted over. One place still has
  it -- the banner section names the file currently set, and the question
  that follows erases it -- and it is left because the fix is entangled
  with a second unfixed defect, hints running to 344 columns and being
  cut off by the same frame. Both belong to the same decision.

### Upgrading

- Nothing to migrate. One thing does look different without being asked
  for, and it is the only one, in the order it happened: the menu bar at
  the top became sticky, the menu repeated under the content stopped making
  sense, and it went. That second menu was hardcoded into the layout, never
  a setting, and it existed for one reason -- to give a reader who had
  reached the end of an article a way out where they were standing. They
  have one the whole way down the page now, and it carries the search field
  too, which the bottom one never did. There is no key to put it back: two
  of the same menu on one screen is not a preference. The line it drew
  between the content and the footer was doing real work and is drawn
  without it now, in the same 5px. Everything else a site gets without
  adding a key is the page it got before.
- It is no longer the same *bytes*, though, and the next deploy is a full
  one rather than incremental. The banner's two overlay lines moved inside
  a wrapper element, which is in the layout every page shares, so the whole
  archive is rewritten -- and on top of that every listing heading became
  an h1, the front page gained one of its own, the heading above tag
  listings and search results changed, and the post pages carry reading
  time and a contents list.
- One thing a site's own text gains: the front page (and its `/page/N/`
  continuations) now carries the site's title as a heading. It is clipped
  by the stylesheet, so nothing is drawn -- but a tool that reads the page
  as text rather than as a rendered document will see the title where it
  saw nothing before.
- A stylesheet of your own that positioned `.banner-title` or
  `.banner-claim` wants a look before you upgrade. Neither is absolutely
  positioned any more: the box around them is (`.banner-overlay`, which
  holds the insets the two lines used to carry themselves), and they are
  items in a column inside it.
- To keep the old heading wording, put the word back with one CSS rule on
  `.listing-heading__kind` in a stylesheet of your own.
- Post versions live in `content.nosync/versions/`. They are part of your
  content, not of the engine -- if you back up `content.nosync/`, they are
  already covered.

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
