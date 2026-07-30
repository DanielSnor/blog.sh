#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable pixelfed import. The mapping lives in lib/import/pixelfed.rb and is
# shared with ./import.sh -- this is the non-interactive way in.
#
# Usage: see ./import.sh --help. LIMIT=n imports only the first n posts.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/pixelfed'

path = ARGV[0] || abort('usage: migrate_pixelfed.rb <path-to-statuses.json>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::Pixelfed.new(path), limit: Import::Cli.limit_from_env)
