#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Blogger import. The mapping lives in lib/import/blogger.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_blogger.rb <blog-backup.xml>
#   LIMIT=20 ruby scripts/migrate_blogger.rb <backup.xml>    # trial run
#   KEEP_PERMALINKS=1 ruby scripts/migrate_blogger.rb <backup.xml>
#
# The input is the Atom backup from Settings → Manage blog → Back up
# content -- it holds posts AND every comment ever left AND the blog's
# settings, so the summary's skip counts are expected, not a problem.
# Drafts come over as drafts. Images download from Google's CDN at full
# size (the markup itself only points at thumbnails).
#
# KEEP_PERMALINKS=1 records each published post's /YYYY/MM/slug.html
# address as a redirect_from entry -- those addresses become real .html
# files on the new site, so Blogger-era links keep working without any
# server configuration. Only for a blog that ran on a custom domain the
# new site now answers at; for *.blogspot.com there is nothing to keep.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/blogger'

path = ARGV[0] || abort('usage: migrate_blogger.rb <blog-backup.xml>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::Blogger.new(path, keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
