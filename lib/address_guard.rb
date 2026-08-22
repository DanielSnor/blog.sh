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

  # The file standing in the way of this write, or nil. Two questions, and
  # both of them have to be asked here, because five callers asked only one
  # of them each and each one asked the other's.
  #
  #   `path`  -- the FILE about to be written. A different post already
  #              there is overwritten with no trash, no version and no
  #              warning, and that is not hypothetical: a post whose file
  #              sits in one year's folder while its date puts its address
  #              in another (which the engine documents as ordinary) has a
  #              free address and an occupied path at the same time.
  #   the address -- which no path check can see, because a page is served
  #              at the root and a post follows its date, not its folder.
  #
  # Replacing the old File.exist? with the address check, rather than
  # adding to it, is how publish, edit, scheduling, restore and re-import
  # came to silently eat a live published post.
  #
  # `except` is the post's own file, which is never in its own way.
  def occupant(post, content_dir:, slug: nil, except: nil, path: nil)
    name = (slug || post['slug']).to_s
    return nil if name.empty?

    mine_now = except && File.expand_path(except)
    if path && File.exist?(path) && File.expand_path(path) != mine_now
      return path
    end

    wanted = PostAddress.collision_keys(post, slug: name)
    Dir.glob(File.join(content_dir, '*', "#{name}.json")).sort.each do |other|
      next if mine_now && File.expand_path(other) == mine_now

      # A file that will not read or parse still owns its address. Guessing
      # "empty" from an unreadable file is how a restore left behind by a
      # permission bit, or a copy the cloud has evicted, reads as free
      # space -- and the build stops on what gets written into it.
      candidate = begin
        JSON.parse(File.read(other, encoding: 'utf-8'))
      rescue StandardError
        return other
      end
      # Valid JSON that is not a post object is in the same position as a
      # file that will not parse: the build stops on it either way, and it
      # is certainly not free space. unreadable? says the same, and these
      # two answers have to agree.
      return other unless candidate.is_a?(Hash)

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
