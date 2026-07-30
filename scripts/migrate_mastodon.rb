#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable mastodon import. The mapping lives in lib/import/mastodon.rb and is
# shared with ./import.sh -- this is the non-interactive way in.
#
# Usage: see ./import.sh --help. LIMIT=n imports only the first n posts.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/mastodon'

dir = ARGV[0] || abort('usage: migrate_mastodon.rb <path-to-unpacked-archive>')
abort("no outbox.json under #{dir}") unless File.exist?(File.join(dir, 'outbox.json'))

Import::Cli.run(Import::Mastodon.new(dir), limit: Import::Cli.limit_from_env)
