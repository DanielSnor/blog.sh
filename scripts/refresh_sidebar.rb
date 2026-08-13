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
require_relative '../lib/post_stats'
require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

ROOT = File.expand_path('..', __dir__)
PUBLIC_DIR = File.join(ROOT, 'public.nosync')

# Writes widget JSONs into public.nosync, so it queues behind a build or a
# deploy like everything else. A skipped refresh is harmless -- cron is
# back in half an hour -- so it must not mail. Exit 3, not 0: the shell
# wrapper continues into deploy-web.sh on success, and a plain 0 made it
# upload widgets this run never regenerated -- and then exit 1 from the
# deploy's own lock check, turning the quiet skip into a failure mail.
# The wrapper maps 3 back to 0.
require_relative '../lib/run_lock'
RunLock.acquire!(ROOT, label: 'sidebar', busy_exit: 3)

abort('❌ public.nosync/ does not exist -- run the build first (ruby build/build_blog.rb).') unless Dir.exist?(PUBLIC_DIR)

puts Sidebar.summary(Sidebar.write_all(PUBLIC_DIR))

# Stats for tooted posts are only fetched here, not on every build.
#
# Only posts from the last ~90 days (PostStats::RECENT_WINDOW_DAYS) are
# live-refreshed on every cron run -- likes/boosts/comments barely change on
# older ones, so a full refresh of every ever-tooted post only needs to
# happen occasionally, via FULL_REFRESH_INTERVAL. The timestamp of the last
# full refresh is kept outside public.nosync/ (the build/deploy don't delete
# it there, but it lives alongside .deploy_manifest.json for consistency),
# so it survives a restart.
STATS_PATH = File.join(PUBLIC_DIR, 'stats.json')
COMMENTS_PATH = File.join(PUBLIC_DIR, 'comments.json')
FULL_REFRESH_PATH = File.join(ROOT, '.stats_full_refresh_at')
FULL_REFRESH_INTERVAL = 7 * 24 * 60 * 60 # 1 week

# --full forces the weekly pass now. It exists for moderation: starring a
# reply under a post older than PostStats::RECENT_WINDOW_DAYS would
# otherwise reach the site whenever that pass next came round -- up to a
# week of wondering why an approved comment isn't showing.
force_full = ARGV.include?('--full')
last_full_refresh = File.exist?(FULL_REFRESH_PATH) ? File.read(FULL_REFRESH_PATH).to_f : 0
full_refresh = force_full || (Time.now.to_f - last_full_refresh) >= FULL_REFRESH_INTERVAL

def previous_json(path)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path))
rescue StandardError
  {}
end

previous_stats = previous_json(STATS_PATH)
previous_comments = previous_json(COMMENTS_PATH)
fetched = PostStats.fetch_all(recent_only: !full_refresh)

stats = previous_stats.merge(fetched.transform_values { |result| result['stats'] })
File.write(STATS_PATH, stats.to_json)
File.write(FULL_REFRESH_PATH, Time.now.to_f.to_s) if full_refresh

puts "stats.json: #{fetched.size} post(s) updated (#{stats.size} total)" \
     "#{full_refresh ? ' [full refresh]' : ' [last ~90 days only]'}"

# comments.json exists only while moderation is on -- with it off the
# browser reads the live thread itself, and a copy nothing renders is
# waste. Deleting it when moderation is switched back off is the part
# that matters: a stale file left behind would keep a since-rejected
# comment readable at a public URL long after the page stopped showing
# it.
if PostStats.approval.nil?
  if File.exist?(COMMENTS_PATH)
    File.delete(COMMENTS_PATH)
    puts 'comments.json: removed (comments.approval is off)'
  end
else
  # Merged, never replaced, exactly like the stats above: a post whose
  # fetch failed this run -- an instance down, a token that lost its read
  # scope -- keeps the comments it last published, instead of one bad
  # request blanking a whole discussion.
  approved = fetched.reject { |_key, result| result['comments'].nil? }
  comments = previous_comments.merge(approved.transform_values { |result| result['comments'] })
  File.write(COMMENTS_PATH, comments.to_json)
  puts "comments.json: #{approved.size} thread(s) updated, " \
       "#{comments.values.sum { |list| Array(list).size }} approved comment(s) total"
end
