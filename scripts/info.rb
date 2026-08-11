#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/info.rb -- `./blog.sh help` and `./blog.sh version`.
#
# Its own entry point for the same reason scripts/doctor.rb has one: these
# two commands must answer on an install that is BROKEN, and that is when
# they are asked. manage_post.rb cannot do it -- requiring it pulls in
# lib/mastodon_poster.rb, lib/bluesky_poster.rb, the four sidebar fetchers
# and lib/i18n.rb, and each of those reads config/site.yml into a constant
# at load time. SiteConfig aborts on a config that will not parse, so the
# abort happened during `require`, thousands of lines before any guard in
# the dispatch could speak. The guard was there and was dead code.
#
# Nothing here reads config through SiteConfig. The language is taken from
# the raw file (as doctor.rb does) so `help` still speaks the site's
# language when the file is readable, and falls back to English when it is
# not -- an English help beats no help.

require 'yaml'
require_relative '../lib/yaml_compat'

ROOT = File.expand_path('..', __dir__)

lang = begin
  data = YamlCompat.load_file(File.join(ROOT, 'config', 'site.yml'))
  data.is_a?(Hash) ? data.dig('site', 'lang') : nil
rescue StandardError
  nil
end

require_relative '../lib/i18n'
I18n.force_lang(lang.to_s.empty? ? 'en' : lang.to_s)

require_relative '../lib/version'
require_relative '../lib/site_header'

# Kept in step with manage_post.rb's RECENT_LIST_COUNT: the usage text
# names it. Duplicated rather than required, since requiring that file is
# the whole problem this entry point exists to avoid.
RECENT_LIST_COUNT = 50

case ARGV.first
when 'version', '--version', '-v'
  puts "blog.sh #{BlogSh::VERSION}"
else
  puts SiteHeader.render
  puts
  puts I18n.t('cli.usage', recent_count: RECENT_LIST_COUNT)
end
