# frozen_string_literal: true

# lib/account_id.rb -- what a fediverse account id may look like, shared
# by the two gates that refuse one (doctor and the style wizard) so they
# cannot drift apart.
#
# Mastodon hands out numeric ids. GoToSocial answers the very same API
# with 26-character ULIDs (01FHWK6JAZZ83J1BP6D3MA9BHR), Pleroma and
# Akkoma with flake ids -- letters and digits either way. What this
# check is really for is the one mistake people actually make: pasting
# the @handle (or the whole profile URL) into the field, after which the
# widget silently shows nothing. Handles are short or carry @ . : /, so:
# purely numeric of any length, or letters-and-digits of at least 16
# characters. A looser rule than "digits only", and that is the point --
# the old rule refused every valid GoToSocial id before the fetcher,
# which handles them fine, ever got to run.
module AccountId
  PLAUSIBLE = /\A(\d+|[0-9A-Za-z]{16,})\z/

  module_function

  def plausible?(value)
    value.to_s.match?(PLAUSIBLE)
  end
end
