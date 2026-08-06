#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable LiveJournal import. The mapping lives in
# lib/import/livejournal.rb and is shared with ./import.sh.
#
# Usage:
#   LJ_PASSWORD=... ruby scripts/migrate_livejournal.rb <username>
#   LIMIT=20 LJ_PASSWORD=... ruby scripts/migrate_livejournal.rb <user>
#   KEEP_PERMALINKS=1 LJ_PASSWORD=... ruby scripts/migrate_livejournal.rb <user>
#
# LiveJournal has no export file -- everything comes over its XML-RPC
# API, so this needs the account's password (from the environment, like
# the other credentials; it is never sent in plaintext, only a
# challenge-response digest). Friends-only and private entries arrive
# as drafts, counted in the summary. The API rate-limits: a long
# journal may pause and resume, and re-running is safe as ever.
#
# KEEP_PERMALINKS=1 records each public entry's /<ditemid>.html path --
# useful only if the journal ran on a custom domain the new site now
# answers at; for *.livejournal.com there is nothing to keep.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/livejournal'

password = ENV.fetch('LJ_PASSWORD') { abort 'set LJ_PASSWORD (the account password; sent only as a challenge digest)' }
username = ARGV[0] || abort('usage: LJ_PASSWORD=... migrate_livejournal.rb <username>')

Import::Cli.run(Import::Livejournal.new(username, password: password,
                                                  keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
