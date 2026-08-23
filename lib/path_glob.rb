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
end
