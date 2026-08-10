# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.

## 1.2 -- unreleased

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

- **A Wayback rescue can take the calendar's window.** The Archive's own
  site lets you pick a year and month; `WAYBACK_FROM` and `WAYBACK_TO`
  are that picker as parameters (`2013`, `2013-01`, `2013-01-15`), and a
  typo aborts rather than silently meaning "everything" -- a window
  quietly dropped would read as a blog the Archive never captured. The
  window filters CAPTURES, not posts: a late window is how you reach a
  blog's end without replaying its whole history, and the summary says
  the run was windowed, because posts the feed no longer carried by then
  are missing from the run, not from the blog. Reading stays
  oldest-first inside the window, so overlapping captures still merge
  with the newest version of a post winning. The image probe ignores the
  window on purpose -- it is the map you pick the window from.

- **`./setup.sh` -- setting a site up is now a conversation.** The
  documented path was to copy two files and edit 277 lines of commented
  YAML; this asks instead, and checks every answer as it arrives. The
  timezone is offered from the machine's own zone database -- unless the
  machine sits on UTC, which is a fact about the datacenter rather than
  about the person answering; then the wizard's own language makes the
  suggestion -- and rejected if it isn't a real zone: the setting whose
  typo would otherwise silently date every post two hours off. The address is checked for shape and written
  to **both** `config/site.yml` and `env.sh`, because env.sh's copy
  overrides the other and the shipped example has it pointing at
  `example.com`: fill in only the config and the site still calls itself
  example.com in its feed, sitemap and every share preview. The Mastodon
  token is verified against the instance on the spot, and the numeric
  account id comes back out of that same call -- so the sidebar widget
  that is most often filled in with an `@handle` (and then silently shows
  nothing) can simply be offered, already correct. Choosing one comments
  network switches the other off, since a config with both is one the
  build refuses to load.

  Nothing is written until the end: answers are collected, both files'
  diffs are shown with secrets masked, and one confirmation covers the
  lot -- so Ctrl-C anywhere leaves an existing install exactly as it was.
  Every question can be skipped with Enter, and re-running it is how you
  change any of this later. Editing the files by hand keeps working
  exactly as before; the two are interchangeable, in both directions.
  Both wizards open with the same ▍ identity banner `./blog.sh` and
  `./import.sh` print -- which site this is, which version -- so a shell
  with several installs never leaves you guessing which one is about to
  be reconfigured.

- **`./style.sh` -- the appearance half, and seven palettes to pick
  from.** Split from setup by lifecycle rather than by file (both write
  `config/site.yml`): setup asks the things you answer once, this is
  everything you come back and fiddle with, so it is a menu you dip into
  -- palette, banner, about, footer, social icons, sidebar widgets,
  fonts, analytics.

  The palette section is the reason it exists. Choosing between fourteen
  hex values is exactly as blind in a wizard as it is in YAML, so whole
  palettes now ship in `config/palettes.yml` -- default blue, warm,
  monochrome and high contrast, each in both light and dark -- and
  picking one is a keystroke. They are the palettes from the "Seven
  keys" gallery on blogsh.app, whose light modes are exactly what that
  page showed; the dark modes are new, since the gallery only ever had
  light homepages. Three more come from the TangerineUI Classic family
  the engine's own palette grew out of (its bluebird IS the default
  palette, to the last hex): **sunflower** in cream and gold with olive
  links -- the golden yellow stays on tag pills, because yellow text on
  cream is unreadable and the accent is above all a text colour here --
  **garden** in greens and khaki, and **ocean** in steel blue over navy.
  Add your own by adding an entry to that file: the
  wizard lists whatever is in it, and a palette you add needs no
  translation to appear.

  And a palette can be **looked at before it is kept**: picking one (or
  finishing the fourteen-value custom route) offers a preview -- your
  own built site with the candidate colors, or on a fresh install a
  bundled sample post rendered through the real builder -- light and
  dark side by side. On a deployed site the preview travels the way a
  draft preview does: uploaded to the site's own
  `/palette-preview.html` (one file, never pruning) and answered with
  the full address and a QR code, so a palette picked at an SSH prompt
  can be judged on a phone. Locally it lands in
  `tmp/palette-preview.html` and opens in the browser where one is
  available. The colors go through the same code
  the build uses (`lib/colors_css.rb`, extracted for exactly this), so
  the preview cannot drift from what a rebuild would produce. Nothing
  is written until the wizard's usual confirmation.

  The banner section is the other one worth naming: give it the path to
  an image and it copies the file into place and **measures** it.
  `banner.width`/`height` exist to reserve layout space before the image
  loads, they have always been copied by hand, and a stale pair makes
  every page jump as it loads.

  As everywhere else here: every question skippable, nothing written
  until you have seen the diff and confirmed it, and the file keeps
  every comment it had.

- **`./blog.sh doctor` -- what is wrong with this configuration, all of
  it, at once.** Every abort in the engine is correct where it stands,
  but each reports only the first problem, from wherever the code
  happened to notice. Doctor reads what is on disk and reports the lot in
  whole sentences, each with a fix line written for somebody who does not
  know which file the setting lives in. It concentrates on what fails
  *silently*: an unknown timezone (Ruby falls back to UTC and says
  nothing), a banner whose declared size no longer matches the file so
  every page jumps as it loads, a widget that can never show anything, a
  font named in the config but missing from `assets/fonts/`, a deploy
  backend configured half way, the example's text still sitting where
  visitors would read it. `--online` additionally asks whether the feeds,
  the analytics script and the access token still answer.

  It runs on configurations too broken for anything else to load,
  including one whose YAML will not parse -- which is exactly when it is
  wanted. Exit status is non-zero for errors only; warnings are advice.

- **Ghost joined the import sources** -- the ninth. Point the wizard (or
  `migrate_ghost.rb`) at the JSON export plus the still-running site's
  URL: the export never carries the images, only `__GHOST_URL__`
  references to them, so they download from the live site -- import
  before the old site goes dark. Drafts stay drafts, scheduled posts
  arrive as drafts (their publish times were the old site's promise, and
  the summary counts them), pages are skipped out loud. A custom excerpt
  becomes the first paragraph, the feature image the first image, YouTube
  embeds the same video blocks hand-written posts get. Note for scripted
  imports: the wizard's source menu gained an entry, so a piped
  `printf "N\n"` may now pick a different source.

- **Substack joined the import sources** -- the tenth. Point the wizard
  (or `migrate_substack.rb`) at the unpacked export directory.
  Newsletters and podcasts import, drafts included, podcast mp3s
  download as leading audio blocks, and paid posts arrive in full --
  the export is the author's own, so the paywall marker is simply
  removed. Subtitles become first paragraphs. Threads and pages are
  skipped out loud, as are posts whose HTML the export didn't include
  (a real Substack habit with the newest posts). Tags don't exist in
  the export at all -- posts arrive with just the platform tag.

- **Medium joined the import sources** -- the eleventh. Point the wizard
  (or `migrate_medium.rb`) at the unpacked export. Posts and drafts
  import with the title/subtitle duplicates and opening divider Medium
  bakes into every body stripped out; the subtitle becomes the first
  paragraph, bookmark cards become links, code blocks keep their
  language. Images download from Medium's CDN -- they are not in the
  export. Published one-paragraph posts with no image are almost always
  responses written under someone else's article, so they arrive as
  drafts for review, counted in the summary; so does the number of posts
  that came without tags, which newer Medium exports no longer include.

- **Threads joined the import sources** -- the twenty-second, closing
  the social-network roster, and both formats the export dialog offers
  are read: the JSON, whose shape is Meta's oddest yet -- every post is
  a media list even when there is no media, with the text riding in a
  title field -- and the HTML page, read back into that same odd shape
  so both walk the same mapping. Your standalone posts import with
  media from the archive, replies to other people's threads are skipped
  and counted (the Bluesky rule), bare URLs become real links, and the
  shared MetaText repair fixes the encoding. Ask for JSON where you get
  a choice: only it marks replies -- an HTML run ends by saying so,
  every time, since it cannot know whether there was anything to miss
  -- and its timestamps carry the seconds
  the HTML page never prints -- the page's minute-level dates, in
  Meta's fixed no-DST Pacific clock, convert back verified-exact to the
  minute against the same account's JSON. The export's
  cross_post_source flag is deliberately NOT a skip signal: on real
  exports it marks posts written directly in the Threads app too -- it
  records where a post was shared TO, and skipping on it would empty
  the archive.

- **Facebook joined the import sources** -- the twenty-first, built and
  verified against a real "Download Your Information" export in both
  the formats Meta offers: JSON and HTML read the same, epoch-identical
  down to the minted re-import ids (the HTML prints its wall clock with
  seconds, in the account's own timezone with daylight saving observed
  -- measured against the JSON of the same account -- and is read in
  the site's zone, the same place when the archive is your own). The
  HTML's dates come localized; Czech and English are understood, and an
  unknown language skips what it cannot date and says so rather than
  guessing. Your own posts import with photos and videos from the
  archive itself; the headline behaviour is what does NOT import
  silently: posts Facebook mirrored in from Twitter, Posterous and
  their era -- on the reference export, 95 % of everything -- are
  recognized and skipped with a count, because those platforms' own
  imports carry the originals (`FACEBOOK_CROSSPOSTS=1` includes them).
  Wordless check-ins and app stories are counted skips too. Meta's
  byte-mangled text encoding is repaired by the same logic the
  Instagram importer proved out, now in a shared module for the whole
  Meta family.

- **The import wizard's source menu is now two levels.** Twenty-one
  sources in one column was a kilometre of scrolling; the first
  question is now what the thing WAS -- a blog or publishing platform,
  a social network, or a dead site (the Wayback Machine) -- and the
  second picks the source inside the group. Backing out of a group
  returns to the groups, not out of the wizard. **Scripted runs are
  untouched:** the piped/non-interactive path keeps the single flat
  numbered list, so existing `printf "N\n"` automation survives.

- **The Wayback Machine joined the import sources** -- the twentieth,
  and the one for blogs whose platform no longer exists at all. The
  Archive crawled the blog's FEED over and over for years; reading
  every distinct capture oldest-first (CDX index, digest-deduplicated,
  original bytes via the id_ endpoint) reassembles the history, and
  re-import matching merges the overlaps. Images recover from the
  Archive by the same time machine. What the crawler never met stays
  lost and is said so: unreadable captures are counted, and a missing
  image -- which the Archive answers with an HTML page and a 200 -- is
  detected by failing to measure as an image and counted as lost
  rather than saved broken. Verified live by rescuing posts from a
  Posterous blog dead since 2013.

  A blog the Archive never saw a feed of falls through to **page
  mode**: every archived post page, newest capture of each. Platform
  packs decide which paths are posts and how the markup spells title,
  date and body -- **blog.cz ships built in** (`/YYMM/slug`, the
  article div, Czech long-form dates, windows-1250 era encodings
  converted), `POST_PATTERN` covers platforms without a pack, and with
  neither the run refuses and prints sample archived paths to build a
  pattern from. Unparseable pages and posts dated only by their
  capture are counted, never papered over.

- **LiveJournal joined the import sources** -- the nineteenth, and the
  one that comes entirely over the wire: LJ has no export file, so the
  import speaks its XML-RPC API, challenge digest for every call (the
  password never travels in plaintext) and the lastsync protocol
  instead of page numbers. `<lj user>` mentions become links, lj-cut
  folds disappear with their content kept, auto-formatted plain-text
  bodies get their paragraphs back. Friends-only and private entries
  arrive as drafts, counted; comments stay behind. Permalinks are
  taken from the API's own url field, never computed -- the number in
  an LJ URL is itemid*256+anum, and a reconstruction would 404.

- **Movable Type and TypePad joined the import sources** -- the
  eighteenth: the line-based MT Import Format half the pre-WXR web once
  spoke, which TypePad exports to this day (gzip read transparently).
  Sections are kept verbatim -- the reference WP importer's habit of
  trimming blank lines is exactly how paragraphs and `<pre>` blocks
  die. Plain-text bodies (`CONVERT BREAKS`) get paragraphs back before
  parsing, comments and trackbacks are counted and left behind. The
  format has no ids and no URLs: identity is minted from
  date + basename, and kept permalinks take `URL_PATTERN` with
  TypePad's own `UNIQUE URL:` lines winning where present.

- **Wix joined the import sources** -- the seventeenth. Point the
  wizard (or `migrate_wix.rb`) at the blog CSV from the Wix admin. The
  rich-content JSON converts to blocks directly -- formatting spans,
  headings, lists, tables, buttons as links, the cover image leading
  the post -- and node types with no equivalent (video, galleries,
  polls) are counted by name in the summary. Images download from
  Wix's CDN by id; category cells holding Wix's internal hex ids
  instead of names are dropped. Kept permalinks come from the export's
  own Post Page URL column.

- **Jekyll, Hugo and every markdown folder joined the import sources**
  -- the sixteenth, and really a whole family: a `_posts/` tree, a Hugo
  content directory, or the output of converters like Meddler and
  Substack2Markdown. YAML and TOML front matter both read, the body
  goes through blog.sh's own markdown parser (no HTML round-trip), and
  images come from the tree itself -- no network, works for a site that
  died years ago. Liquid `highlight` becomes a code block. Because a
  tree cannot tell you its old URL shape, kept permalinks take a
  pattern (`PERMALINK='/:year/:month/:day/:title/'`); an explicit front
  matter permalink always wins.

- **beehiiv joined the import sources** -- the fifteenth. Point the
  wizard (or `migrate_beehiiv.rb`) at the posts CSV from Settings →
  Exports. Each row carries the whole email as HTML; the importer
  slices out the content, drops the template variables, tracking pixel
  and unsubscribe footer, unwraps the layout tables, and rewrites the
  CDN's baked-in quality=80 to full quality before downloading. The
  subtitle becomes the first paragraph, paid posts import in full,
  YouTube thumbnail links become video blocks. Honest gap, the CSV's
  own: it carries created_at but no publish date.

- **Squarespace joined the import sources** -- the fourteenth. Point the
  wizard (or `migrate_squarespace.rb`) at the "WordPress format" XML
  export. It reads like a WordPress import wherever it can, and restores
  what Squarespace's markup hides from a plain parse: images whose URL
  lives in `data-src` (all of them), audio players that are a `<div>`
  with data attributes (they become native audio blocks, file
  downloaded), video embeds stored as escaped markup in an attribute,
  and the feature image the export ships as a separate attachment item
  after its post. Slugs and kept permalinks come from the export's own
  `<link>` paths.

- **Blogger joined the import sources** -- the thirteenth. Point the
  wizard (or `migrate_blogger.rb`) at the Atom backup file from
  Settings → Manage blog → Back up content. The backup mixes posts with
  every comment ever left and the blog's settings; the kind marker
  tells them apart, and the skips are counted by name. Drafts stay
  drafts, labels become tags, YouTube embeds become video blocks, and
  image URLs have their size token rewritten so the full-size files
  download instead of the 320px thumbnails the markup actually points
  at. Kept permalinks come out as real `/2015/03/post.html` files, so
  blogspot-era links survive without server configuration.

- **Podcasts joined the import sources** -- the twelfth: any RSS feed
  whose items carry audio enclosures (Libsyn, Buzzsprout, Anchor, ...).
  Episodes become posts -- artwork, a native audio player, then the
  shownotes -- with the mp3 downloaded and hosted locally, so the
  archive outlives the hosting account. The preview adds up the
  enclosure sizes and says how many gigabytes a show means before
  anything is written. Adapter notes like that one (and Ghost's
  scheduled-posts count, Medium's response count) now appear in the
  wizard's preview too -- previously only the scripted imports printed
  them. They say it in the wizard's language as well; the scripts stay
  deliberately English.

- **A migrated blog can keep its old addresses.** Posts have a new
  `redirect_from` key -- a list of site-root paths the post answered at on
  its previous platform -- and the build serves a redirect at each one,
  the same stubs a rename has always produced. Importers that know their
  posts' original URLs write it on request: the wizard asks "will this
  site answer on the same domain?", the `migrate_feed.rb` and
  `migrate_tumblr.rb` scripts take `KEEP_PERMALINKS=1`. Old Blogger-style
  `.html` addresses come out as real files, so those URLs work without any
  server configuration. WordPress "plain" `?p=123` permalinks cannot be
  kept (the identity lives in the query string, invisible to a static
  file) and are counted in the import summary instead. For archives
  imported before this existed, `scripts/backfill_redirects.rb
  <old-domain>` writes the same entries from what those imports already
  stored -- preview by default, `WRITE=1` to apply. Addresses the site
  itself owns (`/posts/`, `/tag/`, ...) are refused out loud, and a live
  page always wins over a redirect.

- **The queue got its own screen.** `./blog.sh queue` (and a matching
  wizard menu entry) lists every scheduled post in publish order and
  acts on the one you pick: move it a slot earlier or later, publish it
  right now, give it a different time, or return it to the drafts.
  Moving means exchanging times with the neighbouring post, so the set
  of occupied slots never changes -- a hand-picked 14:17 stays a 14:17,
  it just gets a different post. When a post leaves the queue (published
  now, or removed), the screen offers -- never forces -- to let the rest
  step one slot forward into the gap. The preview rebuilds once, on the
  way out, not after every move.
- **Funkwhale and Bandcamp play too, by asking once.** Their page address
  doesn't contain the player's, so saving a post that embeds one asks the
  service where its player is -- the only moment writing a post touches the
  network -- and stores the answer, so editing never asks again and the
  build stays offline. What is stored is an address, not the HTML the
  service returned: a post still carries no third party's markup. If the
  lookup fails, the post saves anyway with a link where the player would
  be, and saving again retries.
- **Six more platforms play in a post, from their address alone.** A
  `!![caption](url)` line now recognises Vimeo, PeerTube and archive.org
  as video, and Spotify, SoundCloud and Mixcloud as audio -- the same
  gesture YouTube has always used, and the same rule: the engine stores a
  provider and an id, never the platform's own embed code, so no third
  party's markup or tracking ends up in a post and no network call happens
  while writing one. Each page asks its Content-Security-Policy for
  exactly the players it carries, which is what lets a PeerTube video work
  at all: the instance is a property of the post, not of the engine. The
  addresses that trip people up are handled -- an unlisted Vimeo link
  keeps its hash, a Spotify URL copied from a browser loses the `intl-xx`
  segment that would 404 the player, a private SoundCloud track keeps its
  token, and Mixcloud's second hostname is allowed because its widget
  redirects there.
- **An interrupted post is offered back instead of just kept.** The text
  from an editor session has always survived an aborted save in
  `.last-edit.md`, but recovering it meant copying the file out by hand
  before the next `add`/`edit` overwrote it. Now the next `add`/`edit`
  finds it, says what it is and when it was written, and asks: `[r]`
  opens the editor on it, `[d]` discards it, `[c]` continues without it.
  No blank-Enter default anywhere in that prompt -- a stray return can
  neither restore old text into a new post nor throw away the only copy.
  A new `.last-edit.meta` records which command wrote the buffer, so text
  from an interrupted `edit <slug>` is only ever restored into that same
  post: offering it to `add` would quietly produce a second post instead
  of continuing the first, and the prompt names the command that does
  continue it. Closing an editor without typing anything no longer
  overwrites the buffer either -- that is how a recovered post used to
  disappear a second time.
- **The header's type comes from the config, like its colours do.**
  `fonts.banner_title` and `fonts.banner_claim` take a CSS font stack,
  `fonts.banner_title_size` and `fonts.banner_claim_size` any CSS length,
  and a site's own web font is one `.woff2` in `assets/fonts/` plus an
  entry under `fonts.faces` away -- the build writes the `@font-face` and
  the custom properties into the same generated stylesheet the palette
  already uses. Say nothing and nothing changes: self-hosted JetBrains
  Mono at 45px/20px, exactly as before. Narrow screens scale from
  whatever size is set rather than from a second pair of keys, so a
  bigger title still steps down on a phone. A declared font file that
  isn't in `assets/fonts/` is named in the build output instead of
  silently rendering in the fallback.
- **A phone video says what it is.** Saving a post with a video now reads
  the codec out of the file itself and says one line when it matters: an
  HEVC clip plays in most browsers but not all, and a QuickTime `.mov`
  carries a container not every browser accepts even when the video
  inside is ordinary H.264. Both messages come with the `ffmpeg` command
  that fixes them, naming the actual file. Neither refuses the save --
  HEVC is not HEIC, and taking away a video most readers could watch
  would cost more than it saves; the per-file size limit remains the only
  hard stop. Reading the codec costs about a third of a millisecond on a
  240 MB file and needs no external tool.
- **Old addresses can be given up.** `[a]` in `./blog.sh props <slug>`
  lists every address that redirects to the post and drops the one you
  pick. It exists for a state that had no cure: when a new post takes an
  address an older post still redirects from, the build refuses to
  overwrite a live page with a redirect stub and says so on every build,
  forever -- and nothing short of hand-editing the post's JSON could
  remove the entry. Those entries are marked "taken by another post".

- **The archive is something you can walk through, not just a list that
  scrolls past.** `./blog.sh browse` (and the wizard's fourth entry) shows
  the same posts as `list` as a screen you stay in: arrows and Page
  Up/Down through the whole archive, filters by type, state and tag with
  the count next to each, and a search that filters as you type. The
  search is the site's own: words are ANDed, `"a quoted phrase"` counts as
  one, `-word` excludes, and diacritics never decide a match -- the query
  language and the folding live in `lib/search_query.rb` next to a note
  that they and `assets/js/search.js` change together, because a query
  that means one thing in the browser and another in the terminal is
  worse than no search in the terminal at all. It searches the full text
  of every post, so under the selected row there is a line of that post's
  own text showing why it matched; the space bar opens the whole post read-only
  (the same markdown `edit` would give you, with media lines shortened to
  their file names); Enter opens it for editing and comes back to the same
  row, same filter. The keys are deliberately none of the letters that
  mean an action elsewhere in the CLI -- p is "publish" in three dialogs
  and x is "delete" in two -- so the preview is the space bar, the way
  every file manager does it, and clearing the filters is z. The rows lead with the title, falling back to the slug
  for the posts that have none -- on an imported archive that is over half
  of them. `list` is unchanged and still prints the slug first: down a
  pipe that is the thing you copy into the next command, and `browse`
  itself falls back to exactly that when it isn't talking to a terminal.

- **Two more built-in social icons: Facebook and X.** The footer set
  covered the Fediverse and the usual code-and-video suspects but not the
  two networks half the world still lives on -- the first site imported
  from Ghost had both and nothing to show for them. `icon: facebook` and
  `icon: x` now work in `site.yml`, the appearance wizard offers them,
  and `icon_svg` remains the escape hatch for everything else.

- **Three finishing touches for crawlers and phones.** Post pages now
  carry `article:published_time` and one `article:tag` per tag (the
  `og:type=article` was already there, just bare), plus a schema.org
  BlogPosting block as JSON-LD -- the shape rich results actually read.
  The JSON-LD needs no CSP loosening: script-src governs execution and a
  data block never executes. And every page names a `theme-color` per
  colour scheme, taken from the palette's own background through the same
  resolution colors.css uses -- so the browser chrome on a phone stops
  banding against whatever palette the site runs. Drafts get none of the
  article metadata; their pages stay noindex and their dates are
  bookkeeping. Worth knowing before deploying: theme-color touches the
  layout, so the first deploy after this rewrites every page once.

- **The Wayback rescue reads b2evolution sites now, and finds them by
  itself.** A second platform pack for page mode, built from a real 2008
  skin rather than documentation: the body in the stock `bText` template
  (which skins practically never replaced -- that is what makes the pack
  general), `h3.bTitle` titles, tags behind their localized label, ads
  and search boxes excluded by construction, and the shipped `y/m/d`
  two-digit dates read in the order the template source says, which no
  rendered page could tell you. Unlike blog.cz there is no host to
  recognize -- every b2evolution lived on its own domain -- so when
  neither the host nor `POST_PATTERN` says anything, one archived page
  is sniffed for the platform's markup and the run says so in its
  report; `WAYBACK_PACK=b2evolution` names it outright.

- **Builds and deploys take a lock, so two runs can no longer rewrite
  `public.nosync` at the same time.** Two of the things that write it come
  from cron -- the scheduled publish every quarter of an hour, the sidebar
  refresh every half -- and on a large archive a build plus a deploy takes
  longer than a tick, so the overlap was ordinary. What it produced was
  not: a deploy walking a tree that was being rewritten under it, or
  pruning as an orphan a page the other run had just published. A run
  that finds the lock held does not queue up behind it; cron says so and
  leaves without mailing, a run you started reports it and exits non-zero
  so nothing tells you a deploy happened when it did not. Where the
  filesystem cannot lock at all, everything behaves as it did before.
  The lock file is shared rather than private, and a run that may not
  write it falls back to opening it read-only: the publishing cron often
  runs as a different user than the person at the keyboard, and a lock
  only one of them could open would have left exactly the collision it
  exists to prevent.

### Changed

- **A YAML syntax error in `config/site.yml` is now a sentence, not a
  backtrace.** It used to surface as a Psych exception from whichever
  entry point happened to read the file first. It now names the line, the
  column, the three usual causes (a tab where spaces belong, a missing
  quote, a colon inside an unquoted value) and points at `doctor`.

- **Configuration written by the engine keeps its comments.** Both
  wizards write through a text-level editor that substitutes values into
  the documented template and leaves every other byte alone, rather than
  loading the YAML and dumping it back -- which would have thrown away
  the ~200 lines of explanation, the commented-out blocks you uncomment
  when you want a widget, and the folded scalars real sites keep HTML in.
  Every write is verified by reading the file back, and restored from its
  backup if it does not read the way it was asked for.

  The diff both wizards show before writing is a proper LCS diff.
  Line-for-line comparison failed in a way that mattered: adding one
  entry to a list shifts every line below it, so a four-line change read
  as "everything from here to the end of the file" -- which is precisely
  the impression a tool asking permission to edit your config must not
  give.

- The "what next?" menu after a save reads in flow order --
  `[d] keep as draft  [e] edit  [p] publish  [s] schedule  [x] delete` --
  the states a post moves through, rather than most-frequent-first. The
  keys are unchanged.

- **Every command now opens with the identity block.** The wizard's
  "which engine, which site" header -- version, site name, address --
  now also tops `help`, `doctor` and every other screen-bound command,
  with the mode on its own line under it: on a machine with more than
  one install, "which blog am I in" is the first thing help and doctor
  should answer. The wrapper's bare `== blog.sh ==` banner is gone, and
  piped output stays data-only -- `./blog.sh list | wc -l` counts posts,
  not banner lines.

- **The sidebar is 260px wide, and the post column gets everything
  else.** The grid used to split the page 2:1; now the sidebar track is
  fixed at its content width and the post column takes every pixel the
  viewport gives or takes -- about 40px more text at full width. The
  gutters are uniform and the tricks behind them are gone: post text
  ends at its column edge (no compensating padding), sidebar cards carry
  no horizontal padding and no longer overhang the layout's edge
  padding, so the space between the columns is the grid gap and both
  page edges are the layout's own 1rem -- the same 16px the nav already
  used. On a phone this turns the sidebar's lopsided 40/24 insets into
  16 on both sides.

### Fixes

- **Seven defects a pre-release audit found, each of them a way to lose
  or corrupt what you had written.**
  - **`[s]` in the draft preview was the one scheduling path that did not
    check whether the post had changed underneath it.** The
    scheduled-publish cron runs every fifteen minutes; if it published
    while you sat at that prompt, `[s]` wrote the pre-publication copy
    back — the post reverted to a draft and its announcement URL was
    dropped, so `unpublish` could no longer delete the toot and the next
    cron tick announced the post a second time. The other three
    scheduling routes had the guard all along.
  - **Two markdown spans covering the same words duplicated the text on
    every save.** A link around inline code, or italics around a
    strikethrough, produced both spans at the top level instead of one
    inside the other — `config.rb` came back as `config.rbconfig.rb`,
    doubling again with each edit. Both shapes are what the HTML
    importers produce from ordinary posts.
  - **A code block containing a fence line lost everything after it.**
    Fenced with exactly three backticks whatever the content, a block
    that demonstrated fenced code closed at its own example: the rest
    became prose and the tail vanished, silently, because no block type
    had disappeared. Fences now grow one backtick longer than anything
    inside them, and the parser accepts three-or-more.
  - **A double quote in an image caption made the post uneditable.** The
    caption is written inside quotes, so an unescaped one broke the line
    the parser had to match, and saving aborted with a complaint about a
    rule you had not broken. The same fault in a link title was worse for
    being silent: the link was destroyed and its markdown published as
    visible text. Both are escaped and unescaped now.
  - **The archive browser painted as a diagonal staircase.** Inside raw
    mode the kernel stops turning a newline into a carriage return plus a
    newline, so every row started where the previous one ended.
  - **Imported media could be republished as the wrong picture.** A file
    missing on one run and present on the next shifted every later
    filename, and the copy step skips a name that already exists — so the
    post pointed at the previous run's bytes. Numbers are now spent when
    a file is referenced, present or not, exactly as they are for a
    download that fails.
  - **Every entry point died on a terminal this machine has no entry
    for.** `clear` fails on ghostty, kitty, wezterm and `TERM=dumb`, and
    as the last command of an and-list under `set -e` it took the whole
    tool with it — before printing a word.

- **Four more from the same audit.**
  - **A re-import of an indented feed duplicated the whole archive.** The
    channel address was read in the one way that returns only the first
    line of text, so a feed whose `<link>` sits on its own line resolved
    to nothing — and without it, nothing matches what is already there.
    A Wayback rescue reading many captures of one feed duplicated every
    post many times over in a single pass.
  - **The sidebar cron reported every failure as success.** The status it
    tested belonged to the negation, not to the run, so it was always
    zero: a monitored job saw a clean run forever while the sidebar had
    not refreshed for weeks.
  - **A paragraph beginning "1) " grew a visible backslash.** The writer
    escapes the parenthesis so the line cannot turn into a list; the
    parser knew how to undo that for "1." but not for "1)", so the
    backslash was published — on an edit that may have changed only the
    title.
  - **`./setup.sh` offered Czech to a config with no language set.**
    Every other part of the engine reads a missing language as English.
    Two "leave it alone" keystrokes were enough to switch the install and
    rebuild the public site in the other language.

- **Four more the same audit found, none of which a user could work
  around.**
  - **Reordering the queue could leave half the move applied.** Swapping
    two posts is two writes, and if the second refused — a slug already
    taken in the year it would move into — the first stayed: two posts
    on one slot, both published by the cron, or one published months
    early. Both halves are now checked before either is written.
  - **`./style.sh` threw away the whole session on an ordinary config.**
    A list written level with its key — valid YAML, and what most tools
    emit — was misread as belonging to nobody, so the footer links were
    written twice over. The result did not parse, the file was rolled
    back, and every other answer given in that run went with it.
  - **A local deploy reported every file as failed while copying it
    fine.** Under cron, where the language settings are unset, a target
    path containing accented characters broke the log line rather than
    the copy — and the failure was recorded, not the success. The site
    was on disk, the deploy said it was not, and every following run
    warned about a deploy that had already happened.
  - **`help` and `version` died on the very install they exist for.**
    Both are meant to answer when the configuration is broken; both
    loaded the configuration on the way in and aborted. They now have
    their own entry point, as `doctor` already did.

- **Six the second audit found, three of them in the first audit's own
  fixes.**
  - **The trash was unreachable without typing a slug from memory.**
    `./blog.sh restore` with no argument, and the wizard's whole Trash
    entry, reported an empty trash over a full one — they were still
    looking for the layout used before posts were filed by year. The
    engine's only undo, effectively dead.
  - **Both crons died on every tick once an accented filename reached the
    deploy.** The deploy is the one entry point that does not load the
    site config, and with it the rule that files are read as UTF-8 — so
    under cron, where the language settings are unset, the manifest
    raised instead of parsing, and the site stopped updating.
  - **A post could render a completely blank page.** The structured-data
    block escaped one of the two sequences that can end a script from
    inside it. Text containing an unterminated HTML comment followed by
    another script tag swallowed the rest of the page.
  - **The fix for "1) " broke a backslash an author typed themselves.**
    Teaching the reader to undo the escape without teaching the writer to
    double it meant `:\)` quietly lost its backslash on the next save.
  - **Span types the engine does not know still duplicated their text.**
    The ordering fixed the five known kinds; anything an importer invents
    shared a rank with inline code and was written twice.
  - **A fence with a language written after a space ("``` ruby") was not
    recognised**, so the code became prose and the rest of the post was
    swallowed into a code block.

- **The rest of what the second audit found, fixed rather than deferred.**
  - **A feed that names its address in an unusual way no longer duplicates
    the archive.** Re-import matches posts by their source, and the
    source's identity starts with the site's host — which came out empty
    for an Atom feed linking only to itself, for a bare domain, for an
    internationalised one, and for a channel with no address at all. Every
    re-run then wrote the whole archive again, which is the opposite of
    what this engine promises.
  - **`./blog.sh preview` no longer serves the site to the local
    network.** It bound every interface while printing "localhost" — and
    what it exposed was the built archive, which after an import is a
    personal history that has never been public.
  - **Comment threads survive changing networks.** The page's security
    policy was built from the network configured today, so posts announced
    on the previous one had their comments blocked by the browser. It is
    now built from what each post actually carries.
  - **The queue publishes the post you picked.** With the same slug in two
    years, `[p]` looked the post up by name again and could publish — and
    announce — the other one. Compacting the queue is also checked as a
    whole now, instead of stopping halfway and reporting that nothing was
    saved.
  - **A first post whose opening words are a long address no longer dies
    with a filesystem error**, and restoring from trash no longer buries
    the restored media inside an older directory of the same name.
  - **One unreadable post file no longer stops the sidebar from ever
    refreshing again**, a fetched feed cannot grow without limit or be
    redirected off the web, an announcement that has to be trimmed fits
    the limit including its ellipsis, and a link ending a sentence keeps
    the sentence's punctuation out of the link.
  - **A post title containing a line break no longer walks the archive
    browser's screen down the terminal.**

- **A third audit, over the previous two audits' fixes.**
  - **Writing a quotation with nothing above its attribution could hang
    the editor.** A loop that discarded blank lines never stopped once it
    ran out of them: `add` never returned, and a stored quote of that
    shape hung on every save.
  - **The queue's `[p]`, and the draft dialog's own actions, now act on
    the post shown.** They looked the post up by name again, so with the
    same name in two years they could publish, edit or delete the other
    one. (Three of these were described as fixed in the previous release
    notes and were not in the code — the entry has been corrected.)
  - **A feed's identity no longer comes from the wrong link.** The
    previous fix took the first address a feed offered, which for a feed
    declaring its licence first was Creative Commons — and a wrong
    identity is worse than none, because unrelated archives then share it
    and overwrite each other. A local export path could become an
    identity the same way.
  - **A link that ends in a bracket keeps it.** Trimming punctuation off
    announcement links took the closing bracket off addresses that own
    one, such as Wikipedia's.
  - **A tab in a post title no longer walks the archive browser's frame
    down the screen** — the character the previous fix named was the one
    it did not remove.
  - **Importing a large archive over the network works again**, after a
    size ceiling meant for a sidebar widget was applied to it.

- **The last small ones, done before the tag rather than after.**
  - **A fetched feed is now capped while it arrives**, not measured once
    it is already in memory — a remote could previously make the process
    hold the whole oversized response before the limit noticed.
  - **A code block whose language is written with a backtick stays a code
    block.** The hint shares the fence line, and a backtick in it made
    that line stop being a fence at all.
  - **A link title containing a line break comes back as itself**, rather
    than carrying an invisible placeholder character into the published
    page.
  - **Imported inline images no longer count as missing files.** A
    `data:` image is the picture itself and is skipped quietly; a
    protocol-relative address is fetched like the remote image it is.
  - **The import summary separates two different losses**: a file missing
    from a post that was written, and one from a post that was skipped
    entirely. One line for both claimed posts had been written that never
    were.
  - **A listing page is no longer granted network permissions it never
    uses** — comment threads are only ever fetched on a post's own page.
  - **A queue reorder that dies partway now says which posts moved and
    which did not**, so the times can be repaired by hand before the cron
    runs on them.

- **The two unattended scripts check the Ruby version like everything
  else does.** `./blog.sh`, `./setup.sh` and `./style.sh` all refuse an
  ancient Ruby with a sentence; the publish and sidebar crons did not --
  and cron's minimal PATH is exactly where a system Ruby 2.6 gets picked
  up, dying mid-run with an error nobody reads.

- **Bold running straight into italic keeps both.** Written out, that
  adjacency is `**bold***italic*` — and the run of three stars in the
  middle is not one delimiter but two: the closer for the bold, the
  opener for the italic. Read as a single run, the whole paragraph fell
  through to italic and came back with stray asterisks in the text. The
  reading now splits the run the way CommonMark's own rules do, and the
  round-trip matrix — every combination of up to three overlapping spans,
  saved three times over — is clean for the first time.

- **`help` on a broken install prints help, and nothing else.** The
  identity line above it wanted the site's name, and asking for it on a
  configuration that will not parse produced a YAML error before the
  first line of the help text — a complaint nobody had asked for, from a
  command that exists precisely for when things are broken. The banner
  now reads the configuration quietly and simply leaves out what it
  cannot find. `doctor` still reports the problem in full, with the line
  and column to look at, because that is the one command whose job it is.

- **A feed whose CDATA sits on its own line no longer reads as twenty
  posts with no body.** `Feed#text_of` read an element through REXML's
  `element.text`, which returns only the FIRST text child -- and a feed
  generator that writes a newline before its CDATA section makes that
  first child pure whitespace. Every item in such a feed imported as
  `:empty`; the posts were there the whole time, one indentation away.
  All text children are read now. Found on the final capture of a dead
  blog whose 2008-era feeds had the CDATA flush against the tag -- the
  same blog, readable for years, became unreadable the day its
  generator started indenting.

  The teaser probe learned the same lesson twice over: it now reads all
  text children too, and a trailing self-link whose anchor text is the
  literal word "Permalink" no longer counts as a "read more" -- some
  generators append that footer to every item, complete posts included,
  and one such feed read as 20 truncations out of 20 full posts.

- **A throttling server no longer reads as a blog that was never
  archived, or as pictures that were never kept.** Two places gave up
  far too early, and both blamed the source for it.

  A rescue that downloads images is exactly the traffic the Wayback
  Machine throttles, and it throttles by REFUSING connections rather
  than answering with a status. That refusal was not among the failures
  worth retrying, so it fell straight through to the handler that counts
  captures which are not feeds: one real run reported 81 of 82 captures
  unreadable, and every one of them was a clean RSS file the moment it
  was asked for on its own. Refused, unreachable and timed-out
  connections now wait the same way a 5xx does, and a capture the
  Archive stopped answering for is counted and named separately from one
  that came back and was not a feed -- the first is missing from the
  run, the second from the blog.

  The media downloader had the same gap for a different reason: it did
  retry, but three times with a one-second pause, which is nothing
  against a door held shut for tens of seconds. The same run lost 36 of
  37 pictures, every failure a refused connection, while the rescue code
  beside it waited fifteen, thirty, forty-five and sixty seconds and got
  everything it asked for. The downloader now waits on that scale too --
  but only for a server that is there and saying "not now". A name that
  does not resolve is a host that has been gone for years, routine in
  these archives, and those keep the brief pause they had: waiting two
  minutes for each of a dead host's images would turn an import into an
  overnight job.

- **Eighteen smaller corrections from the same review round.** Among
  them: a hand-typed frontmatter date that will not parse is a sentence
  naming the buffer, not a backtrace; a draft whose JSON lost its
  draft_token (hand-copied files) is skipped and named instead of built
  at a guessable address; the archive browser's "why it matched" line
  answers the current query, not the previous one, and a tag named
  "365" can actually be typed; a `colors:` section written as a list
  degrades to the default palette instead of a TypeError; a redirect
  chain that never lands is reported; an unterminated `<script>` in a
  truncated capture no longer leaks code into a post; a dateless
  Substack row imports by its send time or skips under its own name;
  Wayback capture dates read as the UTC they are; a commented-out `<div>`
  no longer unbalances the b2evolution reader; the setup diff masks a
  commented-out token like an active one; the doctor accepts `9:30`
  slots the engine accepts and stops calling empty titles "filled in";
  re-running a wizard over a hand-edited config stops rewriting lines
  whose values did not change; an unusable lock path says it is running
  unlocked; the palette preview never QR-encodes example.com; and the
  Czech strings say "postů: 2" instead of "2 postů" and finish
  translating the two oldest palette descriptions.

- **The sidebar cron stops turning a quiet skip into a failure.** The
  wrapper is two processes: the refresh (which skips silently when a
  build holds the run lock) and the deploy it then execs -- whose own
  lock check exited 1, so the whole cron job failed and mailed about a
  collision that was handled correctly one line earlier. The refresh's
  busy skip is now a distinct exit the wrapper maps back to 0, the
  upload is skipped with it (nothing was regenerated, so there was
  nothing to send), and the deploy accepts `--busy-ok` for cron wrappers
  while a hand-run deploy keeps failing loudly. And a half-written
  palette in `config/palettes.yml` -- documented as user-editable -- no
  longer crashes `style.sh` with a backtrace: the malformed entry is
  named once and left out, the rest keep working.

- **Three setup-wizard corrections.** Menus now open with the cursor on
  the CURRENT value, so pressing Enter keeps it -- exactly what the
  wizard's own help promises; before, every menu opened on its first row,
  and on the language menu (Czech sorts first) Enter silently switched an
  English site to Czech. Choosing "Nowhere yet" as the deploy target now
  actually unsets the configured backend instead of printing "builds stay
  local" while `./blog.sh rebuild` kept shipping to the old target -- the
  backend's tokens survive as comments for a later re-enable. And prose
  answers keep their whitespace: two spaces after a period or a tab used
  to fail the write's own verification and roll back every answer of the
  run, because the folded YAML style collapses whitespace runs; such text
  is stored as a quoted or literal scalar now, byte for byte.

- **One build guard and three import fixes.** A pair of imported
  `redirect_from` entries where one address is a directory of the other
  ("/x.html/sub/" then "/x.html") crashed the whole build with EISDIR;
  the second stub now skips out loud like every other collision. A
  redirect whose `Location` is relative -- legal and common -- used to
  dial an empty host three times and lose the media; it resolves against
  the request URL. A media URL with diacritics in the filename (routine
  in the Czech archives the importers target) always failed as "URI must
  be ascii only" after three pointless retries; it is percent-encoded,
  and a URL that cannot parse at all fails once, with a line saying so.
  And tables written with HTML5's optional end tags -- no `</td>`, no
  `</tr>`, the house style of hand-written archives -- no longer nest
  every cell inside the previous one and emit each row twice.

- **Four archive-browser corrections.** Opening a post from search
  results and coming back showed "(nothing matches)" for the query that
  had just matched -- the text index is rebuilt on return now (rebuilt,
  not kept: the edit may have changed the very text being searched). The
  index was keyed by slug, so two posts sharing a slug across years
  answered searches with each other's text; it keys by year/slug. The
  screen holds the terminal in raw mode for its whole life instead of
  per keystroke, so fast typing during a repaint no longer echoes stray
  characters into the frame. And rows are measured in display columns --
  emoji and CJK count two -- so an emoji-heavy row no longer wraps and
  corrupts the repaint one line at a time.

- **Editing a post can no longer silently corrupt it -- eight round-trip
  defects in the markdown writer and parser are gone.** `edit` turns
  stored blocks into markdown and back, and on a real 4840-post archive
  that trip quietly damaged 147 posts: partially-overlapping bold/italic
  (ordinary in imported Tumblr formatting) duplicated text and left stray
  asterisks; a `|` inside a table cell truncated the row; a `!` right
  before a link reassembled into image syntax and made the post
  uneditable; a URL with parentheses lost its tail into the visible text;
  a paragraph starting with `>`, `#`, `- ` or `1. ` changed block type
  (the `>` was eaten outright); a table with more cells than its header
  lost the extras; code spans gained a layer of backslashes per edit (and
  a code span demonstrating image syntax aborted the editor); a link
  whose text contains brackets fell apart. The writer now normalizes
  spans (splits partial overlaps, merges adjacent same-type runs, drops
  zero-length ones), escapes block sigils only at line starts, keeps code
  spans literal and reads balanced parentheses in URLs; the parser learned
  the boundary-sharing bold/italic shapes CommonMark reads. Verified over
  the whole real archive: every post now round-trips with its text intact
  and is byte-stable from the second write on.

- **A re-import after a media failure can no longer publish the wrong
  image.** A failed download used to give its filename number back to
  the next image, so what a post's images were CALLED depended on which
  downloads succeeded. When the source recovered, the re-import -- the
  exact flow the engine advertises as safe -- assigned the names the
  other way around, and since existing files are never overwritten, the
  post ended up showing its second image where its first belongs. A
  failed fetch's number now stays spent: filenames depend only on the
  order the post references its media, every run agrees with every
  other, and the gap in the numbering on disk is the honest trace of the
  download that failed. A dead URL referenced twice in one post is also
  counted as one loss now, not two.

- **The wizards work on Ruby 2.7 and 3.0 again.** `YAML.load_file(path,
  aliases: true)` is Psych 4 (Ruby 3.1+); Psych 3 -- the system Ruby of
  Debian 11, squarely inside the "Ruby 2.7 or newer" this engine
  promises -- does not know the keyword and raises. Two readers carried a
  guard for that; eight did not, and the ones that did not were the 1.2
  wizards' own: on Ruby 2.7, `setup.sh` and `style.sh` could not write a
  config at all, failing verification with a message that blamed the
  file. One guarded loader (`lib/yaml_compat.rb`) now serves them all.

- **Scheduling works again.** A fix in the previous round gave the
  scheduling dialog a parameter carrying the post file's bytes from
  before the prompt -- evidence for the are-you-editing-a-stale-file
  guard -- and the dialog's own variable holding the typed date happened
  to bear the same name. The typed line overwrote the capture, the guard
  compared the post against the date string, and every path into
  scheduling (the command, [s] on a draft, [s] in properties, the queue)
  aborted with "changed on disk". The variable is renamed, the guard gets
  its real evidence -- and the standalone `schedule` command now carries
  the same protection the other paths already had.

- **An image a post uses twice no longer goes missing from the media
  folder.** Every importer collects a post's media into a source-keyed
  map, so registering the same file or URL a second time overwrote the
  first filename with the second: the post said `02.jpg`, the disk said
  `12.jpg`, and the build reported the first as MISSING. Old archives do
  this all the time -- the same photo in the text and in a gallery hit 9
  posts of 1623 in one real import. The same source now gets its first
  filename back, in previews as well, so the preview's counts match what
  the real run writes.

- **A media download that fails with a status code now says so and, when
  the failure is temporary, retries.** Any unsuccessful HTTP status used
  to fall through silently as a missing file: no retry, no line saying
  why, media quietly absent at the end of an hours-long run. A 5xx or 429
  is now retried like a dropped connection always was; a 404 is reported
  once and accepted, because retrying a permanent answer only slows the
  run down. Same distinction the Wayback importer already draws.

- **The import preview stops counting media as if they had already
  arrived.** A preview downloads nothing, so its media number is what the
  run will go after -- one real archive promised 64 files of which the
  source had kept none. The preview now words it that way and adds, when
  media are involved at all, that only the real run can say how many
  actually arrive.

- **Page Up (and Home, End, Insert, Delete) used to leave a stray key
  behind in every menu.** Only the first character after the escape
  bracket was read, so the `~` that ends those sequences arrived a moment
  later as a keypress of its own -- in a menu that accepts typed text,
  that was a `~` in the box nobody typed. The whole sequence is read now,
  Page Up/Down and Home/End do what they say in the lists long enough to
  need them, and a modified arrow (Ctrl-Up and friends) reads as the plain
  arrow instead of as junk.

- **An Instagram HTML export requested in Czech now imports, instead of
  "importing" zero posts without a word of why.** The HTML reader knew
  English month names only, and any box whose printed date it did not
  recognize was quietly dropped -- so an export requested in the one
  language this project ships a locale for came out as a clean, silent
  zero. The timestamp reading now lives with the rest of the
  Meta-family HTML machinery (Czech and English tables, each verified
  against a real export); an unrecognized language is named in one
  line, a file none of whose posts could be dated says so out loud,
  and the English export the reader was built against still reads back
  identical -- all 288 posts, byte for byte, before and after.

  The profile lookup follows: the summary line's `@username` was found
  by the English row label only, so a localized export fell back to
  the directory's name. Both readers now try the labels MetaHtml knows
  -- and the JSON reader repairs the key before comparing, because a
  localized export mangles its keys exactly as it mangles its values.
  Label and mangling were both confirmed against a real Czech-requested
  export. A language the tables don't know still means the directory
  name, a fallback rather than a failure.

- **A Wayback rescue now says up front what it can and cannot recover.**
  Two things decide whether the hours a rescue takes are worth spending,
  and the preview reported neither, so both were discovered the hard way:
  whether that blog's feed carried whole posts or only teasers, and
  whether the crawler ever fetched its pictures. A real rescue promised
  sixty-four images and delivered none -- the Archive had kept
  forty-five pictures of that site across six years and every one was
  part of the page furniture.

  Truncated items are now counted and named. The test is where the item's
  last link POINTS, not what it says: a teaser ends with a link back to
  the post itself, which is the "read more" the blog appended where it
  cut the text off. Looking for the phrase would only work in the
  language it was written in, and the tempting shortcut -- "no
  content:encoded means summary" -- is wrong, because plenty of feeds
  carry the whole post in plain description. And one CDX query now asks
  what images the Archive holds of that host, reported by year: pictures
  from years missing there cannot arrive, whatever the posts reference.

  The help text was overclaiming to match. It said archived feed captures
  reassemble the history "images and all"; they reassemble as much of it
  as the Archive kept, which is the entire point of measuring first.

- **Footer headings only render over content.** An emptied social list
  (or one never filled in) left its heading -- "Find me on", pointing at
  nothing -- on every page, and the links and note columns had the same
  habit. Each footer block now appears only when it has something to
  show; the three-column layout keeps its shape either way. Found live
  on the first site configured wholly through the wizards.
- **The trash is keyed by year and slug, like the content it holds.** The
  same slug in two years is two posts -- backdating makes that ordinary --
  but the trash was keyed by slug alone, so deleting the older one wiped
  the newer one's trashed copy and its whole media directory. The undo for
  a deliberate delete, gone without a word. `restore` now offers both when
  both are there, and still finds a flat `trash/<slug>/` left by an older
  installation.
- **A re-import that moves a published post across a New Year keeps its
  address alive.** The move itself was handled -- JSON and media travel
  together -- but the redirect was not recorded, so every link to the post
  died. A source that starts reporting its dates in another timezone is
  enough to trigger it. Drafts record nothing, as they have no public
  address to keep.
- **The editor buffer is written atomically**, like every post is: it is
  the only copy of what was just typed, and a plain write that runs out of
  disk truncated the previous buffer to nothing. The notice that says the
  text is safe now checks the file has something in it rather than merely
  existing.
- **A save writes the post before pruning its media**, not after. The old
  order could leave a post naming files that were already deleted; this
  one can at worst leave a file nothing references, which the next save
  collects.

- **A video whose address the engine cannot play no longer injects markup
  into the page.** The "video unavailable" notice printed that address
  unescaped, in the post page, in every listing it appears in, and in the
  RSS feed -- and the address comes from an import or a hand-edited post,
  which is exactly the input that cannot be trusted. The audio notice next
  to it had been escaping it all along.
- **A pinned post's player works on the front page.** Each page asks its
  Content-Security-Policy for the players it carries, computed from the
  posts in that page's slice -- but the landing page also lifts the pinned
  post to the top, and once that post has aged onto `/page/2/` it is not
  in the slice. Its player was on the front page with nothing allowing it.
- **Editing a post no longer takes away a Funkwhale or Bandcamp player.**
  Their player address cannot be written in markdown, so the round-trip
  handed back a block without it and the re-lookup decided whether a
  working player survived -- offline, it did not. It is carried over from
  the stored post now, like a video's poster, and the lookup only runs for
  a block that has no player yet. A block still waiting for one also
  round-trips instead of being dropped: without that, such a post could
  not be edited at all until the service answered, which is the opposite
  of the "saving again retries" the message promises.
- **Enter in `./style.sh`'s banner section keeps the overlays as they
  are.** The two questions about painting the site's name and description
  over the banner were plain `[y/N]`, so pressing Enter -- which the
  wizard documents as keeping a value -- turned both off.

- **The queue screen and the properties dialog can no longer overwrite a
  post the cron published while you were deciding.** Both read the post,
  then wait at a prompt -- and the scheduled-publish cron runs every 15
  minutes. Writing that captured copy afterwards reverted the post to a
  draft, dropped the announcement URL (so `unpublish` could never delete
  the toot again), let the next deploy take the live page down, and let
  the next cron tick publish and announce it a second time. Renaming was
  worse still: the stale copy still looked like a draft, so no redirect
  was recorded and the address the post had been live at simply died. The
  staleness check now runs as the last instruction before each write
  rather than at the top of the dialog.
- **`./style.sh` no longer replaces your banner before you confirm.** The
  image was copied in the moment you typed its path, so answering "no" to
  the review printed "Nothing written" over a file that was already gone
  -- and the banner is a per-install file outside git with no backup. It
  is now installed only after the write is confirmed, and the dimensions
  written into the config are measured from the new file rather than the
  old one.
- **Secrets keep their permissions, and their backup keeps out of git.**
  Saving `env.sh` dropped it from 0600 to whatever the umask says, because
  the atomic write replaces the file and the mode was only set for a file
  that did not exist yet -- while the wizard printed "readable only by you
  (mode 600)" a few lines earlier. A stricter mode you chose yourself is
  now kept, anything wider is tightened. `*.bak` joined `.gitignore`: the
  wizards keep a backup of the file they rewrite, and for `env.sh` that
  copy holds the previous live tokens. And the mask over the review diff
  never matched a single line -- diff lines carry their newline and the
  pattern was anchored with `\z` -- so every token was printed in the
  clear in exactly the place the code promised it was hidden.
- **Notes are stripped outside fenced code only.** `//` opens a comment in
  half the languages anyone would paste into a ```js fence, and both
  strippers ran over the whole file: saving a post deleted those lines
  from the sample, and the `<!-- -->` one -- multiline and non-greedy --
  ate whole paragraphs between a note and the next `-->`. Editing such a
  post, changing nothing but its title, was enough.
- **`--only` no longer stands the deploy guards down for a backend that
  ignores it.** git pages force-pushes the entire build whatever it is
  handed, so a `--only` run there replaces the live site -- and
  `refresh-sidebar.sh` is exactly such a run, every half hour. Reproduced
  end to end: a build that lost its content went out unexamined and left
  a branch with no posts and nothing to restore from.

- **A busy Wayback Machine no longer reads as a blog that was never
  archived.** Every query to the Archive ran inside a rescue that turned
  any failure into "nothing here", and the Archive rate-limits precisely
  the traffic a rescue makes -- a dozen queries in a row from one
  client. A run that met a 503 therefore announced `No feed captures,
  and no way to tell posts from listings`, followed by an empty list of
  sample paths to build a `POST_PATTERN` from, because that query had
  failed too: a transport hiccup stated as a fact about the blog, and
  the one hint for working around it missing. The feed was in the
  Archive the whole time.

  Requests now wait a busy Archive out -- four attempts, fifteen seconds
  longer between each -- and that covers everything the rescue fetches,
  captures and images included, not just the index queries. An
  unanswered query is kept apart from one that came back empty: only the
  second is a fact about the blog, and a run that cannot tell which it
  got now says so and stops, rather than falling through to page mode
  and blaming the site. Queries still unanswered after the retries are
  named in the summary, so a rescue that quietly missed part of a blog
  says which part. And when the Archive genuinely kept no post pages,
  that is now its own sentence instead of a request for a pattern with
  nothing to build one from.

- **The menu no longer runs under the search box.** A site using every
  content type has nine items in the bar, and nine did not fit: measured
  against the 908px a 940px page leaves, the three shipped locales came
  out at 906 (English), 927 (Czech) and 899 (German) -- so Czech
  overflowed outright and the other two had single-digit slack, which is
  why it collided anyway. Between the mobile breakpoint and the full
  width every locale overflowed. The bar now sizes itself: the menu may
  wrap to a second row, the search box never shrinks or gets overlapped
  (and is 160px rather than 225px), and the gap between items is 1.25rem
  rather than 1.875rem -- 80px recovered without shortening any label.
  Czech now has 126px of slack where it had -19.
- **A post moved to another year keeps its old link working.** Editing a
  post's date across a New Year moves its address from
  `/posts/2019/slug/` to `/posts/2020/slug/`; the redirect a rename would
  have left behind was never recorded, so the old link simply died. It is
  recorded now, and the redirect stub the build already knew how to emit
  appears at the old address.
- **The preview server answers byte ranges.** It replied 200 to a Range
  request, which Safari treats as "this server cannot stream" -- it
  refuses to play the media element at all -- and which breaks seeking in
  a video or audio post everywhere else. It now answers 206 (and 416 past
  the end of the file), and streams instead of reading whole files into
  memory.
- **The preview server knows every file type a post can carry.** Audio,
  `.m4v` and all nine attachment extensions were served as
  `application/octet-stream`, so a browser downloaded what the deployed
  site plays or displays -- the preview disagreed with the real site
  about what the page does.
- **A video is no longer mistaken for a photo.** The HEIC detector
  matched brands that mean an HEVC image *sequence*, which a video file
  can carry in its header too -- and the converter would have answered
  with a single frame and called it the file. Detection now looks for the
  box that decides it: a movie box means a movie, whatever the brand says.
- **Photos taken sideways get the size they are shown at.** Dimensions
  came from the frame header and ignored the EXIF orientation every
  browser obeys, so a portrait phone photo reserved a landscape box and
  the page jumped exactly where the reservation was meant to stop it.
- **A feed URL that 404s says so.** It came out as a raw backtrace; only
  malformed XML had been given a one-line message.
- **XML that isn't a feed says so too**, instead of "Done. 0 post(s)" and
  exit 0 -- which is what an author saw after pasting a page URL instead
  of its feed URL, and reads as success.
- **A plain draft shows no date in listings and pickers**, the rule the
  properties dialog already follows: a draft's time is set by publishing
  or scheduling, so the timestamp in its file describes bookkeeping, not
  the post.
- **A `banner.claim` that is only markup no longer greets you with a lone
  middle dot** in the CLI header.
- The markdown cheat sheet names the video extensions (.mp4, .mov, .m4v),
  as the audio and attachment sections already did.
- **Editing a post no longer drops a video's poster image.** Markdown has
  no way to write one down, so re-parsing an edited post handed back a
  video block without it, and the safeguard that catches content loss
  didn't notice: it counts block types, and a video that stays a video
  looks untouched. The poster is now carried over from the post as it was,
  matched on the one thing the markdown still names -- the video's file, or
  its URL for an embedded one. Nothing renders a poster today, so no page
  changed; what changed is that the reference is still in the JSON when
  something does. (52 imported videos on sean.cz carry one.)
- **A size is never rounded up into the limit it is under.** 99,999,999
  bytes printed as "100 MB", so an allowed file and a refused one read
  identically, and the warning contradicted itself out loud: "(100 MB) --
  under the 100 MB limit". Sizes now round down, which also means a
  printed size is never larger than the file.
- **The "deploy failed" line no longer advises a retry that cannot work.**
  It said to just run the deploy again -- but when a guard stopped the
  upload, an unchanged re-run stops the same way, every time. It now says
  to read the reason above first, and distinguishes a transfer that broke
  off from a guard waiting to be answered.

- **A consistency pass over everything the interface says, in all three
  languages.** Czech counts now read correctly for every number
  ("Publikačních slotů: 4", not "4 publikačních slotů"), Czech quotes
  close typographically („…“), four import prompts stop addressing the
  author formally, dashes follow each file's convention, the public
  pages call posts "příspěvky" consistently, quick-pick menu hints show
  the real row range instead of a fixed 1-9 (and the section menus of
  ./setup.sh and ./style.sh finally admit digits work), `./blog.sh list`
  has a help line, the draft-preview banner keeps one exclamation mark
  instead of three, and English spelling settles on Favourited.
  The wizard's six menu entries lead with the thing rather than the verb
  ("The archive -- filters, search, preview"), the hints under them stop
  offering to type a slug at menus that ignore letters and the top-level
  one says Esc leaves the program rather than goes back, Czech settles on
  one word for building a site where it had three, its yes/no prompts
  read [a/N], its notes under an import preview stop saying the count
  twice, and `config/site.yml.example` explains what the `rel: "me"` key
  on a social link is for.

- **Three last ways bold and italic could corrupt each other, found by
  widening the round-trip net from 150 span combinations to all 1,085
  assignments -- permutations and repeated types included -- and
  verified against every post of a 4,400-post production site.**
  - **The same formatting twice over overlapping words came back as
    garbage.** Markdown has no way to say "bold inside bold" -- the
    delimiters cancel into `****` at the junction -- so imported
    formatting that stacked a span on itself published stray asterisks.
    The writer now folds same-type overlaps into the one span they mean;
    two links pointing different ways instead split at the boundary,
    which markdown can say.
  - **An italic wrapped around a complete bold (or strikethrough, or
    link) ended at the bold's first star.** `*ab~~c**de**f~~ghij*` closed
    the italic against the opener of `**de**` -- half the paragraph fell
    out of the span and delimiters surfaced as text. An italic's closer
    now refuses a star that touches other stars, which is the CommonMark
    reading: that star is the bold's opener, not the italic's closer.
  - **An italic ending exactly where a bold begins read as neither.**
    `*kurzívou***tučně**` -- the mirror of the `**tučně***kurzívou*`
    adjacency 1.2 already handles -- splits its middle run one-plus-two
    now, and chains (`**a***b***c**`) resolve link by link. The
    head-collision shapes also stopped stealing closers from spans
    further right: their rest halves may hold complete nested runs, but
    never a lone star.
- **An imported archive cannot put markup on your site.** A media file's
  name is chosen by whoever wrote the archive, and an extension is only
  "everything after the last dot" -- so a file named with a quote and an
  angle bracket closed the `src="..."` it was written into and opened a
  tag of its own, on the author's own domain, where the site's own
  Content-Security-Policy trusts it. The attribute beside it had been
  escaped all along; this one was not. Media addresses are escaped now
  wherever they are written (the image, the video, the audio, the
  download card, `og:image` and the JSON-LD), and an extension that could
  not be a file type is stored as `.bin` instead. Extensions that were
  already harmless are kept exactly as they were, because renaming media
  is what breaks a re-import.
- **A media name is a name, not a path.** One carrying `../` pointed the
  page outside the post's own directory and, during the build, wrote
  there too -- somewhere `--prune` could never clean up again. Both ends
  take the basename now.
- **A post cannot forge an entry in your feed.** The rendered post goes
  into RSS inside CDATA, and CDATA has exactly one way to end: a post
  carrying `]]>` -- which an imported `embed_html` can, since it is
  stored verbatim -- closed the section early, and everything after it
  was read as feed markup. A reader could be handed a headline and a link
  of the post's choosing, in an item that still parsed. The sequence is
  split across two sections now, the standard way, and survives as text.
- **A failed announcement deletion no longer loses the announcement.**
  `unpublish` dropped the toot's address whether or not the delete had
  worked, so an expired token left the announcement hanging in public
  with nothing pointing at it -- no retry, no record, and publishing
  again simply added a second one alongside the first. The address is
  kept when the deletion fails, and the run says so.
- **A scheduled post whose announcement fails says so.** Announcing
  answered the same "nothing" whether there had been nothing to send or
  the send had failed, so the publishing cron treated an expired token
  like a site with no comment network: it published the post, exited 0,
  and left no trace that an announcement was ever owed. Nothing retried
  it and nobody found out. The two are told apart now -- the post still
  publishes, but the run counts a failure, exits non-zero so cron mails
  you, and names the post that is public with nothing pointing at it.
- **A moved post keeps its own pictures.** Editing a post's date across a
  year boundary moves its media directory, and a directory already
  standing at the destination -- what a deleted post leaves behind -- made
  the move skip every file whose name was taken. Since names are per post
  (`01.jpg` is `01.jpg` in all of them), the post then served the orphan's
  bytes under its own filename while its real file stayed in the old year.
  The arriving file wins now; whatever was in its way is moved aside
  rather than destroyed, and named so it can be found.
- **Publishing again after a re-import redirects the old address.** An
  unpublished post carries the address it vacated, and publishing spends
  that marker to build the redirect. A re-import publishes without going
  through publishing -- the export simply says the post is public -- so
  the marker was never spent, and after unpublish, rename and re-import
  the old address 404'd with the note to redirect it sitting unread in
  the post's own file.
- **`doctor` says whether anything is actually publishing the queue.** A
  scheduled post that never goes out looks, from inside, exactly like one
  whose time has not come: the post sits there, nothing is wrong with it,
  and nothing anywhere says that no cron has run in three days. The
  scheduled-publish run now leaves a heartbeat on every tick -- including
  the ones with nothing due, which are almost all of them and the only
  proof that anything is running at all -- and `doctor` reads it. It says
  nothing on a site that schedules nothing, notes a queue that is waiting
  on a runner nobody set up, and calls it an error when a post is already
  late and nothing has run. The fix line names the schedule to add and
  reminds you to check that its path points at this blog rather than
  another one on the same machine.
- **Deleting a post takes its announcement down with it.** `unpublish`
  has always tidied up after itself on Mastodon and Bluesky; `delete`
  never did, so the toot stayed public and pointed at a 404 the moment
  the next build pruned the page -- with nothing anywhere saying so. Both
  go through the same retraction now. The confirmation says what is about
  to happen before you type the slug, because the post can be restored
  from trash and the thread under the announcement cannot; and the copy
  that goes to trash forgets an address that is gone, so a restored post
  can be announced again rather than refusing on the strength of one that
  no longer exists.
- **One post cannot be announced twice.** An announcement can reach the
  network and be accepted while the reply never makes it back, and the
  engine then stores nothing: as far as the post's file knows, it was
  never announced. `./blog.sh toot` and `./blog.sh bluesky` exist for
  exactly that situation -- and read the missing address as "nothing was
  sent", so they sent a second one. Bluesky is asked first now whether
  the announcement is already on the account, and if it is, its address
  is recorded rather than another posted. A toot carries an
  idempotency key derived from the post, which is what Mastodon's API
  offers for this: a repeat comes back as the status that already exists.
- **A Bluesky announcement that ends in a link is clickable again.** The
  ellipsis the engine adds when it shortens a preview was swallowed into
  the address, so the link in the announcement pointed at a page that did
  not exist. Every other closing mark was already kept out; this one
  arrives from the engine rather than the author, which is how it was
  missed.
- **A long title and a pile of tags cannot silence an announcement.**
  Together they can fill Bluesky's 300 graphemes on their own, leaving
  the preview nothing to give up -- and Bluesky then refuses the whole
  record, so the post went out announced by nothing. The title is
  shortened first, then tags are dropped from the end; the address is
  never touched, and no tag is ever cut in half.
- **`./blog.sh list` down a pipe is only posts.** The tally under it went
  to the same place as the rows, so `| wc -l` answered three more than
  there are posts. It goes to the terminal when there is one, and out of
  the way when the output is being read by something else.
- **A wizard's yes key comes from the language it is speaking.** It was a
  list of three letters written by hand, so a fourth translation -- which
  the localization guide invites -- would have had the wizard refuse the
  answer it had just offered, and throw away the whole run.
- **A publish the lock arrived in the middle of finishes itself.**
  `./blog.sh publish` announces the post before it builds the site, so a
  build that did not run left the announcement pointing at a page nobody
  would ever upload. It can happen without anything being wrong: the
  sidebar cron holds the lock for as long as its network fetches take,
  and a widget host that does not answer stretches that to half a minute.
  Two things were missing. A skipped build looked exactly like a broken
  one -- same exit code, same red message telling you to go find an error
  that was not there. And the marker that makes the next scheduled run
  pick the site back up was only ever written by the cron, never by the
  hand. A busy lock now says it is a collision and not a fault, and every
  path that can leave the site owing a deploy leaves the same marker, so
  the next run finishes it.
- **`doctor --online` checks a Bluesky app password.** It reported
  "Announcing as <handle>" from the config alone, under a heading that
  promises the tokens were checked too, so a revoked app password read as
  healthy right up until announcements quietly stopped. It now opens a
  session against the same endpoint the announcement itself uses, and a
  refusal is an error rather than a note. Mastodon has had this check all
  along.
- **An import interrupted mid-copy no longer publishes half a photo.**
  Media was copied straight to its destination, and "skip what already
  exists" -- the rule that makes re-importing safe -- then skipped the
  truncated file forever. Ctrl-C, a full disk or a container going away
  was enough. Files are copied beside their destination and renamed into
  place, so the only file under the real name is a complete one.
- **A markdown tree with pictures in it imports at all.** An image
  sitting inside a line of text is something a post cannot show, and
  saving one stops with a message pointing at the line -- which is right
  when you wrote that line, and wrong when it came out of somebody else's
  site. One such paragraph ended the entire run. A real Hugo export of 77
  posts had 23 of them across 11 files: none of the 77 imported, and the
  message named a line the person running the import had never written.
  None of the shapes were exotic -- every WordPress-to-Hugo conversion
  writes `![](photo.png)*caption*`, every README puts badges in a list,
  screenshots end sentences. They are rearranged now the way a person
  would rearrange them: the picture moves onto a line of its own and the
  caption follows it; an image that was only a link's decoration gives
  the link back, keeping its text; a thumbnail with nothing to say keeps
  the picture instead. The run reports how many it moved, because an
  import may transform an archive but not quietly.
- **A Medium export imports at all.** Every published post was skipped as
  "no id to tell which post it is". The adapter read the canonical
  address with a pattern that required the anchor's `class` attribute
  before its `href` -- and Medium's exports write them the other way
  round, so the address came back empty and the post lost the id that
  names it. Drafts were unaffected, because their id is read from the
  file name, which is exactly why an export could look like it half
  worked. The anchor is now found first and its address read second, so
  neither order matters.
- **A site with no deploy target says so, instead of naming one you
  declined.** Answer "nowhere yet" in `./setup.sh` and the very first
  post reported that the Surfer backend was not configured -- a product
  that install had never heard of. An unset backend resolves to Surfer
  for compatibility, and the build had no notion of the difference
  between "not chosen" and "chosen but unconfigured". `doctor` has drawn
  that line all along; now they agree.
- **The import summary is in your language again, all of it.** Eleven of
  the reasons a source can give for skipping something were printed as
  their internal English names in the middle of a Czech or German
  summary -- `crosspost`, `checkin`, `no_content`, `retweet`, `thread`,
  `missing_html`, `bad_frontmatter`, `no_identity`, `no_audio`,
  `media_unfetchable` and `unparsed`. Every source added in this release
  brought its own vocabulary, and the list of translated reasons stayed
  where the first four sources had left it. It showed worst on a
  Facebook export, where the skipped crossposts are usually the largest
  number in the run: three of the four lines read in English, one line
  above a translated sentence reporting the same count. The engine's
  own reasons are all translated now, and a test walks every adapter and
  fails if a new one arrives without wording in all three languages.
- **`doctor` on a config file it cannot read says so.** A `site.yml`
  owned by root after a wizard ran under sudo -- exactly the install
  that needs diagnosing -- crashed the diagnosis with a raw Psych
  backtrace before the first finding. It is now finding number one, with
  the `chmod`/`chown` to run, and the rest of the checkup still happens.

- **Every source was put through a real export from the platform it
  claims to read, and forty-three defects came out.** The tests until
  then were written from the adapters: they proved the code did what it
  said, not that it understood what a platform actually hands you. Run
  against the fixtures the migration tools ship, public exports, live
  podcast feeds and this blog's own WordPress archive, most sources lost
  something -- and the losses were quiet, which is why a green suite had
  not found them.
  - **WordPress filed unpublished posts under the year -1.** The export
    dates a post it never published `Wed, 30 Nov -0001`, which parses
    without complaint and returns a year that has no business being a
    directory name: on a 46-post archive, 11 drafts landed in
    `content/posts/-1/`. `wp:post_date`, the one field that holds the day
    such a post was written, was never read at all. Dates are now checked
    for a plausible year and `wp:post_date` is the last resort -- which
    also catches the Squarespace export that supplied the year 146140482.
  - **A password-protected WordPress post was published in full.** Its
    status is `publish`; WordPress holds the body back until the password
    is typed, and this engine has no such gate. Deliberately closed posts
    went straight onto the open web -- one in each of WordPress's own test
    exports, 17 in their large one. They arrive as drafts now: the text is
    kept, the decision is yours.
  - **The classic WordPress editor's shortcodes were published as
    text.** `[caption]`, `[gallery]`, `[audio]` are markup only WordPress
    expands, so a captioned photo arrived as three blocks -- a paragraph
    reading `[caption id="attachment_906" …]`, the picture, and the
    caption with `[/caption]` still on it. 119 posts of a 969-post export
    carried one. Captions now attach to their picture; the shortcodes
    that have nothing to render are removed rather than printed.
  - **A WordPress post's featured image was lost entirely.** It is not
    part of the body -- the theme paints it from a `_thumbnail_id`
    pointing at an attachment elsewhere in the file, and attachments were
    skipped without being read. Half the posts in a large export lost the
    only picture they had. It now leads the post, registered after the
    body's own images so no existing filename shifts.
  - **A Blogger backup arrived gutted.** A captioned image is a
    `<table class="tr-caption-container">`, and table cells drop pictures:
    the photo vanished and a one-column table holding its caption stood in
    its place. Worse, a classic Blogger body has no paragraphs at all --
    flat text, `<a>`, `<span>` and `<br>` -- and the reader made a block
    per fragment, losing the address of every link on the way: 29 links
    down to 8 in one post, and one post split into 105 blocks. Consecutive
    inline pieces are now gathered into the paragraph they always were,
    with `<br>` ending the line the way the markup means it to. Every
    HTML source shares that reader, so every one of them reads run-on
    bodies better -- this blog's own Posterous-era footers came out as
    "Shot with:", "Camera+", "for iPhone" on three lines and now read as
    the sentence they are.
  - **A picture inside a blockquote disappeared, and a quote holding
    nothing else disappeared with it.** Paragraphs and figures had always
    collected their images; quotes were simply forgotten.
  - **Re-importing a podcast wrote the whole show a second time.**
    Buzzsprout and Simplecast declare a redundant namespace on one
    `<atom:link>`, and from that element on, the channel's own `<link>`
    became invisible to the reader -- so the feed had no identity, and
    without one nothing matches what is already on disk. The second run
    duplicated every episode and re-downloaded the audio to do it, which
    for a podcast is gigabytes. The whole feed family reads addresses
    correctly now.
  - **A video podcast was imported as sound.** Video shows use the same
    `<enclosure>` element, so every episode was stamped audio: an mp4
    inside an `<audio>` tag plays but never shows a picture, and the post
    filed itself under the wrong type in the archive.
  - **Medium dropped published posts on the floor.** When the canonical
    address carries no slug (`medium.com/@you/1234567890`) the post had no
    identity and was skipped -- a published article, gone, with nothing in
    the summary to say it had ever been there. Its tags were looked for in
    a `<div>` when real exports write a `<p>`, so every tag was lost
    silently, and code blocks came back as one welded line with the
    markup's indentation still attached.
  - **A Substack import could finish having written nothing.** `posts.csv`
    was read without naming its encoding, so under cron -- where the
    language settings are unset -- the run died on the first accented
    character. Paid posts were imported with no mark of any kind: they now
    carry a `substack-paid` tag and a line in the summary, so you find
    them before you publish them.
  - **Movable Type dated posts by the day of the import.** The time in a
    `DATE` line is only optionally followed by AM/PM, and a line without
    it was unreadable -- the post was filed under the current year and the
    run reported it as written. That is now a named skip, so the export can
    be fixed and run again. `TAGS`, the main taxonomy since MT 3.3, was
    ignored, and a body written in markdown was fed to the HTML reader
    with its own syntax published as prose.
  - **A Tumblr reblog was published as your own writing.** The trail of
    the post being reblogged was appended with no attribution at all.
    Each part now carries the blog it came from, as a link.
  - **A LiveJournal import collapsed every old entry into one
    paragraph.** The protocol is asked for CRLF line endings, and the
    paragraph split looked for two newlines side by side, which CRLF never
    has. Its retry was worse than useless: it tested the error text for
    "406", a number LiveJournal never puts there, so the first fault of any
    kind ended the import -- and 406 is the one fault that must not be
    retried, since it means the same request has already been sent twice.
  - **A markdown tree gave up its reference links and its line breaks.**
    Reference-style links (`[text][ref]`) are markdown this engine does not
    speak and arrived as visible brackets; a list whose items kramdown had
    wrapped at 120 characters lost every wrapped line; `{% raw %}` blocks
    had their contents stripped as though they were Liquid. A tree with no
    `_posts/` directory swept in the repository's readme, its templates and
    a second copy of the whole site from `_site/`.
  - **Wix threw away quotes, code and anything it did not recognise.**
    Blockquote and code blocks were unknown to the reader although this
    engine has both natively, and an unrecognised node was dropped whole
    even when it was only a container: a collapsible list holds ordinary
    paragraphs one level down, and all of them went with it. A button whose
    link had no scheme -- `www.example.com`, which Wix stores routinely --
    lost its label too.
  - **A beehiiv import brought the email with it.** The unsubscribe
    footer, six social icons as image blocks, "Sign up here" and the ad
    slot were all imported as post content, and a poll arrived as a heading
    with its answers as links back to beehiiv to vote. Paid editions were
    imported with no mark, exactly as Substack's were.
  - **Bluesky lost photo carousels and quoted feeds.** A gallery of up to
    twenty pictures fell through the reader unrecognised -- every image
    gone without a trace, and a picture-only post skipped as empty -- and a
    post sharing your own feed, list or starter pack was discarded as a
    quote of somebody else's writing.

- **One unescaped `&` in an export no longer costs the whole archive.**
  Blog exports are printed by templating engines, not written by XML
  writers: WordPress puts a raw query string in an element
  (`?ixlib=rb-1.2.1&ixid=eyJ&w=1268`) and Squarespace prints a bare `&` in
  a title. A conforming parser refuses such a file outright, so a single
  character in one item of a thousand ended the run before anything was
  written -- 4 of the 12 fixtures that Ghost's own migration tools ship
  are refused this way, while Ghost's parser reads them. A file that fails
  to parse now gets one more attempt with the characters that had to be
  escaped escaped, and the summary says how many there were. Control
  characters XML forbids are dropped the same way, and named for the same
  reason.

  What this deliberately does not do is guess. Nothing structural is
  repaired: a missing end tag or a download that stopped halfway still
  ends the run, because inventing where a tag was meant to close invents
  an archive rather than rescuing one. When the patched copy still will
  not parse, the refusal names the defect that SURVIVED rather than the
  ampersand the engine has just proved it can handle -- a truncated
  export used to complain about a query string and send the author looking
  for the wrong thing. A file that is repaired and then turns out to be an
  HTML error page is refused as not being a feed, with no mention of the
  repair nobody benefited from.

  Two guarantees are worth stating because getting either wrong is worse
  than the defect. **Post bodies are not touched.** They live inside
  CDATA, where `&` is already an ordinary character, so a substitution
  across the whole file would turn every `href="?a=1&b=2"` in every post
  into a visible `&amp;` -- silently, because the file parses afterwards.
  CDATA, comments, processing instructions and the DOCTYPE are found
  first, by their own markers, and copied through untouched. **And a file
  that is not UTF-8 is refused rather than read.** An export in UTF-16 is
  ASCII text with a NUL between every character, which passes as valid
  UTF-8; stripping those NULs would quietly transcode the document, and it
  would then parse, which is exactly what would have made it dangerous. A
  declaration naming some other encoding is left alone for the same
  reason: the parser reads such a file correctly BY that declaration, and
  patching its bytes as UTF-8 would turn a loud refusal into a quiet
  import of mangled text.

  An export that parses today is not read, scanned or rewritten by any of
  this -- the second attempt only happens after the first has already
  failed -- so nothing about an import that works can change because of
  it, and it costs such a file nothing. Verified over 48 files: 17 that
  ended the run now import, everything that was already readable comes out
  byte for byte identical, and everything genuinely broken still stops
  with the same one-line refusal.

- **Six more the real exports found, and one place the docs were wrong.**
  - **A WordPress custom post type vanished into the menu items.** A blog
    with a portfolio, a recipe section or book reviews keeps those in
    their own post type -- with a title, a body and categories like any
    post -- and every one of them was counted under the same
    `not a post` as the navigation menu. In an export where the menu
    contributes four figures, a line reading `1234 skipped (not a post)`
    hides forty articles inside itself, and the documentation told the
    reader that number was normal. Each type is now named after itself
    (`wp:portfolio`), so the summary says what stayed behind. The name is
    namespaced because a section called `quote` or `comment` would
    otherwise have been printed as this engine's own wording for
    something else entirely.
  - **A Wix export lost every post to one stray quote.** A CSV that has
    been through Excel or Numbers holds cells like `He said "hi" to me`,
    and the strict parser stops at the first one -- reported, on top of
    that, as the source having stopped answering, when the file was on
    disk all along. The file is now read leniently. A row that slid out
    of line as a result (a damaged cell containing a comma shifts every
    column after it) is skipped by name rather than imported with
    somebody else's body under the wrong date.
  - **A code sample with two Liquid arguments came out as prose.**
    `{% highlight ruby linenos %}` is the form Jekyll's own documentation
    teaches, and only the single-argument spelling was recognized -- so
    the block fell through to the blanket Liquid strip and arrived with
    its indentation gone and its line breaks turned into spaces.
  - **A Medium post published without a timestamp was dated the day of
    the import.** Medium leaves the publication time out of some exported
    posts, and the file name carries it (`2018-08-11_slug-hash.html`); it
    is read from there now rather than from the file's own mtime, which
    is when the ZIP was unpacked. The post used to sit at the top of the
    new blog, years out of place.
  - **A LiveJournal mention linked to somebody else's journal.** An
    underscore cannot appear in a hostname and LiveJournal spells it as a
    hyphen; this dropped it instead, so `<lj user="james_nicoll">` pointed
    at `jamesnicoll.livejournal.com` -- a journal that exists and belongs
    to another person.
  - **Bluesky tags written outside the post text were thrown away.** The
    lexicon keeps hashtags in two places, and only the facets were read,
    so a post whose tags a client had put in the record's own `tags`
    array arrived with no classification at all.
  - **A beehiiv issue was dated by the machine that imported it.** The
    export's only timestamp carries no timezone, so it was read in the
    site's own -- and the same file landed on a different instant
    depending on where the import ran: an hour out in Prague, thirteen in
    Auckland. For an issue written near midnight that is a different day,
    and since the year is part of a post's address, at the turn of the
    year a different URL. It is read as UTC now, the way every other
    naive timestamp in the engine already is.
  - **The documentation promised Tumblr drafts that no API key can
    reach.** Drafts, the queue and private posts sit behind endpoints
    that want a full OAuth handshake; the import gets the published
    posts. Said plainly now, in the README and the guide.

### Upgrading

- **Nothing to migrate.** `git pull`, rebuild, deploy. Verified against a
  1.1 installation whose config was left exactly as it was: the same site
  comes out, page for page, with no warnings -- every new config section
  (`fonts`, palettes, the wizards) is optional, and `doctor` runs on a 1.1
  config without complaining about their absence.
- **Going back builds, but it is not free**, which is worth knowing
  before you tag. The 1.1 engine reads everything 1.2 has written without
  choking: no build fails, no post is dropped, `former_slugs` redirects
  still come out byte for byte, and fields 1.1 has no notion of are
  ignored rather than fatal. What it cannot do is render what it never
  knew about, and three of those are worth naming.
  - **Audio posts lose the recording's address, not just its player.**
    1.2 renders a player for bandcamp, spotify, soundcloud, mixcloud,
    funkwhale and archive.org, and where it cannot it at least prints the
    link. 1.1 has neither branch, so the page and the feed item both come
    out as a bare "[audio unavailable]" with nothing to click. Video does
    not do this -- 1.1 keeps the address there -- which makes audio the
    one block type where going back loses something a reader could have
    followed.
  - **Comment threads go quiet on posts announced somewhere other than
    the network your config names now.** 1.2 opens `connect-src` per post,
    from the address each post was actually announced at; 1.1 builds it
    from the configured network alone. The thread stays in the markup and
    the browser silently refuses to fetch it. This bites hardest if you
    have ever switched instances or moved between Mastodon and Bluesky.
  - **Editing a 1.2-written post under 1.1 can lose text.** Rebuilding is
    safe; re-saving is not. 1.1 does not escape a `|` inside a table cell
    (everything after it is dropped), a `"` in a link title (the link is
    destroyed and its raw markdown published as body text), or `*` inside
    inline code (a backslash appears, and multiplies with every further
    edit), and it truncates a link address containing brackets. If you
    roll back, treat the archive as read-only until you come forward
    again.
  These are 1.1 behaving like 1.1; nothing about 1.2 has to be undone
  first. Coming back forward re-renders every one of them correctly.
- **Two more working files** sit next to the ones from 1.1:
  `.last-edit.meta` (which command wrote the editor buffer) and
  `.blog-sh.lock` (the build/deploy lock below). Both are gitignored, and
  neither needs backing up. `*.bak` is gitignored now as well -- the
  wizards keep a backup of the file they rewrite, and for `env.sh` that
  copy holds your previous tokens.
- **Builds and deploys now take a lock**, so the publishing cron, the
  sidebar cron and a person at the CLI cannot walk into each other's
  half-written `public.nosync`. A run that finds the lock held does not
  queue: a cron tick says so and leaves (exit 0, no mail), a run you
  started reports it and exits non-zero rather than let its caller think
  a deploy happened. On a filesystem that cannot lock, everything behaves
  exactly as it did before.
- **The wizard menu grew to six entries** with the queue screen, and its
  fourth entry is now the archive browser rather than the flat listing, so
  a scripted `printf "N\n" | ./blog.sh` may select a different one than in
  1.1. The CLI commands are the stable interface; `./blog.sh queue` and
  `./blog.sh list` are the ones to pipe.
- **The import wizard's source menu is two levels now** (blogs / social
  networks / dead sites), so the same caveat applies to
  `printf "N\n" | ./import.sh`. The non-interactive path is unchanged: a
  piped run still gets one flat numbered list, and `migrate_*.rb` scripts
  are unaffected.
- **Media numbering changed for posts with failed downloads.** 1.1 gave a
  failed fetch's number to the next image; 1.2 leaves it spent, so
  filenames depend only on the order a post references its media, never
  on which downloads happened to succeed. Re-importing over a tree the
  1.1 importer wrote is therefore the one upgrade path with a caveat: if
  a post reported failed media back then, its numbering shifts, and the
  copy step's "skip files that already exist" can leave such a post
  showing the neighbouring image. Before re-importing those posts --
  the 1.1 run's summary named them -- delete their media directories, or
  import into a fresh tree. Trees both written and re-imported by the
  same engine version are unaffected either way.

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
