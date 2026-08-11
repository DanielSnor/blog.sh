#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Substack import. The mapping lives in lib/import/substack.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_substack.rb <path-to-unpacked-export> [site-url]
#   LIMIT=20 ruby scripts/migrate_substack.rb <dir>              # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_substack.rb <dir>
#
# Point it at the unpacked export directory (the one holding posts.csv and
# posts/). The site URL is optional -- the /p/<slug> paths that redirects
# need are derivable from the export alone -- but with it each post also
# records its full original address.
#
# KEEP_PERMALINKS=1 records each published post's /p/<slug> path as a
# redirect_from entry. Only for a publication that ran on a custom domain
# the new site now answers at.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/substack'

dir = ARGV[0] || abort('usage: migrate_substack.rb <path-to-unpacked-export> [https://old-site.example]')
dir = File.expand_path(dir)
abort("#{dir} has no posts.csv -- point this at the unpacked export directory") unless File.exist?(File.join(dir, 'posts.csv'))
site = ARGV[1]
abort("site URL must start with http:// or https:// (got #{site.inspect})") if site && !site.start_with?('http://', 'https://')

Import::Cli.run(Import::Substack.new(dir, site_url: site, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
