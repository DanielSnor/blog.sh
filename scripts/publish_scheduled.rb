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
require_relative '../lib/mastodon_poster'
require_relative '../lib/i18n'

due = Dir.glob(File.join(Publishing::CONTENT_DIR, '*', '*.json')).filter_map do |path|
  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  next unless post['state'] == 'draft' && post['scheduled']

  date = Time.parse(post['date'])
  next if date > Time.now

  [path, post, date]
end

if due.empty?
  puts I18n.t('cron.no_scheduled_due')
  exit 0
end

due.each do |path, post, date|
  new_path, updated = Publishing.publish(path, post, date: date)
  toot = Publishing.compose_toot(title: updated['title'], slug: updated['slug'],
                                 year: date.year.to_s, blocks: updated['content'],
                                 tags: updated['tags'] || [])
  url = MastodonPoster.publish(toot)
  File.write(new_path, JSON.pretty_generate(updated.merge('mastodon_url' => url))) if url
  puts I18n.t('cron.published_scheduled', slug: updated['slug'],
                                          date: date.strftime(I18n.t('date_time_format')))
end

exit(Publishing.rebuild_and_deploy(I18n.t('cron.publishing_scheduled', count: due.size)) ? 0 : 1)
