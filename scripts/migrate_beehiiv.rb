#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable beehiiv import. The mapping lives in lib/import/beehiiv.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_beehiiv.rb <posts.csv>
#   LIMIT=20 ruby scripts/migrate_beehiiv.rb <posts.csv>     # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_beehiiv.rb <posts.csv>
#
# The input is the posts CSV from Settings → Exports. Each row carries
# the whole email as HTML; the importer slices out the actual content
# and undoes the email chrome. Images download from beehiiv's CDN at
# full quality. Mind one gap of the CSV itself: it only has created_at,
# not the publish date, so a long-scheduled archive can sit a little
# early on the timeline.
#
# KEEP_PERMALINKS=1 records each published post's /p/<slug> path as a
# redirect_from entry. Only for a publication on a custom domain the
# new site now answers at.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/beehiiv'

path = ARGV[0] || abort('usage: migrate_beehiiv.rb <posts.csv>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::Beehiiv.new(path, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
