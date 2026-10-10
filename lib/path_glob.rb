# frozen_string_literal: true

# lib/path_glob.rb -- list what is under a directory whose name is a NAME,
# not a pattern.
#
# Dir.glob reads its whole argument as a pattern, and File.join(DIR, '*',
# '*.json') hands it the installation's own absolute path as the first half
# of that pattern. Every glob metacharacter in that path is then live. An
# install in "~/Sites/blog [1]" -- the name a second copy of a download
# gets, or a folder somebody numbered by hand -- has its "[1]" read as a
# character class matching the one character "1", so the pattern describes
# a directory called "~/Sites/blog 1". Nothing is there. Dir.glob answers
# [] and calls it a day: no error, no warning, no path named anywhere.
#
# What that looked like from the outside: `build` reported "0 posts" over a
# full archive and wrote a site with nothing in it, `deploy` then refused
# with "public.nosync/ is empty" -- and refusing was the lucky ending. With
# --prune, or on a backend that commits whatever it is handed, a deploy
# that did not refuse would have pushed the emptiness live and taken the
# published site down with it. `check` meanwhile called the archive sound,
# because it could not see the posts either. Brackets are the loud case;
# "{" and "}" (a folder named "blog {old}") do the same thing more quietly,
# and a "*" or "?" in a path makes the glob match the WRONG directory
# rather than none at all.
#
# `base:` is the cure, because a base is a directory rather than a pattern:
# Dir.glob does not parse a character of it. Only the parts passed here as
# the pattern are read as one. The results come back relative to the base,
# so they are re-joined and every caller keeps the absolute paths it always
# had, in the same order -- the base is a common prefix, so sorting is
# unaffected.
#
# That leaves the other half of the join. A pattern like "#{slug}.json" is
# still half NAME -- the slug is somebody's post, not a wildcard -- and a
# slug of "foto[1]" put the same blindness one directory further in:
# `literal` is what makes such a piece stand for itself.
module PathGlob
  module_function

  # `dir` is a directory name, `parts` are the pattern. `flags` reaches
  # Dir.glob untouched (prune_public needs FNM_DOTMATCH to see the
  # dotfiles in public.nosync).
  #
  # An empty dir answers with nothing rather than reaching Dir.glob, where
  # an empty base means the working directory -- so a caller whose
  # directory went missing would have listed the cwd and had "/" pasted in
  # front of every name.
  def under(dir, *parts, flags: 0)
    base = dir.to_s
    return [] if base.empty?

    Dir.glob(File.join(*parts), flags, base: base).map { |rel| File.join(base, rel) }
  end

  # One piece of the PATTERN that is a name rather than a wildcard: a slug,
  # a filename, a directory somebody typed. Everything the engine itself
  # mints is [a-z0-9-] and needs none of this -- but a post file edited by
  # hand carries whatever was typed into it, an archive can be written by
  # something that is not this engine, and an old address an import records
  # in redirect_from is spelled the way the old site served it. check
  # passes all of those on purpose, because they break nothing on disk.
  # They broke the lookups instead: PathGlob.under(CONTENT_DIR, '*',
  # "foto[1].json") describes a file called "foto1.json", so props, delete,
  # restore and the address guard all answered "no such post" over a post
  # the build had just published, and the guard's "the address is free" is
  # the answer that overwrites it.
  #
  # A backslash in front of each metacharacter is how Dir.glob and
  # File.fnmatch spell "this character, itself" -- the same job rsync.rb's
  # literal() does for rsync's include rules, in that syntax's own
  # spelling. The backslash itself goes on the list, or a name carrying one
  # would escape whatever came next. It holds as long as nobody passes
  # File::FNM_NOESCAPE to `under`; nobody does.
  def literal(part)
    part.to_s.gsub(/[*?\[\]{}\\]/) { |char| "\\#{char}" }
  end

  # Whether what was found at `path` is the thing called `name`, to the
  # letter. A pattern with no wildcard in it is not looked up in a listing
  # but asked of the volume -- and a volume that folds case (a Mac's, by
  # default) answers yes to "Venku.json" where the file is venku.json. The
  # caller then went on with the name it had ASKED for: a post deleted as
  # "Venku" went to trash/2026/Venku and came back as Venku.json with the
  # slug `venku` inside, which the same archive on Linux cannot find under
  # either name. So the name is compared with what was found and with
  # what the folder lists, whichever of the two the volume's answer was
  # spelled as. An accent kept apart from its letter is still the same
  # name: that difference a volume may make by itself, and it is none.
  #
  # The bytes are UTF-8 whatever they are labelled: with no LANG a name
  # comes off the disk marked as something else, and two equal names
  # under two labels are not equal to Ruby.
  def named?(path, name)
    utf8 = ->(text) { text.to_s.dup.force_encoding(Encoding::UTF_8) }
    same = lambda do |one, other|
      one == other || (one.valid_encoding? && other.valid_encoding? && one.unicode_normalize(:nfc) == other.unicode_normalize(:nfc))
    end
    asked = utf8.call(name)
    return false unless same.call(utf8.call(File.basename(path.to_s)), asked)

    Dir.children(File.dirname(path.to_s)).any? { |held| same.call(utf8.call(held), asked) }
  rescue SystemCallError
    false
  end
end
