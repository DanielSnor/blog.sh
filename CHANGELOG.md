# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.

## 1.2.1 -- unreleased

### New

- **The site's own chrome speaks Markdown.** `about.html`,
  `footer.note_html`, `footer.copyright` and `banner.claim` were the only
  texts on a Markdown blog that had to be written in HTML -- the field that
  introduces the author wanted a hand-typed `<a href>` for a link. All four
  go through the same parser the posts use now: links, bold, italics,
  strikethrough and inline code, and in the two longer fields also lists,
  quotes, code blocks, rules and as many paragraphs as you like. **Nothing
  to migrate:** raw HTML still passes through untouched, so existing configs
  render exactly as they did, `&copy;` is still a ©, and an `<img>` is still
  how a photo gets into a bio. Images, video, audio and attachments are the
  one thing Markdown does *not* get here -- they resolve filenames against a
  post's media directory, which the sidebar and the footer do not have.
- **A photo no longer publishes the place it was taken.** A phone writes
  coordinates into every picture it takes, the engine copied media byte for
  byte, and nothing in it had ever looked at metadata -- so a snapshot from a
  back garden put the back garden on the open web. Social networks strip this
  on upload and their users have long since stopped thinking about it; a
  static site has nobody to do it for them. New photos are cleaned on the way
  into the archive, on the copy and never on your own file, which covers
  authoring and all twenty-two importers alike, since they share one write.
  Only the location goes: the camera, the lens and the moment the shutter
  opened are your own record of your own photograph, and the Orientation tag
  stays, which is what keeps a portrait photo standing up -- turning one back
  the right way round needs an image decoder this engine deliberately does
  not have. `media.strip_location: false` keeps the coordinates for a site
  that wants them, such as a walking diary. Photos already published are left
  alone: `./blog.sh doctor` counts them and `./blog.sh doctor
  --strip-location` cleans them when asked -- the only thing doctor has ever
  written, which is why it has to be named. **Known gaps**, written down
  rather than guessed at: JPEG only, which is what phones produce and what a
  converted HEIC arrives as, so Exif in a PNG or a WebP is left alone, as is
  a second copy of the coordinates in an XMP packet. A GPS block holding
  nothing but its own version number is not counted as a location and not
  rewritten -- three photos in a real 2962-photo archive have exactly that
  shape, and rewriting them would change three checksums to remove nothing.

### Changed

- `config/site.yml.example` writes `about.html` and `footer.note_html` as a
  literal block scalar (`|-`) instead of a folded one (`>-`). In a folded
  scalar YAML turns a blank line into a single newline, which now reads as
  one wrapped paragraph rather than two -- and glues the items of a list
  onto one line. Wrapped prose still collapses back into a single paragraph
  when rendered, so the file stays as readable as it was. Existing configs
  are not touched.

### Fixes

- **`doctor --strip-location` cleaned the archive and left the published
  photo alone.** The strip keeps a photo's exact byte length on purpose, and
  the build skipped copying a media file whenever the sizes matched -- on the
  stated grounds that media is never edited in place, which is exactly what
  this new tool does. So the archive went clean, `public.nosync` kept the old
  bytes, the deploy saw nothing to upload, and the coordinates stayed on the
  site. Doctor then reported "no published photo carries the place it was
  taken" while the published one still did, and nothing in the tool could
  notice, because it only ever looked at the archive. Media copies compare
  modification time as well as size now (one more stat of a file already
  being stat'd, no hashing), and doctor reads both directories, so the
  sentence about published photos is about the published photos.
- **A GPS entry's data offset was trusted absolutely.** Nothing in the format
  stops one from naming bytes that belong to the camera model, the MakerNote
  or the thumbnail, and written into by a file like that the strip damaged
  the photograph and left the coordinates in it. It now works out which
  ranges the other directories own and refuses to write over any of them.
  Nothing in a 29,805-photo corpus was shaped like this; the rule is there so
  that the answer does not depend on that staying true.
- **Every imported table handed its first row of data to a `<th>`.** A table
  with no heading row -- a list of keyboard shortcuts, a set of figures, a
  table used for layout -- came out with its first line published as a
  column heading, which is a heading to a screen reader as much as to a
  reader. Wix is where it showed, because Ricos states outright whether
  there is a header (`tableData.rowHeader`) and all three answers -- true,
  false, absent -- gave the same table; but the same thing happened on the
  HTML path, which decides for fifteen other sources and did not tell `th`
  from `td` at all. Both read what their source actually says now: Ricos its
  flag, HTML its `<thead>` or a first row of `<th>`.
  A table without a header had no way to exist before this, so the format
  gained one: **a table may open with the separator row**, and then every
  line after it is data. Markdown proper cannot say this and neither could
  the alternative considered -- a header whose cells are all empty -- which
  real archives rule out, since a genuinely empty header and an empty first
  cell beside real headings both occur. Existing posts are untouched and
  round-trip byte for byte; a table already imported keeps its promoted
  header until it is re-imported or edited by hand.

- **A Tumblr ask post read as if the blog's owner had asked themselves.**
  NPF keeps the question in `layout`, not in the blocks
  (`{"type": "ask", "blocks": [0], "attribution": {...}}`), and the field was
  ignored -- so a stranger's question came out as the opening paragraphs of
  the post, in the owner's voice, and the asker's name never reached the
  archive at all, since nothing else in the payload carries it. The question
  is a quote with the asker under it now; an anonymous one stays a quote
  with no name, which is all Tumblr records. Re-import to pick this up on an
  archive already imported. A `rows` layout is still ignored on purpose --
  it describes a display grid, not who wrote what.
- **`./style.sh` reported a held lock as a failed upload.** The palette
  preview uploads one file on its own, and the wizard offers a rebuild at
  the end; both read any non-zero exit as "it broke" and said so in yellow,
  with "the lines above say why" pointing at a line that says only that
  another run got there first. The publishing path has told the two apart
  since 1.2 -- the exit code exists for exactly this -- so the wizard does
  now too, in its own words and without the warning sign. The code itself
  moved from `Publishing` to `RunLock`, where the lock that gives it its
  meaning lives, with one helper to ask instead of two comparisons to keep
  in step.
- **The palette preview promised more than it could keep.** `./style.sh`
  uploads the preview to the site and prints its address with a QR code to
  scan, and said nothing about how long it would answer. It is a page the
  build did not produce, so the next build removes it (`prune_public`) and
  the deploy takes it off the site as an orphan -- which is the build doing
  exactly its job, and can happen a minute later when a scheduled publish
  starts one. Somebody photographed the QR one evening and found it dead the
  next morning. The wizard says so now, with the address rather than under
  the QR, so a run with no terminal to draw one in is told as well.
- **"Another run is still going" did not say to try again.** The lock
  behaved correctly; the message was the problem. It names the run holding
  the lock only when that process is still alive -- otherwise people go
  hunting a pid that ended an hour ago -- but suppressing the detail took
  the one actionable fact with it, that the run in the way is almost always
  the scheduled one and will be gone in a minute. It says so now. The case
  where it matters is the interactive one: cron comes back by itself in
  fifteen minutes, somebody who just confirmed a palette does not.

### Upgrading

- **Photos saved from now on lose their coordinates.** Nothing on the site
  changes and nothing already published is touched, but this is a behaviour
  change that arrives without being asked for, so it is worth knowing before
  the next photo post. Run `./blog.sh doctor` to see how many published
  photos still carry a location, `./blog.sh doctor --strip-location` to clean
  them (every rewritten photo gets a new checksum, so the next deploy uploads
  it again), and set `media.strip_location: false` in `config/site.yml` if
  your site is the kind that wants the place kept.
- Nothing has to change, and nothing has to be rebuilt for the old behaviour
  to keep working. If you want more than one paragraph (or a list) in
  `about.html` or `footer.note_html` and your config still writes them as
  `>-`, change that to `|-` first -- see Changed above for why. `./style.sh`
  already writes the literal style for any value with a line break in it, so
  editing the text through the wizard fixes it on the way past.

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
