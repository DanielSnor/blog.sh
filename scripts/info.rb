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
  if ARGV.include?('--json')
    # The identity block as data: what an app shows above every screen,
    # the way the terminal shows it. From the raw file, like the language
    # above, so a broken config still answers with what it can.
    require 'json'
    locales = Array(data.is_a?(Hash) ? data.dig('site', 'locales') : nil).map(&:to_s).reject(&:empty?)
    # The receiver's ceiling, as the forced command's environment sets it,
    # so an app can measure a delivery before sending it.
    max_mb = ENV.fetch('BLOGSH_MAX_MB', '24').to_i
    # The accent the site wears, per scheme, resolved the way colors.css
    # resolves it -- a palette the site never set answers with the shipped
    # one -- so an app can wear the blog's colour, as /write/ does.
    require_relative '../lib/colors_css'
    colors = data.is_a?(Hash) ? data['colors'] : nil
    accent = %w[light dark].to_h { |mode| [mode, ColorsCss.color_for(colors, mode, 'accent')] }
    puts JSON.pretty_generate('ok' => true, 'engine' => BlogSh::VERSION,
                              'max_mb' => max_mb.positive? ? max_mb : 24,
                              'site' => SiteHeader.identity.merge('lang' => I18n.lang.to_s, 'locales' => locales,
                                                                  'accent' => accent))
  else
    puts "blog.sh #{BlogSh::VERSION}"
  end
else
  puts SiteHeader.render
  puts
  puts I18n.t('cli.usage', recent_count: RECENT_LIST_COUNT)
end
