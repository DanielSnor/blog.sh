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

# A post is announced before the site is rebuilt (so the toot's URL and the
# comment thread exist in the same build), which means a failed deploy would
# otherwise leave a live announcement pointing at a page that was never
# uploaded -- and nothing would retry, because the post is no longer
# scheduled and the next run has nothing due. This marker is that retry.
DEPLOY_PENDING = File.join(Publishing::ROOT, '.deploy-pending')

due = Dir.glob(File.join(Publishing::CONTENT_DIR, '*', '*.json')).filter_map do |path|
  begin
    post = JSON.parse(File.read(path, encoding: 'utf-8'))
  rescue JSON::ParserError, SystemCallError => e
    # One unreadable file used to abort the whole run on every tick, so no
    # scheduled post could ever publish again.
    warn I18n.t('cron.unreadable_post', path: path, error: e.message.lines.first.to_s.strip[0, 100])
    next
  end
  next unless post['state'] == 'draft' && post['scheduled']

  date = Time.parse(post['date'])
  next if date > Time.now

  [path, post, date]
end

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
  fields = Publishing.announce(updated, year: date.year.to_s)
  AtomicWrite.write_json(new_path, updated.merge(fields)) if fields
  puts I18n.t('cron.published_scheduled', slug: updated['slug'],
                                          date: date.strftime(I18n.t('date_time_format')))
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

if deployed
  File.delete(DEPLOY_PENDING) if File.exist?(DEPLOY_PENDING)
else
  File.write(DEPLOY_PENDING, Time.now.iso8601)
  warn I18n.t('cron.deploy_will_retry')
end

exit(deployed && failures.zero? ? 0 : 1)
