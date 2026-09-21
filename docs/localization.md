# Adding a language

Two different things are called "another language" here, and they are
independent:

- **Translating the ENGINE** -- the menu, the labels, the dates, the
  wizards. That is this page, and it is one file of data.
- **Publishing the SITE in more than one language** -- posts with a text
  per language, a root per language, a switcher. That is
  [Publishing in more than one language](#publishing-in-more-than-one-language)
  at the foot of this page.

A site can do either without the other: a Czech blog whose engine speaks
Czech publishes one language, and a blog published in Czech and German
needs both locales to exist first.

How to translate blog.sh -- the generated site and the CLI wizards -- into
a language it doesn't ship yet. No code changes are involved: a language is
data, and a partial translation is useful from day one.

## How language selection works

`site.lang` in `config/site.yml` picks `locales/<lang>.yml`. Every string
the engine renders or prints goes through that file, and **any key missing
from it falls back to English individually** (`lib/i18n.rb`) -- so a
half-finished locale shows your language where it exists and English where
it doesn't, instead of breaking. Only `locales/en.yml` must stay complete:
it is the fallback for everyone, and the build aborts if a key is missing
from both.

## What a complete localization consists of

1. **`locales/<lang>.yml`** -- copy `locales/en.yml` and translate the
   values (never the keys). The sections, roughly in order of what a
   visitor vs. an author sees:

   | Section | Who sees it |
   | --- | --- |
   | `date_format`, `date_time_format` | everyone -- strftime formats for every rendered date |
   | `thousands_separator`, `decimal_point` | nobody reads these as words: they are how a number is written, not a message. English keeps `,` and `.`, German swaps them, Czech separates thousands with a non-breaking space. Only `./blog.sh stats` formats numbers through them |
   | `nav`, `post`, `pagination`, `tag`, `type`, `series`, `index`, `search`, `not_found`, `markdown_page`, `ui`, `redirect` | site visitors -- the chrome, the listings, a post's own furniture (reading time, contents, series navigation), the 404 page and the one line an old address shows while it forwards |
   | `share` | site visitors -- the row of controls under a post, including the question the Mastodon button asks and the two lines the copy button swaps between |
   | `js` | site visitors -- shipped into the browser for client-rendered strings; `js.date_locale` is a BCP-47 tag (`de-DE`) and must agree with `date_format`, or server- and client-rendered dates diverge |
   | `build` | authors -- what `ruby build/build_blog.rb` says while it renders: both lines it signs off with, and everything it names as not built -- a post, a page, a tag, a redirect, a picture a post's media folder does not hold |
   | `cli` | authors -- `./blog.sh`, the wizard, `$EDITOR` hints |
   | `poster` | authors -- what the CLI says when an announcement cannot be sent or its numbers cannot be fetched |
   | `doctor`, `check`, `stats`, `export` | authors -- the commands that report on the installation and the archive. `doctor` and `check` pair each finding with a fix line, and the fix is a sentence telling somebody what to do, so it is worth as much care as the finding |
   | `setup`, `style`, `wizard` | authors -- the questions in `./setup.sh` and `./style.sh`, plus the plumbing both share |
   | `cron`, `import` | authors -- scheduled publishing and `./import.sh` |

2. **`templates/markdown-cheat-sheet.<lang>.md`** -- the source of the
   generated `/markdown/` syntax page. Optional: without it the page falls
   back to English wholesale. Translate the prose, keep the syntax examples
   as they are -- they are what the page exists to show.

3. **`write/locales/<lang>.yml`** -- the strings of the `/write/` page,
   which is a separate app: it runs in a browser with no Ruby behind it,
   so its locales are compiled into `write/i18n.js` by
   `ruby write/build-i18n.rb`. Copy `write/locales/en.yml`, translate the
   values, run that script, and commit the generated file with them; it
   reports every key that still falls back to English as it goes. The
   `error` section is the codes `scripts/receive.sh` and `add --json`
   return -- the server sends a code, never translated text, and this is
   where it becomes a sentence. Optional the way the cheat sheet is: a
   page with no locale of its own falls back to English key by key, and a
   site without `write: true` never publishes it at all.

That's the whole list. `README.md` and `docs/` stay English.

## Rules that keep a translation working

- **Placeholders survive verbatim.** `%{count}`, `%{slug}`, `%{path}` --
  same set as the English string, spelled exactly. A renamed placeholder
  isn't substituted and the reader sees `%{cout}` in the output.
- **Prompts keep their trailing space.** A string ending `": "` puts the
  cursor one space after the colon; drop the space and input sticks to it.
- **There is no plural system, on purpose.** Write count phrases so one
  wording works for any number -- the way the Czech locale phrases around
  its three plural forms, or a neutral `Posts: %{count}` shape. Don't
  invent `one:`/`many:` variants; nothing reads them.
- **Some terms stay untranslated:** `repost`, `boost`, `reblog` name three
  distinct mechanisms on three networks and are established loanwords;
  `Markdown` and `RSS` are names.
- **Use your language's own typography** -- quotes („…", «…», “…”), dashes,
  spacing. The English text is the meaning, not the punctuation.
- **Multi-line messages may reflow.** Match the content, not the line
  count.

## Verifying your locale

Key parity against English (empty arrays = complete):

```bash
ruby -ryaml -e '
def keys(h, p = ""); h.flat_map { |k, v| v.is_a?(Hash) ? keys(v, "#{p}#{k}.") : ["#{p}#{k}"] }; end
en = keys(YAML.load_file("locales/en.yml")); xx = keys(YAML.load_file("locales/de.yml"))
p missing: en - xx, extra: xx - en'
```

Then see it live: set `site.lang: <lang>` in `config/site.yml`, and

```bash
ruby build/build_blog.rb        # the site side
./blog.sh preview                # read a post page, /search/, /markdown/, /404.html
./blog.sh help                   # the CLI side
./blog.sh                        # the wizard menu
./blog.sh doctor                 # and check, stats, export -- the reporting sections
./import.sh --help
```

A placeholder typo shows up immediately as a literal `%{...}` in the
output -- worth grepping the rendered `public.nosync/` for `%{` before
submitting.

## What doesn't localize (yet)

- **Right-to-left languages.** The templates don't mirror the layout
  (`dir="rtl"` is not set anywhere), so an Arabic or Hebrew locale would
  render left-to-right. Honest status: not supported until someone does
  the layout work, which is CSS and templates, not YAML.
- **Slugs stay ASCII.** Titles are transliterated (NFKD plus a table for
  ß, ł, œ and friends -- see `lib/slug.rb`); scripts that don't
  transliterate (CJK, Cyrillic, Arabic) produce an id-based slug instead.
  URLs work either way.

## Publishing in more than one language

`site.lang` is the language the site is WRITTEN in; `site.locales` is the
list of languages it is PUBLISHED in:

```yaml
site:
  lang: cs
  locales: [cs, de]
```

Both locale files have to exist (`locales/cs.yml`, `locales/de.yml`) --
that is the first half of this page.

### A language the engine has not been translated into

The engine ships `en`, `cs` and `de`. Naming any other language in
`site.locales` stops the build and says so: without words of its own that
branch would quietly inherit English, which is worse than being told.

There are three ways out, and the third one is why this section exists:

```yaml
site:
  lang: cs
  locales: [cs, sk]
  ui_language:
    sk: cs
```

The Slovak branch is then built and is Slovak in every way a reader or a
crawler can see -- `/sk/` addresses, `<html lang="sk">`, its own
`hreflang` -- while the engine's own furniture (Read more, the dates, the
search box) is Czech. Borrowing a near language beats publishing an
English-speaking Slovak site, and unlike the silent inheritance it is a
decision somebody made.

The other two ways out are to write `locales/sk.yml` -- the engine takes
translations, see the top of this page -- or to stop publishing the
language.

### What the site looks like

The language in `site.lang` keeps the site root and every other one gets a
root of its own:

```
/                 the site's own language
/de/              every listing, tag, series, feed and post that has German words
/assets/          one copy, shared
/write/           one writing app, shared
/robots.txt       one copy -- a crawler reads the origin's root and nothing else
/sitemap.xml      one copy, naming every language and their alternates
/stats.json …     the sidebar's data, refreshed by cron at the root
```

The root is not `/cs/` on a Czech site, and that is deliberate: every link
anyone has ever made to the site goes on working the day a second language
is added.

### What a post carries

Metadata once, words per language. A post with no `translations` key is a
post in the site's own language -- which is every post in every archive
today, so nothing has to be migrated:

```json
{
  "slug": "muj-post",
  "title": "Český titulek",
  "date": "2026-09-20T10:00:00+02:00",
  "tags": ["ruby"],
  "content": [ ... ],
  "translations": {
    "de": { "title": "Deutscher Titel", "content": [ ... ] }
  }
}
```

A language counts as written when it has a BODY. A title with nothing
under it is a translation somebody started: it stays in the archive and
`check --languages` shows it as started, but the language is not offered
for that post and no page is built there -- a headline in one language
over the text of another is the page nobody wants. Words with no title of
their own are fine: that is an untitled post, named from its own first
sentence, in its own language.

A translation may carry `title`, `content` and `excerpt`, and nothing
else. The date, the tags, the series, the pin and the state belong to the
post and hold in every language at once -- so a post cannot be published
in one language and a draft in another.

Write one with `./blog.sh translate <slug> --lang de` (see
[operations.md](operations.md#writing-a-post-in-another-language)); the
editor shows the title and the body, because that is all there is to it.

### What happens to a post nobody has translated

It is shown, not hidden. It stays in the other language's listing, and the
link on it leads to the address the post actually has -- so the same words
never stand at two addresses, and nothing needs a `canonical`.

The switcher is a chip in the banner's corner, beside the light/dark
button: which language you read the site in is a choice about this visit,
like which mode you read it in, and it belongs where that choice already
lives rather than in the menu, which it breaks in two. It shows language
CODES (`CS/DE/EN`) with the language a click leads to named in the title,
the way the button beside it shows `☀︎/☾︎` and says what it does in a
title. A click anywhere on the chip moves to the next language and wraps
around at the end -- one target, like the button, rather than a row of
small ones to aim at.

The switcher offers every language the site publishes. A language with
nothing of the current post in it leads to that language's front page
rather than to a page that is not there. What the `hreflang` alternates
name is narrower and on purpose: only addresses that exist. A site that
promises a crawler an address it never wrote sends readers from a search
result to its own 404.

### Building and deploying

`./blog.sh rebuild` produces every language the site publishes, in one go
and under one lock, into a single tree -- so the deploy that follows sees
one site and nothing has to be merged afterwards. Each language's build
sweeps only its own root, which is how two of them can share a tree
without carrying each other away.

### The address in each language

A translated post is served under an address of its own:
`/de/posts/2026/mehrsprachiger-blog/`, not the Czech slug with a German
prefix. An address is read by people, and half of it in a language they
do not read is the half that says what the piece is about.

It is made from the translated title the first time the translation is
written, and then left alone -- a post's own slug works that way for the
same reason: an address that follows a title somebody corrected is an
address that breaks every link to it. To choose one, put it in the
header the `translate` editor opens:

```
---
title: Mehrsprachiger Blog
slug: mehrsprachiger-blog
---
```

Two posts cannot share an address in one language: the command says whose
it already is and leaves you in the header to pick another.

🪤 **The post's own `slug` is not this.** It names the post's file and its
media directory -- identity, which does not change with the language
somebody reads in. Changing a translated address changes where that
language serves the post and nothing else; no redirect is left behind, so
it is worth choosing before anybody links to it.

### When a language has nothing for a post

It is shown anyway, in the nearest language that does have it, and the
link on it goes to that copy. Which language is nearest is yours to say:

```yaml
site:
  lang: en
  locales: [en, cs, de]
  fallback:
    de: [cs]
```

A German page with no German words then carries the Czech ones and links
to the Czech page, rather than the English ones the site would otherwise
fall back to. Say nothing and the site's own language stands in, which is
what every site does today.

The words and the address come from the same answer, always: Czech words
under a link to the English page would be worse than either on its own.
And the chain never builds a page -- a language has a page only for a
post that has words in it, so the same text never stands at two
addresses.

### Seeing what is written and what is not

```bash
./blog.sh check --languages
```

A row per post, a column per language: a tick where it is written, a half
circle for a title with no text yet, a dot where that language has
nothing. Only on request, because on an archive of thousands it is a
document rather than a summary -- the ordinary `check` is read for what is
wrong, and a post that exists in one language is not wrong.

One state in it is a fault and is reported by an ordinary `check`: two
posts asking for one address in one language. `translate` refuses to
write that, so it arrives by hand or from an import -- and the build
would serve one of them and drop the other without a word.

### Publishing a post that is not in every language

`publish` and `schedule` refuse it, name the languages it has no words in
and offer `--allow-partial` in the same sentence. A site that publishes
in several languages usually means to publish in all of them at once, and
the exceptions are worth saying out loud rather than discovering later.

The cron that publishes the queue never asks: a post got there through
`schedule`, where somebody already answered this.

### Pages

A page (`About`, `Contact`) is translated exactly as a post is, and is
the thing a reader of the other language reaches for first. Its address
has no year in it, so the translated one is a root of that language:
`/de/ueber-mich/`. That is where the engine writes its own names too, so
a translated page cannot be addressed `assets` or `write` any more than
an untranslated one can -- the refusal says so and leaves you in the
header to pick another.

### The menu

The menu is built once per language, and each kind of entry answers
differently:

| the entry | in `/de/` |
|---|---|
| the default menu (`All`, the types) | the German listings |
| `tag:` | the tag's German listing |
| `url:` naming a post or a page | that piece's German address, which is a different slug -- or the one copy of it, if it has no German words |
| `url:` naming a listing the engine builds (`/search/`, `/archive/`) | its German copy |
| anything else -- an address off the site, a file you put there yourself | exactly as written |

The one to watch is the fourth row: `url: /o-mne/` is not turned into
`/de/o-mne/`, because the German page is at `/de/ueber-mich/`. The item
follows the piece rather than the spelling.

### A link post

The link a link post is about belongs to the post, not to a language: it
is the same page whatever language you read the write-up in. So it is not
in the translation editor, and every language's page carries it. Write
the words under it and nothing else.

### What is not there yet

- **Pictures in a translation.** Media belong to the post and its
  languages share them; add them with `edit`.
- **Tags and series names are not translated.** A tag is the word it is,
  in every language. A post that wants a German tag as well as a Czech
  one carries both.

## Submitting

A pull request with the one or two files is enough. Say whether you are a
native speaker; a locale reviewed by one is marked as shipped in the
README, others as community drafts. When the engine later grows new keys,
they arrive in English via the fallback -- your locale keeps working and
can catch up whenever.
