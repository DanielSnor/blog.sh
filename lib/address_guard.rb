# frozen_string_literal: true

require 'json'
require_relative 'post_address'

# lib/address_guard.rb -- who already lives where this post is going.
#
# Six paths write a post into a year: publish (including the scheduler's
# cron), edit, scheduling a date, moving the queue, restoring from the
# trash and re-importing. Each of them asked `File.exist?` about the exact
# file it was about to write, which answers a narrower question than the
# one that matters. Two posts collide when they share a year and a slug --
# whatever FOLDER they sit in -- and two pages collide on their slug alone,
# because a page is served at the root with no year in its address.
#
# The build refuses to run on either, so a path that failed to see the
# collision did not merely overwrite something: it left an archive that
# will not build, and on the scheduler's path there is nobody at the
# keyboard to read the error. Deciding this in six places is how five of
# them stayed a step behind the sixth.
module AddressGuard
  module_function

  # The file already occupying one of the addresses this post would take,
  # or nil. `except` is the post's own file, which is never in its own way.
  def occupant(post, content_dir:, slug: nil, except: nil)
    name = (slug || post['slug']).to_s
    return nil if name.empty?

    wanted = PostAddress.collision_keys(post, slug: name)
    mine = except && File.expand_path(except)
    Dir.glob(File.join(content_dir, '*', "#{name}.json")).sort.each do |other|
      next if mine && File.expand_path(other) == mine

      # A file that will not read or parse still owns its address. Guessing
      # "empty" from an unreadable file is how a restore left behind by a
      # permission bit, or a copy the cloud has evicted, reads as free
      # space -- and the build stops on what gets written into it.
      candidate = begin
        JSON.parse(File.read(other, encoding: 'utf-8'))
      rescue StandardError
        return other
      end
      next unless candidate.is_a?(Hash)

      return other if (PostAddress.collision_keys(candidate) & wanted).any?
    end
    nil
  end

  # True when a file cannot be read or is not a post at all. The occupant
  # is refused either way -- an address whose owner nobody can read is
  # still not free -- but "another post already uses that slug" would be
  # a claim about a file this process never managed to look at.
  def unreadable?(path)
    !JSON.parse(File.read(path, encoding: 'utf-8')).is_a?(Hash)
  rescue StandardError
    true
  end
end
