# frozen_string_literal: true

# lib/share_targets.rb -- where a reader can carry a post away to.
#
# In lib/ rather than in build_blog.rb for the reason the icon table moved
# here too: doctor has to be able to say "that is not a name I know", and a
# list it cannot reach is a list it has to keep its own copy of. One copy
# went stale within a day of the last one being written.
module ShareTargets
  NAMES = %w[mastodon bluesky email copy system facebook linkedin threads x].freeze

  # The ones that only appear if the browser co-operates: mastodon needs
  # its script, copy needs a clipboard, system needs an OS share sheet. A
  # block made of nothing else is a heading over an empty row, so it
  # arrives hidden and the script decides.
  CONDITIONAL = %w[mastodon copy system].freeze
end
