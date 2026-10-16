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

ROOT = File.expand_path('../..', __dir__)
SKINS = File.join(ROOT, 'skins')

VARIANTS = {
  'minimal-literal' => { base: 'minimal', layer: 'literal.css' }
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

def make(name, recipe)
  _, base = head_and_rest(read(File.join(SKINS, "#{recipe[:base]}.css")), "#{recipe[:base]}.css")
  head, layer = head_and_rest(read(File.join(__dir__, recipe[:layer])), recipe[:layer])
  abort "#{name}: the base carries font files; a skin uses the faces the engine ships" if base.include?('@font-face')
  out = "#{head}\n\n#{base.strip}\n\n#{layer.strip}\n"
  abort "#{name}: braces do not balance" unless out.count('{') == out.count('}')
  out
end

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
