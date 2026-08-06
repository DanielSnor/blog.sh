#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Facebook import. The mapping lives in lib/import/facebook.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_facebook.rb <path-to-unpacked-export>
#   LIMIT=20 ruby scripts/migrate_facebook.rb <dir>          # trial run
#   FACEBOOK_CROSSPOSTS=1 ruby scripts/migrate_facebook.rb <dir>
#
# Crossposts (posts Facebook mirrored from Twitter, Posterous and
# friends -- often MOST of an older account) are skipped and counted by
# default, because those platforms' own imports carry the originals.
# FACEBOOK_CROSSPOSTS=1 includes them.
#
# In Facebook: Accounts Centre -> Your information and permissions ->
# Download your information. Either format works -- JSON and HTML are
# both read, and which one this is comes from the export itself. JSON
# is still the better ask where there's a choice: its timestamps are
# epochs, where the HTML prints a wall clock in the account's own
# timezone and this reads it in the site's -- the same place, for the
# ordinary case of importing your own archive. Unpack the ZIP and point
# this at the directory (the archive root, or the folder holding
# posts/). Photos and videos come from the archive itself, no network.
# Check-ins without words and app stories are skipped and counted.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/facebook'

dir = ARGV[0] || abort('usage: migrate_facebook.rb <path-to-unpacked-export>')
dir = File.expand_path(dir)
abort("#{dir} has no your_posts*.json or your_posts*.html -- point this at the unpacked export directory") unless
  Import::Facebook.format_of(dir)

Import::Cli.run(Import::Facebook.new(dir, include_crossposts: ENV['FACEBOOK_CROSSPOSTS'] == '1'),
                limit: Import::Cli.limit_from_env)
