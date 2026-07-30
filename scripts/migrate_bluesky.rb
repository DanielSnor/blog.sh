#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Bluesky import. The mapping lives in lib/import/bluesky.rb and
# is shared with ./import.sh -- this exists so Bluesky is reachable the same
# ways the other sources are: from a script, a cron job, or a command line,
# not only through the wizard.
#
# Usage:
#   ruby scripts/migrate_bluesky.rb <handle>
#   LIMIT=20 ruby scripts/migrate_bluesky.rb <handle>        # trial run
#
# Needs no credentials: it reads the public AppView, the same unauthenticated
# API the sidebar widget and the comment threads use. Standalone posts only
# -- reposts and quote-posts are skipped and counted, and replies are
# excluded by the server, which means only a self-thread's opening post is
# imported. Re-running is safe: posts are matched on their source id and
# overwritten in place.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/bluesky'

handle = ARGV[0] || abort('usage: migrate_bluesky.rb <handle>   (e.g. someone.bsky.social)')

Import::Cli.run(Import::Bluesky.new(handle), limit: Import::Cli.limit_from_env)
