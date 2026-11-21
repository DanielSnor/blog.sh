# frozen_string_literal: true

# The editor the engine opens when nobody has named one ($EDITOR, $VISUAL):
# nano. Which nano, though, is not the same everywhere.
#
# GNU nano takes --softwrap --atblanks --trimblanks: a paragraph stays the
# one line it is, wrapped on the screen only (see editor_round_trip in
# scripts/manage_post.rb for why that matters to Markdown).
#
# On macOS from 2026 `nano` is a link to `pico` (UW PICO 5.09). It knows none
# of those switches and does not fail on them either: it takes `--atblanks`
# for the name of a file, so the post was written into a file of that name in
# the current directory, and the engine read the post's own file back empty.
# Pico's own switch for "do not break lines" is -w, which GNU nano reads the
# same way (--nowrap), so -w is also the fallback for an old GNU nano that
# does not know the long switches.
module DefaultEditor
  GNU = %w[nano --softwrap --atblanks --trimblanks].freeze
  PLAIN = %w[nano -w].freeze

  module_function

  # The nano a shell would start, followed through its links, or nil.
  def nano_path(search = ENV['PATH'])
    search.to_s.split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?

      candidate = File.join(dir, 'nano')
      next unless File.file?(candidate) && File.executable?(candidate)

      return File.realpath(candidate)
    rescue SystemCallError
      next
    end
    nil
  end

  # Whether `nano` here is really pico. Told by the file the link leads to,
  # never by running it: pico has no --version, and asked for one it opens a
  # file called "--version".
  #
  # A link is not the only way to it (second fleet over 1.12, 03/1): a
  # hard link has no target to read, so it is compared with the pico beside
  # it; a small script that hands over to pico (`exec .../pico "$@"`) is
  # read, not run. Either was taken for GNU nano, got its long switches, and
  # pico wrote the post into a file called --softwrap.
  def pico?(search = ENV['PATH'])
    path = nano_path(search)
    return false unless path
    return true if File.basename(path).start_with?('pico')

    beside = File.join(File.dirname(path), 'pico')
    return true if File.exist?(beside) && File.identical?(path, beside)

    script = File.open(path, 'rb') { |f| f.read(4096) }.to_s
    script.start_with?('#!') && script.match?(%r{(?:\A|[\s/"'])pico(?:[\s"']|\z)})
  rescue SystemCallError
    false
  end

  # The words to start it with, before the file's path.
  def argv(search = ENV['PATH'])
    pico?(search) ? PLAIN : GNU
  end
end
