#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Threads import. The mapping lives in lib/import/threads.rb
# and is shared with ./import.sh -- this is the non-interactive way in.
#
# Usage:
#   ruby scripts/migrate_threads.rb <path-to-unpacked-export>
#   LIMIT=20 ruby scripts/migrate_threads.rb <dir>           # trial run
#
# In Threads: Settings -> Account -> Download your information. Either
# format works -- JSON and HTML are both read, and which one this is
# comes from the export itself. JSON is still the better ask where
# there's a choice: its timestamps carry seconds where the HTML prints
# minutes, and only JSON marks replies. Unpack the ZIP and point this
# at the directory. Your own standalone posts import with their media
# from the archive; replies to other people's threads are skipped and
# counted (from JSON -- the HTML page doesn't say which they are).
# Bare URLs in the text become real links.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/threads'

dir = ARGV[0] || abort('usage: migrate_threads.rb <path-to-unpacked-export>')
dir = File.expand_path(dir)
abort("#{dir} has no threads_and_replies.json or .html -- point this at the unpacked export directory") unless
  Import::Threads.format_of(dir)

Import::Cli.run(Import::Threads.new(dir), limit: Import::Cli.limit_from_env)
