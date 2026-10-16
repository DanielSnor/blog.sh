# frozen_string_literal: true

# lib/css_text.rb -- a stylesheet as a reader's browser needs it.
#
# The engine's stylesheets explain themselves: most rules carry the reason
# they exist, and the reasons outweigh the rules -- the classic skin is
# 86 kB written and 36 kB without them. The reasons are for whoever edits
# the file, never for the browser, so the build publishes the rules alone:
# 27 kB over the wire became about 7.
#
# Comments only. Whitespace is left as it was written, so the published
# file still reads -- somebody looking at it in the browser's tools sees
# the rules where they stand, one to a line, just without their notes.
module CssText
  module_function

  # Every /* ... */ outside a quoted string, and then the lines it leaves
  # empty; never more than one empty line in a row. A comment marker inside
  # a string -- `content: "/*"` -- is part of the string and stays. A
  # comment never closed runs to the end, as a browser reads it, and so
  # does a string. One pass of one pattern: a walk by index went through a
  # UTF-8 string from its start for every character it read, and minimal's
  # 175 kB took 1.8 s of every build where it now takes 3 ms.
  TOKEN = %r{("(?:\\.|[^"\\])*(?:"|\z)|'(?:\\.|[^'\\])*(?:'|\z))|/\*.*?(?:\*/|\z)}m.freeze

  def without_comments(css)
    out = css.gsub(TOKEN) { Regexp.last_match(1) || '' }
    "#{out.lines.map(&:rstrip).join("\n").gsub(/\n{3,}/, "\n\n").strip}\n"
  end
end
