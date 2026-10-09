# Changelog

Every released version, newest first, so a clone can answer "what changed?"
without going to GitHub. Each entry says what was wrong and what it meant in
practice -- a one-line "fixed a bug" is no use to someone deciding whether an
upgrade is urgent for them.

Versions are `MAJOR.MINOR.PATCH`: a patch release fixes defects and never
changes configuration, content or the shape of a post file; a minor release
adds features and stays compatible with existing sites. `./blog.sh version`
prints what an installation is running.


## 1.10.pre -- 2026-09-28

Opened the morning 1.9 went out, so `version` does not claim a release nobody has cut. What
goes in is still being decided; the suffix and the date both come off at the tag.

### Added

- **`doctor --json`, and the table of languages as data.** `./blog.sh doctor --json` prints the
  diagnosis as one object -- `errors`, `warnings`, `oks`, and every finding with its level, the
  check it came from (`kind`: `trash`, `scheduler`, `banner`…), its sentence and its advice,
  problems first -- and a program with a key may now ask for it
  (`scripts/remote.rb`; not `--online`, not `--strip-location`). `check --languages --json`
  prints which post has a text in which language. That pair used to be refused, which made
  `--languages` useless to the one caller it was listed for: a program's request always says
  `--json`.
- **An old address can belong to a translation.** Two posts that were one piece in two languages
  become one post with a translation -- and the second one's address, which the post's own
  `former_slugs` could only send to the post in the site's own language, now leads to the
  translated page: a translation may carry `former_slugs` of its own
  (`translations.en.former_slugs: ["2019/the-old-slug"]`). The redirect stands at the site's
  root and in that language's tree; `check` asks of it what it asks of any old address, and
  saving the translation again keeps it.
- **`site.author_name`.** The author's name as it stands alone -- under a hero title, as the
  person the structured data names, and on the pages of a language other than the site's own.
  For a language that inflects names: there `author` is the form its sentences take ("na webu
  Daniela Šnora") and this is the name itself. Optional; without it `author` is used everywhere,
  as before.
- **A series has a name per language.** `series:` in `config/site.<lang>.yml` gives a series the
  name that language shows -- over its listing, in the sentence that places a part, in the page's
  title -- keyed like `tags:` by the name the posts write or by its slug. The series itself stays
  one thing: one address, one set of parts. Without it a second language showed the series' name
  untranslated over translated posts.
- **On this day.** A sidebar card with posts from this day in earlier years, switched on by
  `on_this_day:` under `widgets:` (or in `./style.sh`). One row per year, five at most: round
  anniversaries always, the rest spread along the years with the oldest claiming first, a titled
  post standing for its year. A busy day rotates through up to three windows; a day with nothing
  hides the card. No settings -- the same rule from a hundred posts to thirteen thousand.
- **`./blog.sh list --search="words"`.** The search `browse` runs behind `/`, for a caller with
  no screen to type it into: the same query language as the screen and the site's search box,
  over the whole text. With `--json` each row carries `match`, the line that says why it is in
  the results, and the answer says the query back as `search`.
- **The search in the terminal keeps its index.** `browse` and `list --search` read every post
  and folded its text on every query -- 4.9 s on 6,600 posts, 3.8 s of it rebuilding what the
  query before had built. The index is now written to `.search_index.json` and a post is read
  again only when its file changed: the same search answers in a quarter of a second. It also
  searches what the site's own search box searches, in every language the site publishes -- a
  translation's title and text, and the label a language gives a tag.
- **`version --json` says the site's accent.** `site.accent` carries the palette's accent for
  light and for dark, resolved as colors.css resolves it, so an app can wear the blog's colour
  the way `/write/` does. `site.palette` carries the rest of what the pages are set in -- `bg`,
  `text`, `meta_text` and `border`, for light and for dark -- so an app can wear the blog's
  ground and ink too.
- **`./blog.sh on-this-day [--date MM-DD] [--json]`.** The same selection in the terminal: every
  post of the day, and which of them the card shows in which window.
- **A draft can be edited from the phone.** *Open a draft from the blog* in `/write/` lists the
  drafts; choosing one puts it in the form, and sending saves it over the draft. Its pictures
  stay on the blog and are shown from there; a picture the text stops naming is deleted, said
  before sending. A draft markdown cannot hold whole is listed but cannot be chosen, and one
  that changed in the meantime is not overwritten. The shortcut does not change.
- **`./blog.sh drafts [--json] [<slug>]`.** The drafts, and with --json what the phone needs to
  edit each one.
- **`edits: <slug>` in a file for `add`.** Saves it over that draft, as `edit` would, with every
  question a refusal; `base:` refuses a draft that changed after its text was handed out. What
  the new text leaves out is taken out -- a post can be made shorter this way; refused as a loss
  is only what markdown has no words for, which the text never showed.
- **The sidebar cron turns the day over.** A site with the card wants `refresh-sidebar.sh` in
  cron even with no other widget; it rewrites the card's file once a day, per language. The
  script leaves the moment it ran, and `doctor` says when the card is switched on and nothing
  runs it -- without it the card shows the day of the last build and is gone the day after.
- **`list --json`, `props <slug> --json`, `queue --json`.** The three screens somebody reads before
  acting, as data: the archive with its filters, one post with its properties and the actions that
  apply to it by name, the queue in publish order. One object each, every key always present, a
  refusal as an object with a zero exit -- the promise `add --json` already keeps. For a program
  that cannot press a key in a dialog: a phone app, a script.
- **The actions of those screens, for a program.** `schedule <slug> --at <time> --json` and
  `--cancel` (with `--compact` to shift the queue behind it), `publish --compact`, `unpublish --yes`,
  `delete --yes`, `restore` (without a slug: the trash as data), `rebuild` and `empty trash` /
  `empty versions` (without `--yes`: the count and the size), all under `--json`. Every question
  the terminal asks is a flag or a refusal; a flag that answers a dialog's question is refused
  without `--json`, where the dialog is there to ask it. See *Driving the engine from a program*
  in docs/operations.md.
- **The rest of the properties screen and the queue, for a program.** `props <slug> --set
  series=... --set tags=... --json` writes the [e] rows and the pin; `--drop-address`, `--rename
  <slug> --yes`, `--versions` and `--restore-version <name> --yes` are the [a], [r] and [v] keys;
  `queue --up <slug>`, `--down <slug>` and `--move <slug> --to <n>` are [u], [d] and [m]; `toot` and
  `bluesky` answer with the address or the reason, `--force` answering the "announce it anyway?"
  question. Every answer is the screen as it stands afterwards.
- **`version --json`**, and **`scripts/remote.sh`**: the forced command for a program's key. `run`
  takes one engine command with its argv as JSON on standard input and checks every word against a
  whitelist of commands and flags before the engine sees it -- nothing is ever parsed as shell, and
  the key never gets one; `receive` is the delivery `receive.sh` takes. The identity block (engine,
  site, claim, URL, languages) comes as data, for an app to show above its screens.
- **`deliver`** on the same key: a delivery ended by a line saying `end`, for a sender that cannot
  close its side of the stream, handed to `receive.sh` whole; `version --json` says the receiver's
  ceiling (`max_mb`), and `props --json` which network [t] announces on, the slot the schedule
  dialog would offer, and the [e] rows in the words `--set` takes back.
- **`edit <slug> --json`, and a published post edited from a file.** The text as the editor opens
  it, handed out for any post; a file saying `edits: <slug>` may now edit a published post too, with
  `base:` required so a change made elsewhere in the meantime is refused rather than overwritten.
  The app on a phone is a desk now. `translate <slug> --lang <code> --json` hands a language's text
  out the same way, and a file saying `lang:` beside `edits:` and `base:` brings it back.
- **`./blog.sh pair`: an app is let in by reading a code.** Reaching the engine from an app has
  meant copying the app's key out and writing a line into `~/.ssh/authorized_keys` by hand; that
  stays, and beside it `pair` draws a QR code in the terminal that an app reads and is connected --
  no address, user name or key typed anywhere. The code holds where to connect, the fingerprints
  of the server's own keys, and a key good for one thing, once, for ten minutes: handing in the
  public half of a key the app made itself, which the engine then writes a line for, held to
  `scripts/remote.sh`. `pair --list` and `pair --revoke` show and remove the devices let in this
  way: `--list` numbers them, and `--revoke` takes that number, the name or the fingerprint, or asks.
  The engine writes only `restrict,command=` lines of its own, touches no line it did not
  write, and keeps the file as it was beside it. For a blog and an SSH server in one account; a
  container still wants its line written by hand. `doctor` mentions a code's line left behind.
- **A program may say which language it reads.** `"lang": "cs"` beside `args` in a request to
  `scripts/remote.sh`: `check` and `doctor` then say their findings in that language where the
  engine ships it, instead of in the blog's. An app in Czech showed an English blog's diagnosis in
  English. Only those two -- they build nothing -- and a language the engine does not have is the
  blog's own, never a refusal.
- **The queue says whether anything publishes it.** `queue --json` carries `scheduler.last_run`,
  null on a blog nothing has ever run the queue on. There, a post past its time no longer says
  "wait for the cron": it says nothing publishes the queue here and to publish the post with
  `./blog.sh publish <slug>`. Nothing is published by looking -- publishing announces.
- **A launcher on a Mac.** `./setup.sh` ends by offering an icon in Applications, named after the
  site and wearing its favicon, that opens Terminal in the site's folder and runs `./blog.sh` --
  for the author to whom "open Terminal and type" is three things to get wrong. Built from what
  macOS ships (`osacompile`, `sips`, `iconutil`, `codesign`); nothing is installed. The answer to
  Enter is no, an application of the same name that blog.sh did not make is never replaced, and
  `./setup.sh --launcher` makes it later or makes it again for a site that moved. macOS asks once
  whether it may control Terminal, and Terminal keeps its window open afterwards; the wizard says
  both. Elsewhere the question is not asked.
- **`/series/`: the index of series.** A line for every series that has a page -- its name, how
  many parts, the years they span -- with the one still being written first. A series could be
  reached only from a post that belongs to it, and `/series/` answered 404 with every address under
  it alive. The name in a series' own heading now leads back to the index, as a tag's leads to
  `/tag/`; the sitemap lists the page, `check` knows the address, and a second language gets its
  own with the names `series:` in `config/site.<lang>.yml` gives them. A site with no series has
  no such page.
- **The archive says what its shading means, and a year can be crossed.** The map's last row is a
  legend: the four steps between "less" and "more", drawn with the map's own cells. A year's page
  opens with that year's row of the map behind the words "jump to a month" -- a month with posts
  is a link to its section further down, shaded as on the map.
- **The tag index has a way to a letter.** Above the list, the letters that have tags under them,
  each a link to its band, behind the words "jump to a letter". Count order has no bands, so the
  switch puts the row away while that order is shown.
- **`banner.show_image: false`.** A header without its picture: the short name and the description
  stand on the page itself, in the page's own text colours, and the whole header is still the link
  home. The markup is the banner's with the `<img>` taken out and nothing else moved -- the wrap
  gains `banner-wrap--plain` -- and the default rules for it weigh nothing, so a skin that already
  draws its own header and hides the picture looks exactly as it did, and its readers stop
  downloading a file nobody showed them. `banner.src` stays: it is also the picture a page with
  none of its own is shared with.
- **`layout.lead_card`.** With it on, the card that opens the front page -- the pinned post where
  there is one -- leads with its post's first picture, under the title and above the opening
  words. A card is cut by height, so a picture written after the first paragraph is usually left
  out of it, and a stylesheet cannot show what the card was never given. Only that one card and
  only the front page itself; it carries `post-list-item--lead` for a skin to dress. Off by
  default, and a post with no picture keeps the card it had.

### Changed

- **The card of a picture post carries the picture, and a video post's the video.** A card is cut
  by height and keeps its first block whatever that weighs, so a photograph under one line of
  words was left off the card of a post that is that photograph: on one archive the first page of
  the pictures showed three pictures in thirteen cards. For a post whose kind is image or video
  the medium now goes first and the same cut runs over what follows. A post that opened with its
  medium keeps what it kept; a medium taller than wide is held to 22rem instead of taking a screen,
  and the budget is charged that height, so the caption under a portrait photograph is on the card.
  Such a card is `post-list-item--media` (and `--media-tall`). **This changes listings without
  anything being set**: every site with such posts shows more pictures after the upgrade. An
  article with a photograph in it is still an article, and the card `layout.lead_card` asks for is
  left as it was.
- **The cheat sheet shows a picture and a gallery.** Its section on pictures had a source and a
  sentence and nothing to look at. It now draws both -- a picture with its caption, and a gallery
  of a landscape beside a portrait, which is the crop the paragraph above it describes -- from two
  drawings of under a kilobyte each, shipped in `assets/cheat-sheet/`.
- **A part of a series names the series first.** "Nový Sean.cz — part 3 of 19" where the note used
  to read "Part 3 of 19 of Nový Sean.cz" -- in all three languages -- so a reader meets what they
  are in before where they are in it. The same line now stands on each card of the series' own
  listing, which until now showed which posts belong and not which comes when; there it is words,
  not a link to the page it stands on. Every post in a series and every page of a series' listing
  is rewritten by the next build.
- **One thing, one word, in the terminal.** The queue offered "[s] different time" and "[n] remove
  from queue" for what a post's own screen calls "[s] reschedule" and "[n] cancel the schedule";
  both say the second now, in all three languages. Czech also called an unlisted post two things
  and taking a post off the site two things: it is "mimo výpisy" and "vrátit do konceptů"
  everywhere. The keys are the keys they were.
- **A page of a listing says the days it covers.** "page 663 · Sep 12–18, 2026" where it said
  "page 663": pages are numbered from the oldest post, so the one right behind the front page
  carries the highest number, and a number without a total says nothing about where it is. There
  is still no total -- it would rewrite every page each time one is added -- and the dates need
  none: they are read off the page's own posts. What the two ends share is said once (one month,
  one year), in each language's own way, on a line of their own under the number. The page the
  numbering starts from says "the beginning" where the link to older posts would stand. A series
  is paged by parts and says neither. Every page under `/page/N/` is rewritten by the next build,
  once.
- **The 404 page offers what its sentence promises.** It said "the menu above and the search box
  are the way on" and put neither under the sentence. Now a search field stands there, filled with
  the words of the address that was not found (`/posts/2019/a-day-out/` becomes "a day out";
  nothing is searched until the reader asks), and under it pills back to the front page, to the
  archive and to the index of tags -- each only where the site has that page -- plus the year of
  the archive when the address names one it has. No word on the page is new: the labels are the
  ones those pages already carry. For a skin: `.not-found-search`, `.not-found-links`,
  `.not-found-link--back`, `--archive`, `--year`, `--tags`.
- **A listing's heading says how many it holds.** A small number after the name, as the index of
  tags writes it: posts under a tag or of a type, parts of a series, posts of an archive year and
  of the whole archive, tags in the index of tags. On a tag's or a type's listing it stands on the first page only -- that
  page is rewritten by a new post anyway, and on all of them it would rewrite every page of a tag
  each time a post takes it. A series says it on every page, which costs nothing: its cards
  already count the parts.
- **A thread reads as a conversation.** A reply to somebody's comment, rather than to the post,
  is set in under it -- one step, however deep the exchange goes. In a live thread the page
  reads it off the thread; on a moderated site cron writes `reply: true` into `comments.json`
  for such a comment, so the indent appears with the next refresh. `comment--reply` for a skin.
- **The search says why a result is there.** The words that were asked for are marked in a
  result's title and excerpt -- as written, accents and all: "ctyri" marks "Čtyři". Only what
  the card shows is marked; a match deeper in the post marks nothing.
- **Things a skin could not select are marked.** Nothing looks different until a stylesheet
  says so (`docs/skinning.md`, "What the markup marks for you"):
  a link in a post's text that is a mention or a hashtag -- its whole text "@somebody" or
  "#something" -- carries `mention` or `mention hashtag`, the classes the same things have in the
  comments and in the sidebar's toots;
  a reply written by the account that announced the post is `comment--author`;
  "page 12" under a listing is `pagination-word` and `pagination-number`;
  the search's "4 results" is `search-count` and `search-unit`;
  the series sentence is three spans -- the name, what joins it, the part -- so a series' own
  listing can drop the name every card repeats;
  the heading of an archive year says its kind and its year separately, as a tag's does, and the
  year alone is the link back to the map of years (the word "Archive" was part of the link);
  on a tag's listing the pill of that tag is `tag-pill-own`;
  a count of zero under a post is `post-stat--zero`;
  and on the markdown cheat sheet what a source becomes stands in `md-example`.
  Every listing of a tag, every archive year and the cheat sheet are rewritten by the next build.

### On its way out

- **`/write/` and the shortcut.** Native apps for iOS and Android are in preparation. They talk
  to the engine over the SSH the server already has (`scripts/remote.sh`) and do what the page
  does and more -- the queue, a post's properties, a published post's text, a translation -- on
  Android as well, where the page could hand its files to nothing the engine ships. **1.11 takes
  out** the page, the `SendPost` shortcut and what exists only for the two: the delivery receipts
  and the `publish.txt` and `drafts.txt` requests. This is the notice. In 1.10 both work as they
  do today, and nothing new is added to them. `scripts/receive.sh` stays -- it is what the apps
  deliver through, and what `./blog.sh add <file>` has always been the other end of.

### Fixed

- **The config writer read a config in whatever encoding the shell named.** Under a shell that
  names none, a `config/site.yml` with one accented letter in it could not be searched for a key,
  and every setting written to it failed with "invalid byte sequence in US-ASCII". The wizards set
  the encoding before they open the writer and never met it; anything opening the writer on its own
  did. It reads UTF-8 by name now.
- **A second language's build called a post's own page "already taken".** A translation that kept
  the slug of the post it was merged from stands, in its own tree, at an address the post's
  `former_slugs` also names; the build warned once per such post on every run. An old address
  that is the post's own page is the post answering, and is passed over without a word.
- **The cheat sheet's contents list had lost two sections.** The teaser (1.5) and the link card
  (1.7) were added to the sheet and never to the list at its top, in all three languages.
- **An export left a post's other languages behind.** `translations` was not among the keys an
  export writes, so the documented way to move an installation carried a site of two languages
  out as a site of one, and said "posts: N". They ride under `blogsh:` now, and an import of the
  tree brings them home -- words, address and old addresses of each language.
- **Three pages of a second language named the first language's as their own.** `/en/search/`,
  `/en/markdown/` and `/en/404.html` carried the canonical address and `og:url` of the pages
  without `/en/`, beside an hreflang that said otherwise. Each says its own address.
- **`doctor` said "0 problems" about a language configuration no language builds on.** A language
  in `site.locales` with no locale file, a key a language's file may not have, a translation of a
  widget the site lacks, an empty tag label: `check` named them and `doctor` did not. It does;
  and `check` names the one neither did -- `site.fallback` or `site.ui_language` kept in
  `config/site.yml`, where 1.9 stopped reading them.
- **The advice about a language with no locale file did not work.** Build and `check` said to
  write `site.ui_language` into `config/site.yml`, which is where it is refused. They say
  `ui_language: <code>` at the top of `config/site.<code>.yml`.
- **`preview` on a port already in use printed "Serving at ..." and a stack trace.** It says the
  port is taken, and which one to try.
- **`translate` closed without a change left an empty template behind as rescued text,** said the
  text was not lost, and had the next `add` ask about it.
- **Saving a post rewrote the blocks nobody had touched.** An edit rebuilds a post from its
  text, and the text has no word for what an import brought along: a paragraph Tumblr marked as
  indented or as a list item, a video's provider and first address, a player handed over as HTML.
  Fixing a typo in one paragraph saved every other block without them -- at the desk and from an
  app alike; on one real archive 101 posts changed by being saved unchanged. A block the new text
  did not change is now saved as it was stored, whole; so is anything a translation's entry holds
  beside its words.
- **Two deliveries arriving together could swap pictures.** `incoming/` knows a picture by the
  name it was sent under, and every phone calls its first one the same: of two posts sent at the
  same moment, the one made first got the other's `01.jpg`, and both were answered ok. The
  receiver takes deliveries in one at a time; one that has waited `BLOGSH_TURN_SECONDS` (300) is
  told `busy` and stores nothing.
- **A listing by type was promised in a language that has none.** A photo post translated in
  words alone is a text post in that language; where every photo post is, `/en/type/image/` is
  never written -- and the sitemap, the hreflang of `/type/image/` and its language switcher all
  named it. Each says only what that language's build wrote.
- **A page and a post of one year translated to the same slug stopped every language.** "Projects"
  for the page and for this year's post are two addresses, `/en/projects/` and
  `/en/posts/2026/projects/`; the build called them one, with `translate` having saved both and
  `check` finding nothing wrong.
- **Four places where a second language met something written for one.** A menu item pointing
  at a part of a page (`/about/#contact`) was not moved to that page's address in the other
  language, and one pointing at a part of a post led nowhere. A language that borrows its
  interface (`ui_language`) said `og:locale="en_US"` on every page; it now says none. What the
  build has to say about `config/site.yml` came once per language, each time in that language's
  words; it is said in the site's own. And a `redirect_from` into a language's folder
  (`/en/old/`) was written by one run and deleted by the next on every build while `check` called
  the address alive: the build refuses it aloud and `check` names it.
- **A launcher on a Mac was replaced by another site's.** Two sites called the same -- any two
  nobody has named yet -- wrote one icon, opening whichever was made last. The second is told so.
- **Pairing, on more machines and with fewer surprises.** A window too small for the code is asked
  to grow before `pair` gives up on drawing it. The line written for sshd begins `env PATH=...`,
  which a csh or tcsh login shell runs too. A key that already stands on another line of the
  account's file is refused (`key_in_use`) instead of being written where sshd would never look.
  A Ctrl-C that lands in the moment the app hands its key in says who came in, not "cancelled".
  A device's name keeps its accents when it arrives decomposed. An address guessed from an SSH
  session is not offered when it is the machine talking to itself or a link-local one. A site
  name too long for the code is shortened until the code can be drawn. `pair --list` writes
  nothing, and a key file with carriage returns or no final line feed comes back byte for byte.
- **Six answers to a program that were written for a screen.** A file saying `edits:` for a slug
  two years have used opened the picker -- a question in prose and a status of 1; it answers
  `ambiguous_slug`. Every lookup that could not ask said the sentence written for `publish
  --yes`, so an app opening a post to read it was told to publish it. `drafts --json` carried
  `omitted` only sometimes, `empty --json` a size of null, and `delete`, `restore` and `schedule
  --cancel` their own "Deleted: /path" among the warnings. `list --tag cats`, the value as the
  next word, answered with the whole archive. And `schedule --at` with a moment said in UTC
  dated the post in UTC and filed it under UTC's year, and read 30 February as 2 March.
- **`translate` refused an address no page had.** A post never written in a language has no page
  in its tree, and the address it would have there was counted as taken.
- **`docs/install.md` updated a site in two languages halfway.** Its recipe ran the build script,
  which renders one language per run, and deployed; the second language stayed as the previous
  version built it. The recipe is `./blog.sh rebuild`.


## 1.9 -- 2026-09-28

The release about publishing in more than one language. A post keeps one set of metadata and a
text per language, every language in `site.locales` beyond the site's own gets a root of its own,
and one `rebuild` builds them all. Beside that, the first hour: everything two people setting
blog.sh up from scratch tripped over is fixed. One thing to do, on Cloudron's Surfer only: Surfer 7
signs in with `SURFER_USERNAME` and an app password in `SURFER_PASSWORD`.

### Added

- **More than one language.** `site.locales` names them; one post, a text per language.
- **`./blog.sh translate <slug> --lang de`.** Or from the wizard's crossroads and the post's properties.
- **A root per language.** The site's own keeps `/`; one `rebuild` builds them all, one sitemap names them.
- **A post nobody has translated still shows**, linking to the one copy that exists.
- **A language switcher.** A chip beside the light/dark button; a click moves to the next language.
- **`fallback:` and `ui_language:`.** What stands in for a missing text, or a missing interface.
- **`config/site.<lang>.yml`.** Title, description, banner, about, footer, menu and tag names per language.
- **Pages are translated like posts.** Under the language's root (`/de/ueber-mich/`).
- **`check --languages`.** A row per post, a column per language.
- **`publish` and `schedule` refuse a post missing a language.** `--allow-partial` says otherwise.
- **`doctor --online` asks the deploy target.** Whether it answers, and what stands in its root.
- **`deploy.keep` in `config/site.yml`.** What stands in the target's root on purpose.
- **A draft's properties show its preview address.** `[q]` puts it on a phone as a QR code.
- **Setup says what went into a hidden prompt.** Its length and its last two characters.

### Changed

- **Surfer 7 signs in with the Cloudron username and an app password.** `SURFER_USERNAME`, `SURFER_PASSWORD`.
- **Adding or removing a language is a deploy like any other.** No `--force`, no `--prune`.
- **Structured data names the page's language.** `inLanguage` in every post's JSON-LD.
- **A heading the site does not write is the engine's**, in the language of the page.
- **The Czech interface says "příspěvek", "sestavení" and "koncept".**
- **One phone shortcut instead of two.** It runs on a Mac too.
- **`./blog.sh rebuild` takes `--full` and `--force`, and nothing else.** A failed one exits 1.
- **A cold build costs about 6% more than 1.8's.** A cached rebuild costs what it did.

### Fixed

- **A picture captioned in typographic quotes vanished from the page.**
- **Embedded players were black on a host with a tight referrer policy.** YouTube's "Error 153".
- **`check` called `/write/` dead on the sites that publish it.**
- **The import menu did not say WordPress takes a file.**
- **A re-import dropped what it had no name for.** A phone receipt, among others. It keeps everything the source does not decide.
- **A token pasted with a space around it was saved with it.**
- **`install.md` never said a deploy leaves an old site's files in place.**
- **In the writing app, "Add a picture or video" did not look like a button.**
- **The writing app's warning about a missing description read like a rule.** A second tap sends.
- **Chrome and Edge could not send the text from the writing app.** It goes as `.md.txt` now.
- **The writing app, reopened more than five minutes after sending, said nothing.** It waits fifteen now, and a page reopened later asks once.
- **rclone installed as a snap failed every deploy.**
- **`doctor` ticked a backend whose program is not installed.**
- **The warning before an edit loses something spoke the schema's English.**
- **A file size used the English decimal point in every language.**
- **Ctrl+C in any screen of `./blog.sh` ended in a stack trace.** It exits 130.
- **FTP was nowhere in the docs.** The rclone backend has always reached it.
- **`publish --json` fell over on a post whose date nobody can read.**
- **A podcast import put the show's cover over every episode.**
- **Esc did things.** It deployed, opened the editor, wrote a control character. Now it never does.
- **`rebuild --help` built and deployed the site.** And `--force` was ignored.
- **A mistyped command scrolled the whole usage past** without saying it does not exist.
- **`[p]` in a draft's properties published and announced on one key.** It asks first.
- **A site that announces nowhere, or has no token, was promised an announcement.**
- **After a failed build, the last line said to wait for another run.** There was none.
- **A slug pasted into a picker kept its first character.** A menu past nine rows takes two digits.
- **`./setup.sh` took the template's examples as the site's name and address.** And spoke English above a Czech run.
- **`./setup.sh` wrote `~/www` as typed**, and `doctor` then called it a relative path.
- **Enter through Layout in `./style.sh` wrote the engine's defaults into `site.yml`.**
- **Cancelling a plan left the slot's date on the post.**
- **A site deploying to a directory was told it "goes nowhere yet".**
- **Every publish on a site with no network advised checking the config.**
- **`doctor --onlien` ran the offline checks and said nothing.**
- **The shipped banner was said to jump.** Only the ratio holds the space open.
- **A quote left open in `site.yml` was reported on the wrong line.**
- **Pickers said `[DRAFT]` on a Czech screen.** `list`, which scripts read, keeps it.

## 1.8 -- 2026-09-14

The release about what happens when something goes wrong. A page is written whole or not at all, a
delivery that arrives twice is one post, a name that was never meant to be a path is refused rather
than repaired into an address nobody chose -- and `check` asks what the build asks, so an archive it
calls sound is one the build can run on. Before the tag, five narrow review passes went through the
write paths, the build's output, import and export, `check` and the series; everything they found
is fixed here. Nothing to configure and nothing to migrate. Two things look different: a series of
twenty parts or more opens at part one, and a tree exported from blog.sh asks before it goes into an
archive that already has posts.

### Added

- **`props` says where a numbered part will actually stand.** Only when that differs from its number.
- **A release checklist.** `docs/releasing.md`, nine steps, the build's speed among them.
- **Importing a site's own export says so first, and asks.** Recognised by its posts, so exports made by any version count.
- **`check` finds a post file the build never reads.** One lying directly in `posts/`, or a folder too deep.

### Changed

- **Every page, feed and index is written to a temp file and renamed.** A reader never meets half of one.
- **A cold build costs about a fifth more.** Cached rebuilds are unchanged, so publishing costs the same.
- **A long series opens at part one.** `/series/<slug>/` holds the first parts, `/page/2/` on the ones after -- other parts than in 1.7.
- **`export --force` refreshes only what an export of this site wrote.** A cloned site's `_config.yml` and anyone else's files are left alone and listed.
- **An export closes each HTML block with `<!-- /blogsh:block -->`.** Trees exported before 1.8 are still read.
- **An export says which blog it came from.** `_config.yml`, unless the target already has one of its own.
- **An export that could not write a post leaves with 1.** The rest of the archive still comes out, and the post is named.
- **An export says how many media files no block names.** A re-import brings home only what the posts refer to.
- **A cancelled import leaves with 1.** Zero no longer means "nobody answered".
- **`check` has more to say.** An unusable `former_slugs` entry, a post that looks like a copy, an old address a live post has taken, two addresses that are one folder on macOS.
- **A question `check` cannot ask is one finding, not the end of the run.** It names the question and the error.
- **`--repair` shows what an entity fix will change.** And says when text escaped twice still has a layer left.
- **A page the build cannot write is a warning and a count at the end.** The rest of the site is still built.
- **The names the engine keeps in the site's root are one list.** Measured against what the build writes; `series` is among them now.
- **The build's domains live beside it.** `blocks`, `output`, `feeds`, `discovery`, `cards`, and `lib/series.rb`.
- **The cheat sheet says how pictures end up side by side.**

### Fixed

- **A save interrupted by a full volume left the post at 0 bytes.** The old text gone, the new one never written.
- **A build stopped mid-write left a page, a feed or the search index at half its length.** Served that way.
- **The same delivery arriving twice made two posts.** The second one invisible to whoever wrote it.
- **Two deliveries of one receipt arriving together made two posts.** A retry that overtook the first attempt.
- **Re-importing this engine's own export wrote every post again.** 1200 posts became 2400.
- **A slug, a media name or a redirect target carrying `../` reached `mkdir`.** From a hand-edited post or somebody else's export.
- **A local deploy could write and delete files above the directory it was pointed at.** Both reported as done.
- **A feed's redirect could send the fetch to localhost or a private address.**
- **Undoing an edit could delete a post's history rather than step it aside.**
- **A replaced file came back wearing the temp file's permissions.** Under a strict umask, a page the server cannot read.
- **Two writes in one process could meet on one temp name.**
- **Repacking a video dropped its recording time.** And every sound track but the first.
- **A refused write left its first picture behind, and the retry landed on `slug-2`.** An address nobody chose.
- **A re-import stopped halfway through a change of year left the post in one year and its pictures in the other.**
- **A part numbered `08` or `09` lost its number.** Read as octal; the series fell out of order.
- **A picture restored from a backup never reached the site.** Where the build copies rather than links.
- **One address the build could not claim switched every later picture from a link to a copy.**
- **An interrupted save left a temp file in the archive.** And a refused write named the temp file, not the target.
- **Cron's files in `public/` were emptied before they were written.** A run that died left a blank `stats.json` live.
- **A page slugged `index.html` or `search-index.json` stopped every build.** Twelve root names were missing from the reserved list.
- **`check` died on a post whose `media` was an object.** Before it had reported anything.
- **`check` called an archive sound over six shapes the build dies on.** A draft token climbing out of the site among them.
- **`check --json` gave at most twenty address collisions.** The rest as a bare count, with nothing to find them by.
- **`--repair` decoded text it had never been offered.** A paragraph written meanwhile about HTML lost its point.
- **A media directory in another unicode form was called orphaned.** And `--repair` offered to trash live pictures.
- **A series whose name did not fit an address linked every part to a 404.**
- **A link post's borrowed title was printed twice in the feed.**
- **An empty heading sent the contents list one heading off.**
- **One broken post stopped the whole export.** Everything after it in alphabetical order stayed at home.
- **A page slug carrying `../` was exported above the target directory.**
- **A spacer took the next paragraph with it on the way home.** And an embed with a blank line left its markup on the page.
- **A post whose date nobody could read was dated by its file's timestamp.** For a tree just copied, the day of the import; the file name decides now, and the import says so.

## 1.7 -- 2026-09-05

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
