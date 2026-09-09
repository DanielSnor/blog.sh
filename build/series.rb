# frozen_string_literal: true

# build/series.rb -- which posts belong together, and in what order.
#
# A series is the one relationship in this archive that a post declares
# about OTHER posts, so it is the one thing here that cannot be worked
# out from a single file. Three functions hold it: what a post says its
# series is, what that series is called as an address, and what order
# its parts go in when some of them are numbered and some are not.
#
# The ordering is the subtle one and the reason this is worth its own
# file: a numbered part is INSERTED at the position it claims among the
# unnumbered ones, rather than sorted with them, and three places in the
# engine have to agree about that -- the build, the CLI and the draft
# preview. This is where the build`s answer lives.
module Series
  module_function

  # Which series a post belongs to, the posts in it, and where this one sits
  # -- filled in after the archive is read (SERIES_MAP below), so a post
  # rendered before that knows nothing and simply has no series.
  #
  # Ordered by date unless a post says otherwise with series_part. Publishing
  # out of order is rare enough that the date is the right default and wrong
  # often enough that there has to be a way to say so.
  def series_context(post)
    slug = series_slug_of(post)
    return [nil, [], nil] if slug.nil? || !defined?(SERIES_MAP)

    in_series = SERIES_MAP[slug] || []
    index = in_series.index { |p| p.equal?(post) }
    index ? [slug, in_series, index] : [nil, [], nil]
  end

  def series_slug_of(post)
    name = post['series'].to_s.strip
    return nil if name.empty?

    slug = Slug.slugify(name)
    slug.empty? ? nil : slug
  end

  # The reading order of one series: the parts that carry no number keep
  # their chronology, and a part that names a position is put AT that
  # position among them.
  #
  # Until 1.7 this was a sort key, [has-a-number, the-number, date], which
  # read the number as "ahead of everything undated" rather than as a
  # position. The case the number exists for came out backwards: the docs'
  # own scenario -- parts 1, 2, 4, 5 written in order, then the missing
  # part 3 written last and told "3" -- put part 3 at the front and
  # relabelled the two real first parts 2 and 3. The listing, the "part N
  # of M" note and the prev/next chain all read this list, so all three
  # said it, and the CLI went on showing the number the post actually
  # carries, which is what let the two disagree out loud.
  #
  # Insertion rather than a sort key, because a position is a fact about
  # the list and not about the post: with two numbered parts in a series,
  # "3" means the third slot once "2" has taken the second, and no key
  # computed from one post alone can know that.
  def series_in_order(group)
    # The archive's own tiebreak (see the sort of `posts` below), so that
    # two parts stamped the same second cannot swap places between builds.
    by_date = ->(post) { [post_time(post), post['slug'].to_s] }
    claimed = group.group_by { |post| Integer(post['series_part'], exception: false) }
    ordered = (claimed.delete(nil) || []).sort_by(&by_date)
    # Ascending, so each insertion lands in a list whose earlier slots are
    # already filled -- part 5 has to count the post that part 2 put in
    # front of it. A whole equal-numbered group at once, so that two posts
    # claiming the same slot keep their own date order instead of the
    # second shoving the first aside.
    #
    # The floor is the slot after the last number already placed, and it is
    # what keeps a bigger number from landing in front of a smaller one
    # when the numbers do not add up: parts 1, 1 and 2 have three posts for
    # two slots, and without it part 2 took the slot the second part 1 was
    # standing in. It is also what makes this identical to the old sort for
    # a series where every part is numbered -- there the floor is always
    # the end of the list, so every group is simply appended in order.
    # A number below the first position, or past the last, is one the
    # series does not have; the clamp gives it the nearest one it does.
    floor = 0
    claimed.sort_by(&:first).each do |part, claimants|
      at = (part - 1).clamp(floor, ordered.size)
      claimants = claimants.sort_by(&by_date)
      ordered.insert(at, *claimants)
      floor = at + claimants.size
    end
    ordered
  end
end
