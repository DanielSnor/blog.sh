#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable feed / WordPress import. The mapping lives in
# lib/import/feed.rb and is shared with ./import.sh -- this is the
# non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_feed.rb <path-to-wordpress-export.xml>
#   ruby scripts/migrate_feed.rb https://example.com/feed/
#   LIMIT=20 ruby scripts/migrate_feed.rb <source>          # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_feed.rb <source> # same-domain move
#
# KEEP_PERMALINKS=1 records each published post's original path (from the
# feed's own <link>) as a redirect_from entry, so the address keeps working
# after the move. Only say it when the new site will answer on the SAME
# domain the old one did -- on any other domain the old paths were never
# yours to answer.
#
# One command for both because they are one format: a WordPress WXR export
# is RSS 2.0 with a wp: namespace layered on, so the file itself says which
# it is. What differs is completeness -- a public feed carries only its last
# few dozen items, a WXR file the whole archive.
#
# Post bodies arrive as HTML and are converted to content blocks
# (lib/import/html_blocks.rb) in the conservative subset the schema can
# represent; anything it can't keep is counted in the summary rather than
# dropped silently. Images referenced in the markup are downloaded and
# measured, since nothing may stay hotlinked and a block without dimensions
# would be dropped at build time.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/feed'

source = ARGV[0] || abort('usage: migrate_feed.rb <export.xml | feed-url>')

Import::Cli.run(Import::Feed.new(source, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
