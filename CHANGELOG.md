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

### New

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
  own text showing why it matched; `p` opens the whole post read-only
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

### Fixes

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

### Upgrading

- **Nothing to migrate.** `git pull`, rebuild, deploy. Verified against a
  1.1 installation whose config was left exactly as it was: the same site
  comes out, page for page, with no warnings -- every new config section
  (`fonts`, palettes, the wizards) is optional, and `doctor` runs on a 1.1
  config without complaining about their absence.
- **Going back works too**, which is worth knowing before you tag: the 1.1
  engine builds posts that 1.2 has written since. `former_slugs`
  redirects still come out, and the fields 1.1 has no notion of
  (`redirect_from`, a resolved `embed_src`) are ignored rather than fatal
  -- the only difference is that the redirect stubs `redirect_from` would
  have produced are not emitted, because that feature does not exist
  there.
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
