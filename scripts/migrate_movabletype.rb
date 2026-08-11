#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable Movable Type / TypePad import. The mapping lives in
# lib/import/movable_type.rb and is shared with ./import.sh.
#
# Usage:
#   ruby scripts/migrate_movabletype.rb <mt-export.txt>
#   URL_PATTERN='https://old.example/%Y/%m/{basename}.html' \
#     KEEP_PERMALINKS=1 ruby scripts/migrate_movabletype.rb <export>
#   LIMIT=20 ruby scripts/migrate_movabletype.rb <export>    # trial run
#
# The input is the MT Import Format file (Tools → Export in Movable
# Type, the export TypePad still produces); gzipped files read
# transparently. The format has no post ids and, usually, no URLs --
# URL_PATTERN reconstructs the old addresses (%Y %m %d strftime parts
# plus {basename}); a TypePad UNIQUE URL line always wins over it.
# Comments and trackbacks in the file are counted and left behind.

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/import/cli'
require_relative '../lib/import/movable_type'

path = ARGV[0] || abort('usage: migrate_movabletype.rb <mt-export.txt>')
abort("no such file: #{path}") unless File.exist?(path)

Import::Cli.run(Import::MovableType.new(path, url_pattern: ENV['URL_PATTERN'],
                                              keep_permalinks: Import::Cli.keep_permalinks_from_env),
                limit: Import::Cli.limit_from_env)
