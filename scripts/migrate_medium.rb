#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Medium import. The mapping lives in lib/import/medium.rb and
# is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_medium.rb <path-to-unpacked-export>
#   LIMIT=20 ruby scripts/migrate_medium.rb <dir>            # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_medium.rb <dir>
#
# Point it at the unpacked export directory -- the one holding posts/.
# The images are not in the export; they download from Medium's CDN,
# which works for as long as Medium serves them.
#
# KEEP_PERMALINKS=1 records each published post's original path (from its
# canonical URL) as a redirect_from entry. Only for a publication that
# ran on a custom domain the new site now answers at -- for medium.com
# addresses the old paths stay Medium's and there is nothing to keep.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/medium'

dir = ARGV[0] || abort('usage: migrate_medium.rb <path-to-unpacked-export>')
dir = File.expand_path(dir)
abort("#{dir} has no posts/ directory -- point this at the unpacked export") unless Dir.exist?(File.join(dir, 'posts'))

Import::Cli.run(Import::Medium.new(dir, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
