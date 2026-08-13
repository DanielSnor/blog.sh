#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/publish_scheduled.rb -- publishes scheduled drafts whose date
# has arrived. Meant for cron (./scripts/publish-scheduled.sh); the
# scheduling itself happens interactively (./blog.sh schedule <slug>).
#
# Decisions were all made at schedule time, so this runs without a single
# prompt: the scheduled date is kept (that's the point of scheduling),
# and the toot is sent without the CLI's recency check -- there is nobody
# at a terminal to answer it, and a schedule is explicit intent even if
# cron was down for a while and the date is now days in the past. One
# rebuild+deploy at the end regardless of how many posts were due.

require 'json'
require 'time'
require_relative '../lib/publishing'
require_relative '../lib/atomic_write'
require_relative '../lib/i18n'
require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

# Held for the whole run -- publishing, the rebuild and the deploy are one
# operation as far as the site is concerned, and the sidebar cron or a
# person at the CLI must not walk into the middle of it. A tick that finds
# the lock held leaves quietly: nothing has been published, and cron is
# back in fifteen minutes (see lib/run_lock.rb).
require_relative '../lib/run_lock'
RunLock.acquire!(Publishing::ROOT, label: 'publish', busy_exit: 0)

# A post is announced before the site is rebuilt (so the toot's URL and the
# comment thread exist in the same build), which means a failed deploy would
# otherwise leave a live announcement pointing at a page that was never
# uploaded -- and nothing would retry, because the post is no longer
# scheduled and the next run has nothing due. This marker is that retry.
# One definition, in Publishing, because the manual publish leaves this
# marker too now -- two copies of the same path is how they drift apart.
DEPLOY_PENDING = Publishing::DEPLOY_PENDING

due = Dir.glob(File.join(Publishing::CONTENT_DIR, '*', '*.json')).filter_map do |path|
  begin
    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    raise JSON::ParserError, 'not a post object' unless post.is_a?(Hash)

    next unless post['state'] == 'draft' && post['scheduled']

    date = Time.parse(post['date'])
    next if date > Time.now

    [path, post, date]
  rescue StandardError => e
    # Every failure this file can produce, not just an unparseable one: a
    # post whose `date` is malformed or missing raises from Time.parse, and
    # any of them used to abort the whole run on every tick -- so no
    # scheduled post could ever publish again.
    warn I18n.t('cron.unreadable_post', path: path, error: "#{e.class}: #{e.message.lines.first.to_s.strip[0, 80]}")
    next
  end
end

# Written on EVERY tick, before anything is decided -- including the ticks
# where nothing is due, which are almost all of them. That is the point:
# a queue that never fires looks exactly like a queue whose time has not
# come, and the only difference is whether anything is running at all.
# Without this the engine could not tell the two apart, and neither could
# anyone else: a post can sit past its date indefinitely with nothing
# anywhere saying why. `doctor` reads this file.
Publishing.mark_scheduler_alive

if due.empty? && !File.exist?(DEPLOY_PENDING)
  puts I18n.t('cron.no_scheduled_due')
  exit 0
end

failures = 0
due.each do |path, post, date|
  # Per post, so one bad post can't strand the ones already published and
  # announced in this same run (they would stay off the site until a human
  # noticed, with their announcements already public).
  new_path, updated = Publishing.publish(path, post, date: date)
  # An unlisted post is published but never announced. It is out of the
  # listings, the feeds, the sitemap and the search index by the author's
  # own instruction, and this loop is the one place that would have put its
  # address into a public timeline anyway -- without asking, because cron
  # has nobody to ask, and irreversibly, because a server that has the
  # announcement has it. Skipped rather than failed: nothing went wrong and
  # the exit code must not say it did, or the one mail that matters gets
  # lost among the ones that do not.
  unlisted = [true, 'true', 'yes', 1].include?(updated['unlisted'])
  fields = unlisted ? nil : Publishing.announce(updated, year: date.year.to_s)
  AtomicWrite.write_json(new_path, updated.merge(fields)) if fields
  puts I18n.t('cron.published_scheduled', slug: updated['slug'],
                                          date: date.strftime(I18n.t('date_time_format')))
  puts I18n.t('cron.unlisted_not_announced', slug: updated['slug']) if unlisted
  # The post is published either way -- that part worked, and undoing it
  # would be worse. But an announcement that was attempted and failed is a
  # failure of this run: counted, so the exit code is non-zero and cron
  # mails somebody, and said out loud, because the post is now public with
  # nothing announcing it and no second attempt coming.
  if fields == false
    failures += 1
    warn I18n.t('cron.announce_failed', slug: updated['slug'])
  end
# SystemExit as well as StandardError: the likeliest per-post failure is
# Publishing.publish's own `abort` when the target year already has a post
# with this slug, and an abort in a loop over due posts must not take the
# other posts -- or the final rebuild+deploy -- down with it.
rescue StandardError, SystemExit => e
  failures += 1
  # Collapsed to one line: an abort's message carries its own newlines, and
  # this ends up in cron mail where the slug and the reason want to be on
  # the same line.
  detail = e.message.to_s.gsub(/\s+/, ' ').strip
  detail = e.class.to_s if detail.empty?
  warn I18n.t('cron.publish_failed', slug: post['slug'], error: detail[0, 200])
end

reason = due.empty? ? I18n.t('cron.retrying_deploy') : I18n.t('cron.publishing_scheduled', count: due.size)
deployed = Publishing.rebuild_and_deploy(reason)

# The .deploy-pending marker is written and cleared by rebuild_and_deploy
# itself now, so every path that can leave the site owing a deploy -- this
# cron and the manual publish alike -- leaves the same trace behind.
warn I18n.t('cron.deploy_will_retry') unless deployed

exit(deployed && failures.zero? ? 0 : 1)
