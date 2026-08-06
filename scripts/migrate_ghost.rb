#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Ghost import. The mapping lives in lib/import/ghost.rb and is
# shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_ghost.rb <export.json> <https://old-site.example>
#   LIMIT=20 ruby scripts/migrate_ghost.rb <export.json> <url>   # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_ghost.rb <export.json> <url>
#
# The site URL is required because the export never spells it out: every
# image arrives as a "__GHOST_URL__/..." reference, and the files
# themselves only exist on the live site -- import while it is still up.
#
# KEEP_PERMALINKS=1 records each published post's path (Ghost's /<slug>/,
# or its same-site canonical_url) as a redirect_from entry. Only for a
# site that keeps its domain, as ever.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/ghost'

path = ARGV[0] || abort('usage: migrate_ghost.rb <export.json> <https://old-site.example>')
abort("no such file: #{path}") unless File.exist?(path)
site = ARGV[1] || abort('the site URL is required -- images live only on the live site (see --help in import.sh)')
abort("site URL must start with http:// or https:// (got #{site.inspect})") unless site.start_with?('http://', 'https://')

Import::Cli.run(Import::Ghost.new(path, site_url: site, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
