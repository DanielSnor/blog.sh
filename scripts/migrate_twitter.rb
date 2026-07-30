#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Twitter/X archive import. The mapping lives in
# lib/import/twitter.rb and is shared with ./import.sh -- this is the
# non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_twitter.rb <path-to-extracted-export>
#   LIMIT=20 ruby scripts/migrate_twitter.rb <path>          # trial run
#
# Standalone tweets only: replies, "RT @..." retweets and quote-tweets are
# skipped and counted in the summary. Media comes from the export's own
# data/tweets_media/, so this needs no network. Re-running is safe -- posts
# are matched on their source id and overwritten in place.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/twitter'

export_dir = ARGV[0] || abort('usage: migrate_twitter.rb <path-to-extracted-export>')
abort("no such directory: #{export_dir}") unless Dir.exist?(export_dir)

Import::Cli.run(Import::Twitter.new(export_dir), limit: Import::Cli.limit_from_env)
