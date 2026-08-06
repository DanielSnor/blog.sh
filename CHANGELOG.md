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

### New

- **`./setup.sh` -- setting a site up is now a conversation.** The
  documented path was to copy two files and edit 277 lines of commented
  YAML; this asks instead, and checks every answer as it arrives. The
  timezone is offered from the machine's own zone database and rejected
  if it isn't one -- the setting whose typo would otherwise silently date
  every post two hours off. The address is checked for shape and written
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

- **`./style.sh` -- the appearance half, and four palettes to pick
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
  light homepages. Add your own by adding an entry to that file: the
  wizard lists whatever is in it, and a palette you add needs no
  translation to appear.

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

## 1.2 -- unreleased

### New

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
  the social-network roster. The JSON export's shape is Meta's oddest
  yet -- every post is a media list even when there is no media, with
  the text riding in a title field -- and it is read as found: your
  standalone posts import with media from the archive, replies to
  other people's threads are skipped and counted (the Bluesky rule),
  bare URLs become real links, and the shared MetaText repair fixes
  the encoding. The export's cross_post_source flag is deliberately
  NOT a skip signal: on real exports it marks posts written directly
  in the Threads app too -- it records where a post was shared TO,
  and skipping on it would empty the archive.

- **Facebook joined the import sources** -- the twenty-first, built and
  verified against a real "Download Your Information" JSON export. Your
  own posts import with photos and videos from the archive itself; the
  headline behaviour is what does NOT import silently: posts Facebook
  mirrored in from Twitter, Posterous and their era -- on the reference
  export, 95 % of everything -- are recognized and skipped with a
  count, because those platforms' own imports carry the originals
  (`FACEBOOK_CROSSPOSTS=1` includes them). Wordless check-ins and app
  stories are counted skips too. Meta's byte-mangled text encoding is
  repaired by the same logic the Instagram importer proved out, now in
  a shared module for the whole Meta family.

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
  them.

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

### Changed

- The "what next?" menu after a save reads in flow order --
  `[d] keep as draft  [e] edit  [p] publish  [s] schedule  [x] delete` --
  the states a post moves through, rather than most-frequent-first. The
  keys are unchanged.

### New

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

### Fixes

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
