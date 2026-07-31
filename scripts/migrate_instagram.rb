#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Instagram archive import. The mapping lives in
# lib/import/instagram.rb and is shared with ./import.sh -- this is the
# non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_instagram.rb <path-to-unpacked-export>
#   LIMIT=20 ruby scripts/migrate_instagram.rb <path>         # trial run
#
# Request the export in either format (Accounts Centre → Your information
# and permissions → Download your information) and unpack it -- HTML and
# JSON are both read, and which one this is comes from the export itself.
# Your grid and your IGTV videos are imported; archived posts, profile
# photos and stories are not. Media comes from the export itself, so this
# needs no network and no token. Re-running is safe -- posts are matched on
# their source id and overwritten in place, which also holds across the two
# formats: they name their media files differently but agree on the ids.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/instagram'

dir = ARGV[0] || abort('usage: migrate_instagram.rb <path-to-unpacked-export>')
abort("no Instagram export under #{dir} (looked for your_instagram_activity/{content,media}/posts_*)") unless
  Import::Instagram.format_of(dir)

Import::Cli.run(Import::Instagram.new(dir), limit: Import::Cli.limit_from_env)
