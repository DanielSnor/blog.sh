#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Tumblr import. The mapping lives in lib/import/tumblr.rb and is
# shared with ./import.sh -- this is the non-interactive way in, for a cron
# job, a scripted migration, or simply preferring a command to a wizard.
#
# Usage:
#   TUMBLR_API_KEY=... ruby scripts/migrate_tumblr.rb <blog-name>.tumblr.com
#   LIMIT=20 TUMBLR_API_KEY=... ruby scripts/migrate_tumblr.rb <blog>   # trial run
#
# Unlike the wizard this writes immediately, with no preview pass -- use
# LIMIT for a trial, or ./import.sh when you want to see the shape of an
# import before committing to it. Re-running is safe either way: posts are
# matched on their source id and overwritten in place.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/tumblr'

api_key = ENV.fetch('TUMBLR_API_KEY') { abort 'set TUMBLR_API_KEY (source env.sh first)' }
blog = ARGV[0] || abort('usage: migrate_tumblr.rb <blog-name>.tumblr.com')

Import::Cli.run(Import::Tumblr.new(blog, api_key: api_key), limit: Import::Cli.limit_from_env)
