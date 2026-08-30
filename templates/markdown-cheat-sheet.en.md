---
title: Markdown Cheat Sheet
---
This site is written in Markdown — in the editor that `./blog.sh add` opens. It isn't full Markdown, it's a subset tailored to this engine. This page shows everything it supports: for each group, first the source as you'd type it, and right below it, how it comes out.

A link to this page is also in the in-editor help, so it's at hand while you write.

- [Paragraphs](#paragraphs)
- [Headings](#headings)
- [Emphasis](#emphasis)
- [Links](#links)
- [Lists](#lists)
- [Blockquotes](#blockquotes)
- [Chat](#chat)
- [Horizontal rule](#horizontal-rule)
- [Code blocks](#code-blocks)
- [Tables](#tables)
- [Images](#images)
- [Video](#video)
- [Audio](#audio)
- [Attachments](#attachments)
- [Escaping](#escaping)
- [Deliberately not supported](#deliberately-not-supported)

## Paragraphs

Paragraphs are separated by a blank line. A line break inside a paragraph collapses into a space when rendered — so if you want a new paragraph, leave an empty line between them. For a hard line break *inside* a paragraph, end the line with a backslash:

```
First line \
second line right under it.
```

First line \
second line right under it.

```
First paragraph.

Second paragraph.
```

First paragraph.

Second paragraph.

## Headings

Hashes at the start of the line, one to six by level. A heading has to sit on its own line.

```
# Level one heading
## Level two heading
### Level three heading
#### Level four heading
##### Level five heading
###### Level six heading
```

The first two levels are what this article uses for its own sections, so here's a sample from level three down:

### Level three heading

#### Level four heading

##### Level five heading

## Emphasis

```
**bold**, *italic*, ~~strikethrough~~ and `code inside a sentence`
```

**bold**, *italic*, ~~strikethrough~~ and `code inside a sentence`

Emphasis can be combined and nested:

```
**bold text with *italics* inside**
```

**bold text with *italics* inside**

They can also sit straight next to each other, with no space between. The
three stars in the middle are read as two: the closing pair for the bold,
and the single one that opens the italic. It works the other way round
too — one closes the italic, the pair opens the bold.

```
**bold***italic*
*italic***bold**
```

**bold***italic*
*italic***bold**

## Links

Text in square brackets, address in round ones. A title in quotes can follow the address — it shows up as a tooltip on hover.

```
[Example](https://example.com)
[Example with a title](https://example.com "Tooltip on hover")
```

[Example](https://example.com) and [Example with a title](https://example.com "Tooltip on hover")

An address written directly in a sentence turns into a link by itself, no markup needed:

```
I write about it at https://example.com regularly.
```

I write about it at https://example.com regularly.

## Lists

Bullets start with a dash or an asterisk, an ordered list with a number and a period. No blank line between items — that would end the list.

```
- first bullet
- second bullet
- third bullet
```

- first bullet
- second bullet
- third bullet

```
1. first item
2. second item
3. third item
```

1. first item
2. second item
3. third item

A task list marks items with square brackets — rendered as checkboxes (read-only; a visitor can't tick your to-dos):

```
- [x] write the post
- [ ] publish it
```

- [x] write the post
- [ ] publish it

The numbers don't matter, they're renumbered when rendered. A nested list is indented by two spaces:

```
- fruit
  - apple
  - pear
- vegetables
  1. carrot
  2. parsley
```

- fruit
  - apple
  - pear
- vegetables
  1. carrot
  2. parsley

## Blockquotes

Every line of a quote starts with `>`.

```
> Begin at the beginning, the King said gravely,
> and go on till you come to the end: then stop.
```

> Begin at the beginning, the King said gravely,
> and go on till you come to the end: then stop.

A last line opening with an em dash (or `--`) becomes the attribution:

```
> Begin at the beginning, and go on
> till you come to the end: then stop.
> — Lewis Carroll
```

> Begin at the beginning, and go on
> till you come to the end: then stop.
> — Lewis Carroll

## Chat

A dialogue goes into a `chat` fence, one line per statement — the speaker's
name before the colon. A line without a colon continues the previous one.

```
Watson: What does it mean?
Holmes: Elementary.
```

Written as:

    ```chat
    Watson: What does it mean?
    Holmes: Elementary.
    ```

## Horizontal rule

A line of three or more dashes, on its own.

```
---
```

---

## Teaser

A line reading `//--more--//`, on its own, splits the post in two. What is above it is the teaser: exactly that shows up in the listing on the front page, in the announcement on your social network, and on the link card. What is below it is read by whoever opens the post.

Without this line the engine cuts a teaser off the start of the text itself -- and a machine cut rarely lands where it should.

Write it exactly like that, no inner spaces and in lower case. Written any other way it is an ordinary note and disappears when the post is saved. Blank lines around it are not required -- a line holding nothing else is enough.

```
The opening paragraph, the one meant to catch the eye.

//--more--//

The rest of the post, which the listing does not show.
```

---

## Code blocks

Code is wrapped between lines of three backticks — \`\`\`. A language can follow the first triple; it's cosmetic only, it doesn't change the rendering. Nothing inside the block is formatted, asterisks and similar characters stay literal.

```ruby
def greet(name)
  puts "Hello #{name}!"
end
```

A wide block scrolls within itself instead of stretching the page:

```
rsync -avz --delete --rsync-path="sudo rsync" -e "ssh -p 202" ./ user@server:/some/long/path/deep/down/
```

## Tables

The first line is the header, the second a dash separator, the rest is data. Colons in the separator set column alignment: `:---` left, `---:` right, `:---:` center.

```
| Column | Right | Center |
| --- | ---: | :---: |
| first row | 6228 | 1 |
| second row | ~435 | **7 to 9** |
```

| Column | Right | Center |
| --- | ---: | :---: |
| first row | 6228 | 1 |
| second row | ~435 | **7 to 9** |

Regular formatting works inside cells, links included. A wide table scrolls within itself, same as a code block.

Start with the separator instead and the table has no header at all -- every line is data. Useful for a list of pairs, or a table used for layout, where a heading would be a lie. Write that first line with the outer pipes, exactly as below: it is what tells a table with no header from a bullet list whose first item happens to be punctuation.

```
| --- | --- |
| Ctrl + c | Copy |
| Ctrl + v | Paste |
```

| --- | --- |
| Ctrl + c | Copy |
| Ctrl + v | Paste |

## Images

An exclamation mark, alt text in square brackets, path in round ones. A title in quotes can follow the path — it shows as a caption under the photo.

```
![Alt text for screen readers](/path/to/photo.jpg)
![Alt text for screen readers](/path/to/photo.jpg "Caption under the photo")
```

An image has to sit on its own line, separated by blank lines. It can't be written mid-paragraph — saving stops and warns in that case.

The path can point anywhere on disk, the file gets copied automatically. A bare filename with no path is looked up in the `incoming/` directory — handy when writing from a phone: upload the photo over SFTP and reference it by name alone.

## Video

Two exclamation marks, otherwise same as an image. Works for a local file (.mp4, .mov, .m4v) and for a video address: YouTube, Vimeo, PeerTube, archive.org. **The caption is mandatory for a video.**

```
!![Video caption](/path/to/video.mp4)
!![Video caption](https://www.youtube.com/watch?v=jNQXAC9IVRw)
!![Video caption](https://vimeo.com/76979871)
!![Video caption](https://framatube.org/w/kkGMgK9ZtnKfYAgnEtQxbv)
```

!![The very first video on YouTube](https://www.youtube.com/watch?v=jNQXAC9IVRw)

A bare YouTube address on its own line does **not** turn into a player — it becomes an ordinary link. That's deliberate, so a video can also just be linked to.

## Audio

Same two exclamation marks as a video — the file extension tells them apart
(.mp3, .m4a, .ogg, .opus, .aac, .flac, .wav). **The caption is mandatory**,
and the file renders as a native player. The same line also takes a
Spotify, SoundCloud, Mixcloud, Funkwhale or Bandcamp address and turns it
into that platform's player. (For the last two the address alone isn't
enough, so saving the post asks the service once where its player is --
the only moment writing a post needs the network.)

```
!![Audio caption](/path/to/recording.mp3)
!![Audio caption](https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT)
!![Audio caption](https://soundcloud.com/nasa/sputnik-beep)
```

## Attachments

A line that is nothing but a link whose target is a bare filename turns
that file into a download card with its size on it -- the same shorthand
images use, so the file can be staged in `incoming/` and picked up by
name. Extensions that count: .pdf, .zip, .tgz, .epub, .txt, .md, .ics,
.gpx, .csv. A link to an address stays an ordinary link.

```
[Reading diary 2025](diary.pdf)
```

A post whose text is just a short line plus attachments is filed under
**Documents**; a full article that happens to attach its data stays an
article with a file on it.

## Escaping

To write a character that means something in Markdown, put a backslash in front of it.

```
\*not italics\*, the mask \*.mp4, \`backticks\` and \[square brackets\]
```

\*not italics\*, the mask \*.mp4, \`backticks\` and \[square brackets\]

Seven characters that carry meaning in Markdown can be escaped:

```
*   `   ~   [   ]   !   \
```

Before any other character the backslash stays as it is — so the d8-\ emoticon needs no special treatment.

## Deliberately not supported

These aren't missing — each was considered and turned down, mostly because
its cost lands on everyone who *doesn't* use it:

- underscore italics `_like this_` — underscores live inside ordinary text
  (file_names, snake_case); use asterisks
- code blocks indented with spaces — collides with nested-list indentation;
  use the three backticks
- headings underlined with `===` — a line of dashes already means a
  horizontal rule and the frontmatter delimiter
- nested quotes `>>`
- reference links `[text][id]` and footnotes

These render exactly as written, too.
