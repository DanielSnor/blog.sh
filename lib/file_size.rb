# frozen_string_literal: true

# lib/file_size.rb -- the one place that knows how big is too big, and how
# to say a size out loud.
#
# ONE limit for every deploy backend, deliberately, even though the hosts
# differ wildly: GitHub Pages refuses a single file over 100 MiB, while a
# plain rsync target refuses nothing at all. The site has to stay portable
# between targets -- a post that saves today, while the site deploys to
# Surfer, must not turn out to be undeployable on the day someone points
# the same site at git pages. So the tightest supported target sets the
# rule for all of them, and there is no config key to loosen it: the same
# reasoning as the fixed JPEG quality in the HEIC converter, where a knob
# nobody asked for would outlive the question that prompted it.
#
# Decimal, not binary: 100_000_000 sits ~4.7% below GitHub's 100 MiB, so
# the engine refuses before the host does -- which is the entire point of
# refusing early. Binary units would be more correct and less useful:
# nobody weighing a download cares about the difference between MB and MiB.
module FileSize
  HARD_LIMIT = 100_000_000
  SOFT_LIMIT = 50_000_000

  module_function

  def classify(bytes)
    value = bytes.to_i
    return :hard if value >= HARD_LIMIT
    return :soft if value >= SOFT_LIMIT

    :ok
  end

  # nil, not "0 B", when there is nothing to report: an attachment card
  # prints a size only when one is known, and nil is how it asks not to be
  # rendered at all.
  #
  # Rounds DOWN, never up. Rounding up let 99_999_999 B print as "100 MB",
  # so a file the engine had just allowed and a file it would have refused
  # read identically in the log -- and the soft warning contradicted itself
  # out loud: "(100 MB) -- under the 100 MB limit". The classification was
  # right either way (it counts bytes, not text), but a size that reads as
  # the limit itself while being under it is the kind of detail someone
  # debugging a refused deploy has no reason to distrust. Rounding down
  # means the printed number is never larger than the file, so it can never
  # claim a limit has been reached before it has.
  def human(bytes)
    value = bytes.to_i
    return nil unless value.positive?
    return "#{value} B" if value < 1000
    return "#{value / 1000} kB" if value < 1_000_000

    # Integer division on purpose: (value / 100_000.0).floor would hand
    # 2_900_000 back as 28 (28.999999999999996 floored), and a size that
    # shrinks by a tenth for no visible reason is worse than the rounding
    # this replaces.
    format('%.1f MB', (value / 100_000) / 10.0).sub('.0 ', ' ')
  end
end
