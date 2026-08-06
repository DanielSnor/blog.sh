#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Wayback rescue. The mapping lives in lib/import/wayback.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_wayback.rb <https://dead-blog.example>
#   ruby scripts/migrate_wayback.rb <https://dead-blog.example/rss>
#   LIMIT=20 ruby scripts/migrate_wayback.rb <url>           # trial run
#   WAYBACK_DELAY=2 ruby scripts/migrate_wayback.rb <url>    # gentler pace
#   WAYBACK_MODE=pages ruby scripts/migrate_wayback.rb <url> # skip feeds
#   POST_PATTERN='^/\d{4}/\d{2}/' ruby scripts/migrate_wayback.rb <url>
#   WAYBACK_PACK=b2evolution ruby scripts/migrate_wayback.rb <url>
#
# For a blog whose platform no longer exists: the Wayback Machine
# archived its FEED again and again over the years, and reading every
# distinct capture oldest-first reassembles the history -- overlaps
# merge through the usual re-import matching. Point it at the blog's
# old URL (the common feed paths are tried) or straight at the feed.
#
# A blog the Archive only ever saw as pages falls through to PAGE MODE:
# every archived post page, newest capture of each. Which paths are
# posts is decided by a platform pack (blog.cz ships built in), or by
# POST_PATTERN -- with neither, the run refuses and shows sample paths
# to build a pattern from. Images are recovered from the Archive too;
# what it never saw is lost and counted. The Archive rate-limits: one
# request per second by default, so a long history takes a while and
# narrates its progress.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/wayback'

url = ARGV[0] || abort('usage: migrate_wayback.rb <https://dead-blog.example[/rss]>')
abort("that is not a URL: #{url.inspect}") unless url.start_with?('http://', 'https://')
delay = ENV['WAYBACK_DELAY'] ? ENV['WAYBACK_DELAY'].to_f : 1.0

mode = ENV['WAYBACK_MODE'] == 'pages' ? :pages : :auto

Import::Cli.run(Import::Wayback.new(url, delay: delay, mode: mode,
                                         post_pattern: ENV['POST_PATTERN'],
                                         pack: ENV['WAYBACK_PACK'],
                                         keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
