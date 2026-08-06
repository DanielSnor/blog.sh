#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Squarespace import. The mapping lives in
# lib/import/squarespace.rb and is shared with ./import.sh -- this is the
# non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_squarespace.rb <squarespace-export.xml>
#   LIMIT=20 ruby scripts/migrate_squarespace.rb <export.xml>   # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_squarespace.rb <export.xml>
#
# The input is the "WordPress format" XML from Settings → Import/Export →
# Export. The media is not in it -- images, audio and feature images
# download from Squarespace's CDN, so import while the old site is still
# up. Pages and attachments are counted as skips, same as a WordPress
# export.
#
# KEEP_PERMALINKS=1 records each published post's path (typically
# /blog/<slug>) as a redirect_from entry. Only for a site that keeps its
# domain, as ever.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/squarespace'

path = ARGV[0] || abort('usage: migrate_squarespace.rb <squarespace-export.xml>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::Squarespace.new(path, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
