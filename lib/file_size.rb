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
  def human(bytes)
    value = bytes.to_i
    return nil unless value.positive?
    return "#{value} B" if value < 1000
    return "#{(value / 1000.0).round} kB" if value < 1_000_000

    format('%.1f MB', value / 1_000_000.0).sub('.0 ', ' ')
  end
end
