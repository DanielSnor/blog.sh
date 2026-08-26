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
require_relative '../lib/public_file'
require_relative '../lib/post_stats'
require_relative '../lib/site_config'

# Under cron stdout is a pipe, which Ruby block-buffers while warn goes
# straight out -- every warning in the mail then jumps ahead of the
# output it belongs under. Unbuffered here at the entry point; the
# libraries stay quiet about how their caller's stdout is wired.
$stdout.sync = true

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
require_relative '../lib/i18n'
RunLock.acquire!(ROOT, label: 'sidebar', busy_exit: 3, quiet_when_busy: true)

# Not an abort: this runs every half hour under cron, where a non-zero
# exit with a line on stderr is a mail, and "you have not built the site
# yet" is not news worth mailing forty-eight times a day. Saying it and
# leaving quietly also lets refresh-sidebar.sh reach its own "Nothing
# built yet" branch, which was written for this and could never run.
unless Dir.exist?(PUBLIC_DIR)
  puts I18n.t('cron.sidebar_not_built')
  exit 0
end

# Printed only when there is something to say. A switched-off sidebar
# returns nothing, and this line runs under cron, where every line is
# mail: a blank one every half hour is still a half-hourly mail.
sidebar_line = Sidebar.summary(Sidebar.write_all(PUBLIC_DIR))
puts sidebar_line unless sidebar_line.strip.empty?

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

# Both files below are read only to be merged into, so anything this
# cannot turn into a Hash has to end as an empty one -- but never in
# silence, and never left on disk to be met again next tick.
#
# Unreadable text used to be swallowed into {} without a word: the merge
# then dropped every entry outside the refreshed window (with
# comments.json, whole discussions under older posts), and the run looked
# exactly like a healthy one. deploy_web.rb's load_manifest meets the same
# situation and says "treating it as empty" for precisely that reason.
#
# Valid JSON of the wrong shape -- `[]`, a number -- is the same corruption
# from the other side, and worse: it passed the parse and then died on
# Hash#merge, mid-run, after the widgets and stats.json had been written
# but before anything was uploaded. Nothing rewrote the file, so every
# cron tick from then on died in the same place, mailing a backtrace while
# the live site stayed frozen and the local build looked current. Naming
# the shape here turns that into one warning and a file the run replaces.
def previous_json(path)
  return {} unless File.exist?(path)

  data = JSON.parse(File.read(path))
  return data if data.is_a?(Hash)

  raise JSON::ParserError, "not an object (#{data.class})"
rescue StandardError => e
  name = File.basename(path)
  warn I18n.t('cron.sidebar_unreadable', name: name,
                                        reason: e.message.lines.first.to_s.strip[0, 60])
  {}
end

previous_stats = previous_json(STATS_PATH)
previous_comments = previous_json(COMMENTS_PATH)
fetched = PostStats.fetch_all(recent_only: !full_refresh)

# Both files are served from the public site, and merging alone never
# forgets: a post taken back down -- or deleted outright -- kept its whole
# approved discussion readable at a public URL for as long as the file
# lived, which is exactly what taking a post down is meant to prevent.
#
# Narrowed against ALL entries, not against what this run fetched: a run
# without --full only refetches the last ninety days, and intersecting
# with that would delete every older post's thread on every tick.
# PostStats.entries already leaves out drafts, and a withdrawn post is a
# draft again -- so "still published" and "still exists" are one question
# with one answer here.
# ...but only when the archive could be read in full. entries silently
# skips a post file that will not parse -- a half-written save, a cloud
# copy still arriving -- and narrowing against that list would read the
# gap as "this post is gone" and delete its approved discussion. A run
# without --full does not refetch it either, so the thread would not come
# back until the weekly pass. Not being able to tell is a reason to keep
# everything, not to forget.
live, unreadable = PostStats.entries_with_gaps
# ...and only when the archive is THERE. PathGlob answers an absent or
# empty content.nosync with [] and no error, so a tick on a volume that
# had not mounted -- or in a working copy whose files were still arriving
# -- read as "every announced post was deleted": both public files were
# sliced down to {}, uploaded (they are in refresh-sidebar.sh's --only
# list), and the live site lost every approved comment and every counter
# at once. Exit 0, nothing said, nothing mailed. Not being able to see the
# archive is a reason to keep everything, exactly like not being able to
# read part of it.
missing_archive = !Dir.exist?(PostStats::CONTENT_DIR) ||
                  (live.empty? && (previous_stats.any? || previous_comments.any?))
if missing_archive
  warn I18n.t('cron.sidebar_no_archive', dir: PostStats::CONTENT_DIR)
elsif unreadable.positive?
  warn I18n.t('cron.sidebar_gaps', count: unreadable)
else
  previous_stats = previous_stats.slice(*live)
  previous_comments = previous_comments.slice(*live)
end

stats = previous_stats.merge(fetched.transform_values { |result| result['stats'] })
# PublicFile.write, not File.write: this file is served to readers, and
# under cron the umask is whatever the daemon's is -- 0600 on a stock
# Cloudron, which is a stats.json the web server cannot read. Its sibling
# comments.json has gone through PublicFile since it was written.
PublicFile.write(STATS_PATH, stats.to_json)
# The stamp says "the weekly pass was done", and the next six days are
# decided by it. A pass in which every single fetch failed -- an instance
# down, a token that lost its scope -- used to write it anyway, so the
# thing that would have retried tomorrow went quiet for a week instead.
if full_refresh
  if fetched.any? || PostStats.entries.empty?
    File.write(FULL_REFRESH_PATH, Time.now.to_f.to_s)
  else
    warn I18n.t('cron.sidebar_empty_pass')
  end
end

puts I18n.t(full_refresh ? 'cron.sidebar_stats_full' : 'cron.sidebar_stats_recent',
            updated: fetched.size, total: stats.size)

# comments.json exists only while moderation is on -- with it off the
# browser reads the live thread itself, and a copy nothing renders is
# waste. Deleting it when moderation is switched back off is the part
# that matters: a stale file left behind would keep a since-rejected
# comment readable at a public URL long after the page stopped showing
# it.
if PostStats.approval.nil?
  if File.exist?(COMMENTS_PATH)
    File.delete(COMMENTS_PATH)
    puts I18n.t('cron.sidebar_comments_removed')
  end
else
  # Merged, never replaced, exactly like the stats above: a post whose
  # fetch failed this run -- an instance down, a token that lost its read
  # scope -- keeps the comments it last published, instead of one bad
  # request blanking a whole discussion.
  approved = fetched.reject { |_key, result| result['comments'].nil? }
  comments = previous_comments.merge(approved.transform_values { |result| result['comments'] })
  PublicFile.write(COMMENTS_PATH, comments.to_json)
  puts I18n.t('cron.sidebar_comments', threads: approved.size,
                                       comments: comments.values.sum { |list| Array(list).size })
end
