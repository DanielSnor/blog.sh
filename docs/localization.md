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

### What the site looks like

The language in `site.lang` keeps the site root and every other one gets a
root of its own:

```
/                 the site's own language
/de/              every listing, tag, series, feed and post that has German words
/assets/          one copy, shared
/write/           one writing app, shared
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

### What is not there yet

- **A fallback chain.** A language falls back to the post's own text, not
  to a language you nominate.
- **Pictures in a translation.** Media belong to the post and its
  languages share them; add them with `edit`.

## Submitting

A pull request with the one or two files is enough. Say whether you are a
native speaker; a locale reviewed by one is marked as shipped in the
README, others as community drafts. When the engine later grows new keys,
they arrive in English via the fallback -- your locale keeps working and
can catch up whenever.
