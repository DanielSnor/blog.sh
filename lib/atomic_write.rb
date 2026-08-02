# frozen_string_literal: true

require 'json'
require 'fileutils'

# lib/atomic_write.rb -- replace a file's contents, or leave the file
# exactly as it was.
#
# File.write opens with "w": it truncates the target FIRST and only then
# finds out it can't write (a full volume, a vanished mount, a killed
# container). What was a perfectly good post then sits on disk as 0 bytes
# -- the previous version destroyed, the new one never written, and after
# an `edit` the author's text has already left the editor's temp file.
# Nothing restores that: content.nosync/ isn't in git and nothing moved
# the post to trash/.
#
# Writing a sibling temp file and renaming it over the target makes the
# replacement all-or-nothing. The temp file has to live in the SAME
# directory as its target -- rename(2) is only atomic within one
# filesystem, so a temp in /tmp would silently degrade to a copy.
module AtomicWrite
  module_function

  def write(path, content)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = File.join(dir, ".#{File.basename(path)}.tmp#{Process.pid}")

    begin
      File.open(tmp, 'w') do |f|
        f.write(content)
        f.flush
        # Without fsync the rename can land before the data does, so a
        # power cut or a hard container stop can leave the new name
        # pointing at an empty file -- the very outcome this exists to
        # prevent.
        f.fsync
      end
      File.rename(tmp, path)
    rescue StandardError
      File.delete(tmp) if File.exist?(tmp)
      raise
    end

    path
  end

  def write_json(path, data)
    write(path, JSON.pretty_generate(data))
  end
end
