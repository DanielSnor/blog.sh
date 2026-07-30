# Adding a language

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
   | `nav`, `post`, `pagination`, `tag`, `type`, `index`, `search`, `markdown_page`, `ui` | site visitors |
   | `js` | site visitors -- shipped into the browser for client-rendered strings; `js.date_locale` is a BCP-47 tag (`de-DE`) and must agree with `date_format`, or server- and client-rendered dates diverge |
   | `cli` | authors -- `./blog.sh`, the wizard, `$EDITOR` hints |
   | `cron`, `import` | authors -- scheduled publishing and `./import.sh` |

2. **`templates/markdown-cheat-sheet.<lang>.md`** -- the source of the
   generated `/markdown/` syntax page. Optional: without it the page falls
   back to English wholesale. Translate the prose, keep the syntax examples
   as they are -- they are what the page exists to show.

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
./blog.sh preview                # read a post page, /search/, /markdown/
./blog.sh help                   # the CLI side
./blog.sh                        # the wizard menu
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

## Submitting

A pull request with the one or two files is enough. Say whether you are a
native speaker; a locale reviewed by one is marked as shipped in the
README, others as community drafts. When the engine later grows new keys,
they arrive in English via the fallback -- your locale keeps working and
can catch up whenever.
