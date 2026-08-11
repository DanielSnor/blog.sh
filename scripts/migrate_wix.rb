#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Wix import. The mapping lives in lib/import/wix.rb and is
# shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_wix.rb <posts.csv>
#   LIMIT=20 ruby scripts/migrate_wix.rb <posts.csv>         # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_wix.rb <posts.csv>
#
# The input is the blog CSV from the Wix admin export. Post bodies are
# Wix's rich-content JSON and convert straight to blocks; whatever has
# no equivalent (video, galleries, polls) is counted and named in the
# summary. Images download from Wix's CDN -- the export has none -- so
# import while the old site is still up.
#
# KEEP_PERMALINKS=1 records each published post's path (the export's own
# Post Page URL, typically /post/<slug>) as a redirect_from entry. Only
# for a site that keeps its domain, as ever.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/wix'

path = ARGV[0] || abort('usage: migrate_wix.rb <posts.csv>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::Wix.new(path, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
