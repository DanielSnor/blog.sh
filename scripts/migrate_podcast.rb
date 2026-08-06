#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable podcast import. The mapping lives in lib/import/podcast.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_podcast.rb <feed-url | export.xml>
#   LIMIT=5 ruby scripts/migrate_podcast.rb <feed-url>     # trial run
#
# Works with any podcast RSS -- Libsyn, Buzzsprout, Anchor, a plain
# feed with audio enclosures. A bare libsyn.com show URL is expanded to
# its metadata-carrying feed automatically. Every episode's audio (and
# artwork) downloads and is hosted locally, so mind the summary's size
# note: a long-running show adds up to real gigabytes.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/podcast'

source = ARGV[0] || abort('usage: migrate_podcast.rb <feed-url | export.xml>')

Import::Cli.run(Import::Podcast.new(source), limit: Import::Cli.limit_from_env)
