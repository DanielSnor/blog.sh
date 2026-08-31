# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

# A post that arrived from somewhere else: one ZIP holding a markdown file
# and the pictures its text refers to, base64-encoded, on standard input.
#
# This is the guard between a network and the archive, and it is here --
# in Ruby, in lib/, under the same test suite as everything else -- rather
# than in the shell script that receives it, because two audits of that
# script found nine and then twelve blocking faults and NOT ONE of them
# was a mistake about security. They were all mistakes about bash:
#
#   * `mkdir -p` adopts a name that already exists and follows a symlink
#     through it, so a planted link turned staging into arbitrary write
#   * awk's field rebuild pads a record, so `photo.jpg` and
#     `sub/photo.jpg` compared as different while unzip flattened them
#     into one and the later silently replaced the earlier
#   * `ulimit -f` bounds each file rather than the total, so four hundred
#     entries just under the limit walked past it
#   * a glob does not see a name beginning with a dot, so a picture was
#     unpacked, counted, and never staged
#
# Every one of those is a place where the line does not do what it looks
# like it does. `File.lstat` means `File.lstat`.
#
# unzip is the one outside tool left, and only to extract: what it
# produced is then measured, counted and typed here.
module Bundle
  # A bundle this may not accept. `code` is the stable string a program
  # branches on -- the same vocabulary the engine's own refusals use, so a
  # caller reads one set of names and not two.
  class Rejected < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  # Kept settable under the names the shell version used, because an
  # operator whose phone takes large photographs is the person who needs
  # to change them and the guide already names them.
  MAX_MB = (ENV['BLOGSH_MAX_MB'] || 24).to_i
  MAX_UNPACKED_MB = (ENV['BLOGSH_MAX_UNPACKED_MB'] || 120).to_i
  # A bundle is ONE post. A thousand entries is not a post with pictures,
  # it is something else, and every entry costs a stat and a copy.
  MAX_ENTRIES = 64

  module_function

  # Takes the base64 text, returns [markdown_filename, staging_directory].
  #
  # The staging directory is made with Dir.mktmpdir INSIDE incoming/: an
  # unguessable name that cannot be pre-empted and is never reused, which
  # is what the pid-named directory failed at in both directions.
  def unpack(text, incoming_dir)
    raise Rejected.new('empty_input', 'Nothing arrived on standard input.') if text.to_s.strip.empty?

    bytes = decode(text)
    weigh('too_large', bytes.bytesize, MAX_MB)

    Dir.mktmpdir('blogsh-bundle') do |work|
      archive = File.join(work, 'bundle.zip')
      File.binwrite(archive, bytes)
      unpacked = extract(archive, File.join(work, 'unpacked'))
      stage(unpacked, incoming_dir)
    end
  end

  # Strict, so a stray character is a refusal rather than silently skipped
  # bytes that then fail as a broken archive. (BSD base64 skips what it
  # does not recognise; GNU refuses. One answer on both.)
  # Whitespace out first, then STRICT. `base64` wraps its output at
  # seventy-six columns and a shortcut adds a newline of its own, so a
  # decoder that refuses whitespace refuses every real bundle -- while a
  # lenient one silently SKIPS anything it does not recognise, which is
  # how rubbish became a broken archive instead of a plain "that is not
  # base64". Strip the one, refuse the other.
  def decode(text)
    text.gsub(/\s+/, '').unpack1('m0')
  rescue ArgumentError
    raise Rejected.new('bad_base64', 'Input is not valid base64.')
  end

  def weigh(code, size, limit_mb)
    return if size <= limit_mb * 1_048_576

    raise Rejected.new(code, "Bundle is #{size / 1_048_576} MB, the limit is #{limit_mb} MB.")
  end

  # unzip -j, so a stored path cannot climb out of the directory. The
  # names it declares are then counted against the files that appeared:
  # anything that swallowed anything else -- a subdirectory entry meeting
  # a root one, two spellings a filesystem folds together, a pair that
  # differ only in unicode normalisation -- shows up as a file that is
  # missing, whatever the reason was. Deducing collisions from the names
  # themselves was tried and got them wrong twice.
  def extract(archive, into)
    FileUtils.mkdir_p(into)
    declared = names_in(archive)
    raise Rejected.new('not_a_zip', 'Input is not a readable ZIP archive.') if declared.empty?

    if declared.size > MAX_ENTRIES
      raise Rejected.new('too_many_files', "The bundle holds #{declared.size} files; #{MAX_ENTRIES} is the most a post may carry.")
    end

    # Exit 1 is a WARNING with every file correctly on disk; only above
    # that is a failure. Asked of the result rather than of the status
    # wherever possible.
    system('unzip', '-o', '-j', '-q', '-d', into, archive, out: File::NULL, err: File::NULL)
    landed = Dir.children(into).map { |name| File.join(into, name) }
    raise Rejected.new('not_a_zip', 'Input is not a readable ZIP archive.') if landed.empty?

    check_entries(landed, declared.size)
    into
  end

  def names_in(archive)
    IO.popen(['unzip', '-Z1', archive], err: File::NULL, &:read).to_s
      .split("\n").reject { |name| name.empty? || name.end_with?('/') }
  rescue SystemCallError
    raise Rejected.new('no_unzip', 'This machine has no unzip.')
  end

  # lstat, not File.file?: file? follows a link and answers about its
  # target. A ZIP may hold a symlink, unzip restores it as one, and
  # copying it then reads whatever it points at -- which is how a bundle
  # of one entry published the installation's env.sh, deploy token and
  # all, to a public draft address.
  def check_entries(paths, declared_count)
    paths.each do |path|
      next if File.lstat(path).file?

      raise Rejected.new('bad_entry',
                         "The bundle holds something that is not an ordinary file: #{File.basename(path)}.")
    end
    if paths.size != declared_count
      raise Rejected.new('colliding_names', 'Two files in the bundle end up with the same name.')
    end

    weigh('unpacks_too_large', paths.sum { |path| File.size(path) }, MAX_UNPACKED_MB)
  end

  # One .md, and the pictures beside it.
  def stage(unpacked, incoming_dir)
    entries = Dir.children(unpacked)
    markdown = entries.select { |name| File.extname(name).casecmp('.md').zero? }
    raise Rejected.new('missing_markdown', 'The bundle holds no .md file.') if markdown.empty?

    if markdown.size > 1
      raise Rejected.new('many_markdown', "The bundle holds #{markdown.size} .md files, expected one.")
    end

    dir = Dir.mktmpdir('.receive-', incoming_dir)
    # The name is ours, not the bundle's. The sender's name reaches the
    # engine as an argument, so a file called `--json.md` was refused as
    # an option -- and the name decides nothing anyway, since a post is
    # addressed by its title.
    post = 'post.md'
    entries.each do |name|
      target = File.join(dir, name == markdown.first ? post : name)
      FileUtils.cp(File.join(unpacked, name), target)
      # Not the mode the archive carried: a phone that stored one as 000
      # made a file the engine could not read.
      File.chmod(0o644, target)
    end
    [post, dir]
  end
end
