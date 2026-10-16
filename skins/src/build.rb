# frozen_string_literal: true

# skins/src/build.rb -- the skins of the Minimal family, made from the
# skin they stand on and a layer of their own.
#
#   ruby skins/src/build.rb            writes every variant into skins/
#   ruby skins/src/build.rb --check    says which are not what their
#                                      sources make, and exits 1 if any
#
# A variant of minimal is minimal whole with its own layer after it: the
# family shares one head, one menu, one foot, and a variant changes how a
# page of posts is laid out. So the file a site wears -- skins/<name>.css,
# chosen with `site.skin:` like any other -- is made here rather than
# written: the base is read from skins/, the layer from skins/src/<layer>,
# and a change to the base reaches every variant the next time this runs.
# The suite runs it with --check, so a base changed without its variants
# being made again does not get past it.
#
# A layer file begins with the variant's own head comment, which goes
# first in what is made; the rest of the file goes after the base. The
# base's own head comment is left out -- the variant says what it is.
#
# Terminal stands on classic rather than on minimal: it was written as one
# stylesheet over classic and says everything minimal would. Its recipe
# takes classic less every declaration the layer sets again for the same
# selector under the same @media (one that is not !important) -- such a
# declaration can never win -- the way minimal's own part one was made.
# And its layer spells two long lists of counts as @C99@ and @C9@, which
# are written out here so the source stays readable.
#
# Pictorial hangs a wall of pictures where minimal's listing stood, and
# keeps one card of it a row: the lead of the front page when it has no
# picture. So minimal's own rules for a post in a listing (part two of
# minimal.css; part one is classic's, which every tile still stands on)
# are narrowed to that card, inside :where() so each weighs what it
# weighed, and the layer's rules for a tile are kept off it.

ROOT = File.expand_path('../..', __dir__)
SKINS = File.join(ROOT, 'skins')

VARIANTS = {
  'minimal-literal' => { base: 'minimal', layer: 'literal.css' },
  'minimal-terminal' => { base: 'classic', layer: 'terminal.css', reduce: true, counts: true },
  'minimal-pictorial' => { base: 'minimal', layer: 'pictorial.css', rowcard: true }
}.freeze

def read(path)
  File.read(path, encoding: 'utf-8')
end

# The first /* ... */ of a stylesheet, and everything after it.
def head_and_rest(css, name)
  css = css.lstrip
  abort "#{name}: does not begin with its head comment" unless css.start_with?('/*')
  close = css.index('*/') or abort "#{name}: its head comment is never closed"
  [css[0, close + 2], css[(close + 2)..].to_s]
end

# [data-count="1"], [data-count="2"], ... up to n.
def counts(n)
  (1..n).map { |i| %([data-count="#{i}"]) }.join(', ')
end

COMMENT = %r{/\*.*?\*/}m.freeze

# Comments out of the way of the braces and semicolons a rule is found by:
# each becomes a placeholder holding neither.
def mask(css)
  saved = []
  [css.gsub(COMMENT) { saved << Regexp.last_match(0); "\u0000#{saved.size - 1}\u0000" }, saved]
end

def unmask(text, saved)
  text.gsub(/\u0000(\d+)\u0000/) { saved[Regexp.last_match(1).to_i] }
end

# [[media, selector, body_start, body_end]] for every rule, one level of @media.
def rules(text)
  found = []
  scan = lambda do |from, to, media|
    i = from
    while i < to
      open = text.index('{', i)
      break if open.nil? || open >= to

      depth = 1
      j = open + 1
      while depth.positive?
        depth += 1 if text[j] == '{'
        depth -= 1 if text[j] == '}'
        j += 1
      end
      prelude = text[i...open].split(/[;}]/).last.to_s.gsub(/\u0000\d+\u0000/, '').gsub(/\s+/, ' ').strip
      if prelude.start_with?('@media')
        scan.call(open + 1, j - 1, prelude)
      elsif !prelude.start_with?('@')
        found << [media, prelude, open + 1, j - 1]
      end
      i = j
    end
  end
  scan.call(0, text.length, '')
  found
end

def properties(body)
  body.gsub(/\u0000\d+\u0000/, '').split(';').map { |d| d.split(':', 2) }.select { |d| d.size == 2 }.map { |p, _| p.strip.downcase }
end

# The base less every declaration the layer sets again for the same
# selector under the same @media, unless the base's is !important. A rule
# left with nothing goes whole -- its selector list from the last brace or
# semicolon before it, comments between included, so a list written over
# several lines cannot be cut in half and glued to the next rule.
def reduce(base, layer)
  text, saved = mask(base)
  ltext, = mask(layer)
  over = Hash.new { |h, k| h[k] = [] }
  rules(ltext).each { |media, sel, a, b| over[[media, sel]].concat(properties(ltext[a...b])) }
  edits = []
  rules(text).each do |media, sel, a, b|
    props = over[[media, sel]]
    next if props.empty?

    kept = text[a...b].split(/(?<=;)/).reject do |part|
      name, value = part.gsub(/\u0000\d+\u0000/, '').split(':', 2)
      value && props.include?(name.strip.downcase) && !value.include?('!important')
    end
    edits << [a, b, kept.join]
  end
  edits.sort_by { |a, _, _| -a }.each { |a, b, body| text[a...b] = body }
  loop do
    empty = rules(text).select { |_, _, a, b| text[a...b].strip.empty? }
    break if empty.empty?

    empty.sort_by { |_, _, a, _| -a }.each do |_, _, a, b|
      start = text.rindex(/[;{}]/, a - 2) || -1
      text[(start + 1)..b] = ''
    end
  end
  text.gsub!(/@media[^{};]*\{\s*\}/, '')
  unmask(text, saved).gsub(/\n{3,}/, "\n\n")
end

# The one card of a listing that stays a row in pictorial.
ROWCARD = 'body.page-first main:has(> .listing-heading--home) > :is(.post-list-item--lead, :first-of-type)' \
          ':not(:has(.content > figure:first-child, .content > .photo-grid:first-child))'

# A stylesheet as its top-level pieces: [[kind, text]], kind :comment,
# :rule, :at or :ws.
def split_top(css)
  out = []
  i = 0
  n = css.size
  while i < n
    if css[i, 2] == '/*'
      j = css.index('*/', i) + 2
      out << [:comment, css[i...j]]
    elsif css[i] =~ /\s/
      j = i
      j += 1 while j < n && css[j] =~ /\s/
      out << [:ws, css[i...j]]
    else
      j = i
      depth = 0
      kind = css[i] == '@' ? :at : :rule
      while j < n
        if css[j, 2] == '/*'
          j = css.index('*/', j) + 2
          next
        end
        c = css[j]
        if c == '{'
          depth += 1
        elsif c == '}'
          depth -= 1
          if depth.zero?
            j += 1
            break
          end
        elsif c == ';' && depth.zero?
          j += 1
          break
        end
        j += 1
      end
      out << [kind, css[i...j]]
    end
    i = j
  end
  out
end

def listing_selector?(sel)
  sel.include?('.post-list-item') && !sel.include?('search-result')
end

def to_rowcard(sel)
  sel.sub(/\.post-list-item(?![\w-])/) { ".post-list-item:where(#{ROWCARD})" }
end

# Every selector of a rule that speaks of a post in a listing, narrowed to
# the row card; @media and the like are gone into.
def narrow(css)
  split_top(css).map do |kind, text|
    case kind
    when :rule
      sel, body = text.split('{', 2)
      kept = sel.gsub(COMMENT, '').split(/,(?![^(]*\))/).map(&:strip).map { |x| listing_selector?(x) ? to_rowcard(x) : x }
      kept.empty? ? '' : "#{kept.join(",\n")} {#{body}"
    when :at
      if text =~ /\A@(media|supports|container)\b/
        pre, rest = text.split('{', 2)
        inner = narrow(rest[0...rest.rindex('}')])
        inner.strip.empty? ? '' : "#{pre}{#{inner}}"
      else
        text
      end
    else
      text
    end
  end.join.gsub(/\n{3,}/, "\n\n")
end

def make(name, recipe)
  _, base = head_and_rest(read(File.join(SKINS, "#{recipe[:base]}.css")), "#{recipe[:base]}.css")
  head, layer = head_and_rest(read(File.join(__dir__, recipe[:layer])), recipe[:layer])
  layer = layer.gsub('@C99@') { counts(99) }.gsub('@C9@') { counts(9) } if recipe[:counts]
  abort "#{name}: a count list left unwritten" if recipe[:counts] && layer.include?('@C')
  base = reduce(base, layer) if recipe[:reduce]
  if recipe[:rowcard]
    two = base.index('/* ---- part two') or abort "#{name}: the base has no part two to narrow"
    base = base[0...two] + narrow(base[two..])
    layer = layer.gsub(/main > \.post-list-item(?![\w-])/) { "main > .post-list-item:not(:where(#{ROWCARD}))" }
  end
  abort "#{name}: the base carries font files; a skin uses the faces the engine ships" if base.include?('@font-face')
  out = "#{head}\n\n#{base.strip}\n\n#{layer.strip}\n"
  abort "#{name}: braces do not balance" unless out.count('{') == out.count('}')
  out
end

# Run, it makes the files; required (the suite does), it only lends its
# pieces.
if $PROGRAM_NAME == __FILE__
  check = ARGV.include?('--check')
  stale = []
  VARIANTS.each do |name, recipe|
    path = File.join(SKINS, "#{name}.css")
    made = make(name, recipe)
    if check
      stale << name unless File.file?(path) && read(path) == made
    elsif !File.file?(path) || read(path) != made
      File.write(path, made, encoding: 'utf-8')
      puts "skins/#{name}.css: #{made.lines.size} lines"
    end
  end
  if check && stale.any?
    warn "not what skins/src makes of them: #{stale.join(', ')} -- run ruby skins/src/build.rb"
    exit 1
  end
end
