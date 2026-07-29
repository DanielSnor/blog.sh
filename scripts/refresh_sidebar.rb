#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/refresh_sidebar.rb -- regenerates only the sidebar widget JSON
# files (pixelfed.json, toots.json, commits.json) without rebuilding the
# whole site. Meant for cron; ./scripts/refresh-sidebar.sh then uploads them to
# Surfer directly.
#
# Without this, widgets would go stale until the next new post -- the data
# isn't fetched by the visitor's browser, but server-side (see lib/sidebar.rb).

require_relative '../lib/sidebar'
require_relative '../lib/mastodon_stats'

ROOT = File.expand_path('..', __dir__)
PUBLIC_DIR = File.join(ROOT, 'public.nosync')

abort('❌ public.nosync/ does not exist -- run the build first (ruby build/build_blog.rb).') unless Dir.exist?(PUBLIC_DIR)

puts Sidebar.summary(Sidebar.write_all(PUBLIC_DIR))

# Stats for tooted posts are only fetched here, not on every build.
#
# Only posts from the last ~90 days (MastodonStats::RECENT_WINDOW_DAYS) are
# live-refreshed on every cron run -- likes/boosts/comments barely change on
# older ones, so a full refresh of every ever-tooted post only needs to
# happen occasionally, via FULL_REFRESH_INTERVAL. The timestamp of the last
# full refresh is kept outside public.nosync/ (the build/deploy don't delete
# it there, but it lives alongside .deploy_manifest.json for consistency),
# so it survives a restart.
STATS_PATH = File.join(PUBLIC_DIR, 'stats.json')
FULL_REFRESH_PATH = File.join(ROOT, '.stats_full_refresh_at')
FULL_REFRESH_INTERVAL = 7 * 24 * 60 * 60 # 1 week

last_full_refresh = File.exist?(FULL_REFRESH_PATH) ? File.read(FULL_REFRESH_PATH).to_f : 0
full_refresh = (Time.now.to_f - last_full_refresh) >= FULL_REFRESH_INTERVAL

previous = File.exist?(STATS_PATH) ? (JSON.parse(File.read(STATS_PATH)) rescue {}) : {}
fetched = MastodonStats.fetch_all(recent_only: !full_refresh)
File.write(STATS_PATH, previous.merge(fetched).to_json)
File.write(FULL_REFRESH_PATH, Time.now.to_f.to_s) if full_refresh

puts "stats.json: #{fetched.size} post(s) updated (#{previous.merge(fetched).size} total)" \
     "#{full_refresh ? ' [full refresh]' : ' [last ~90 days only]'}"
