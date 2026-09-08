# frozen_string_literal: true

# lib/path_safety.rb -- one answer to "may this value become part of a
# filesystem path?", for every value the engine did not make itself.
#
# Slugs, draft tokens, receipt ids, media filenames and redirect targets
# all end up as arguments to File.join, and every one of them comes from
# somewhere a person can edit: a post JSON, a config, somebody else's
# export. Until this file existed each caller decided on its own, which
# meant several different answers and one missing one. The Jekyll importer
# hands back the slug from a blogsh: front matter unchanged, on the
# grounds that our own export wrote it, so a "../" in one travels all the
# way to File.join; the /write/ receipt id is checked against the same
# regex written out twice, once in the CLI and once in the build; and the
# checker's own slug test runs after the fact, when the directory is
# already there.
#
# Two rules the callers of this file follow:
#
# 1. Refuse, do not repair. File.basename would turn an unsafe slug into
#    a safe one, but a post's address is its public identity -- quietly
#    moving it is a broken link and no redirect to it. A bad value names
#    the post it came from and stops.
# 2. Ask before the operation, not instead of it. A checker that finds
#    the problem afterwards is a report; this is meant to sit in front of
#    the mkdir, the rename and the rm_rf.
module PathSafety
  # Raised by contained! when an operation would reach outside the tree it
  # belongs to. Not a user error: either an archive holds a value that
  # should never have been written, or a caller built a path wrong.
  class Escape < StandardError; end

  # What every filesystem the engine runs on allows for one component.
  # Callers with a tighter rule of their own keep it -- post slugs stop at
  # 200 bytes and that lives in Slug.pageable?, because a second copy here
  # is a copy that drifts.
  SEGMENT_MAX_BYTES = 255

  # draft_token and the /write/ receipt id are both SecureRandom.hex(8).
  TOKEN_LENGTH = 16

  # Separators, NUL and the C0 range. A newline in a filename is legal on
  # Unix and does arrive from deliveries and imports; nothing the engine
  # makes has one, and a name that cannot be printed in a warning cannot
  # be reported to the person who has to fix it. Backslash counts as a
  # separator here even on Unix, where it is a legal character: names
  # travel to Windows shares, rclone remotes and SFTP servers that read
  # it as one.
  UNSAFE_IN_SEGMENT = %r{[/\\\x00-\x1f\x7f]}

  module_function

  # True when the value can stand as ONE component of a path: not empty,
  # not hidden -- which also rules out "." and ".." -- no separator in it,
  # no control characters, and short enough to be a filename.
  def safe_segment?(value, max_bytes: SEGMENT_MAX_BYTES)
    text = value.to_s
    # A string carrying broken bytes cannot be matched against without
    # raising, so it is refused before the pattern rather than by it.
    return false unless text.valid_encoding?
    return false if text.empty? || text.bytesize > max_bytes
    return false if text.start_with?('.')

    !text.match?(UNSAFE_IN_SEGMENT)
  end

  # True when the value is a relative path made only of safe components:
  # what a redirect_from entry or a former_slugs pair may be. Absolute
  # paths, traversal and empty components ("a//b", "a/", "/a") are out.
  def safe_relative_path?(value, max_bytes: SEGMENT_MAX_BYTES)
    text = value.to_s
    return false unless text.valid_encoding?
    return false if text.empty? || text.start_with?('/', '\\')

    text.split(%r{[/\\]}, -1).all? { |part| safe_segment?(part, max_bytes: max_bytes) }
  end

  # Draft tokens and receipt ids: lowercase hex of a known length. They
  # are generated and never typed, so anything else is either a mistake
  # or somebody trying the directory above.
  def hex_token?(value, length: TOKEN_LENGTH)
    text = value.to_s
    return false unless text.valid_encoding?

    text.length == length && text.match?(/\A[0-9a-f]+\z/)
  end

  # Whether candidate is root itself or something underneath it.
  def within?(root, candidate)
    base = resolve(root)
    path = resolve(candidate)

    path == base || path.start_with?(base + File::SEPARATOR)
  end

  # within?, as a guard: hands the candidate back so it can be used
  # inline, raises when it would leave the tree. For the operations that
  # cannot be taken back -- rename, rm_rf, an upload that deletes what it
  # replaces.
  def contained!(root, candidate, what = 'path')
    return candidate if within?(root, candidate)

    raise Escape, "#{what} #{candidate.to_s.inspect} is outside #{root.to_s.inspect}"
  end

  # An absolute path with the symlinks of every existing directory in it
  # resolved. realpath needs what it is handed to exist and a destination
  # usually does not yet, so this resolves the deepest directory that IS
  # there and puts the rest back on. Both sides of within? come through
  # here, so a root given as /tmp/x and a candidate that resolves to
  # /private/tmp/x still compare on macOS, and a media directory
  # symlinked onto another volume is compared where it really is.
  #
  # What it does not do is resolve a symlink that is the last component
  # and does not exist yet. This runs before the write; it does not
  # replace the write's own errors.
  def resolve(path)
    full = File.expand_path(path.to_s)
    cursor = full
    tail = []

    until File.directory?(cursor)
      parent = File.dirname(cursor)
      return full if parent == cursor

      tail.unshift(File.basename(cursor))
      cursor = parent
    end

    real = begin
      File.realpath(cursor)
    rescue SystemCallError
      cursor
    end

    tail.empty? ? real : File.join(real, *tail)
  end
end
