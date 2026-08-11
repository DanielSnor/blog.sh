#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable import of a markdown tree with front matter -- a Jekyll
# site, a Hugo content directory, or any folder of .md files a converter
# produced (Meddler for Medium, Substack2Markdown, ...). The mapping
# lives in lib/import/jekyll.rb and is shared with ./import.sh.
#
# Usage:
#   ruby scripts/migrate_jekyll.rb <path-to-site-tree>
#   PERMALINK='/:year/:month/:day/:title/' ruby scripts/migrate_jekyll.rb <dir>
#   LIMIT=20 ruby scripts/migrate_jekyll.rb <dir>            # trial run
#   KEEP_PERMALINKS=1 PERMALINK=... ruby scripts/migrate_jekyll.rb <dir>
#
# Images come from the tree itself -- no network, works for a site that
# died years ago. PERMALINK is the old site's pattern (:year :month :day
# :title), needed because a Jekyll tree does not carry its own URL shape;
# a post's explicit front matter permalink always wins over it.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/jekyll'

dir = ARGV[0] || abort('usage: migrate_jekyll.rb <path-to-site-tree>')
dir = File.expand_path(dir)
abort("no such directory: #{dir}") unless Dir.exist?(dir)

Import::Cli.run(Import::Jekyll.new(dir, permalink: ENV['PERMALINK'],
                                        keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
