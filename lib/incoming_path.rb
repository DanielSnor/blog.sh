# frozen_string_literal: true

# What "a file" means when somebody names one on the command line or in
# answer to a prompt.
#
# incoming/ is where anything meant for the site is dropped -- the one
# directory a separate upload account can write to, and where a phone
# sends its photos. A BARE filename -- a name with no slash in it at all
# -- is looked up there; anything else is a path and is used as given,
# which is what working from a Mac wants.
#
# One module rather than a copy per caller: the rules below are the kind
# that get half-remembered. `style.rb` had them for its wizard answers
# and `add <file>` needs exactly the same reading of exactly the same
# words -- a second copy would have been the place where a quoted path or
# a dragged file quietly stopped working for one of them.
module IncomingPath
  module_function

  # Returns an absolute path, or nil when the answer is empty.
  def resolve(answer, incoming_dir)
    path = answer.to_s.strip.gsub(/\A['"]|['"]\z/, '')
    return nil if path.empty?

    # Dragging a file from Finder into a terminal writes the spaces escaped
    # ("~/Mobile\ Documents/…"). Typed by nobody, produced by the most
    # natural gesture there is -- and refused as "no such file".
    path = path.gsub(/\\(.)/, '\1') if !exist?(path) && path.include?('\\')

    # ⚠️ basename == path, not dirname == '.'. Those agree on "clanek.md"
    # and disagree on "./clanek.md", where dirname is also "." -- so an
    # answer that pointed at the current directory ON PURPOSE was treated
    # as a bare name and served the incoming/ copy instead, silently, over
    # the file the caller had spelled out. A slash means a path.
    return absolute(path) unless File.basename(path) == path

    # symlink? as well as file?, because File.file? follows a link and so
    # says no to a broken one. A name that is THERE in incoming/ -- even
    # as a link pointing nowhere, which is what a half-finished upload
    # leaves behind -- is the name the author meant. Falling through to
    # the working directory instead answered "no such file: visi.md,
    # bare names are looked for in incoming/" about a name `ls incoming/`
    # shows in the first column.
    in_incoming = incoming_dir && File.join(incoming_dir, path)
    # Anything that EXISTS under that name is the name the author meant --
    # a directory or a broken link included, so that add can say "not a
    # file" about it rather than "no such file" about a name ls shows.
    if in_incoming && (File.exist?(in_incoming) || File.symlink?(in_incoming))
      in_incoming
    else
      absolute(path)
    end
  end

  # File.expand_path with the two ways it can turn a bad answer into a
  # backtrace taken away:
  #
  #   * "~nikdo/x.md" raises ArgumentError when there is no such user, and
  #     nothing on this path rescued it -- a typo in a home directory
  #     ended the command with a stack trace instead of "no such file".
  #   * a relative path was expanded against the INSTALL, because both
  #     wrappers cd there before starting ruby. So `add sub/clanek.md`
  #     from a script meant a file next to the engine, never the one next
  #     to the caller. BLOG_SH_PWD is where they were standing.
  def absolute(path)
    File.expand_path(path, base_dir)
  rescue ArgumentError
    # No ~user to expand: keep the answer as typed and let the caller
    # report it as the missing file it is.
    File.absolute_path(path, base_dir)
  end

  def base_dir
    from_wrapper = ENV['BLOG_SH_PWD'].to_s
    from_wrapper.empty? ? Dir.pwd : from_wrapper
  end

  # File.exist? without the ArgumentError, for the Finder-drag test above.
  def exist?(path)
    File.exist?(path)
  rescue ArgumentError
    false
  end
end
