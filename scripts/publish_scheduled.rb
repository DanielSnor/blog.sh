#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/publish_scheduled.rb -- publishes scheduled drafts whose date
# has arrived. Meant for cron (./scripts/publish-scheduled.sh); the
# scheduling itself happens interactively (./blog.sh schedule <slug>).
#
# Decisions were all made at schedule time, so this runs without a single
# prompt: the scheduled date is kept (that's the point of scheduling).
# One rebuild+deploy at the end regardless of how many posts were due.
#
# Publishing and announcing are separate questions here, and only the
# first one is answered by the schedule. Three kinds of post are published
# and NOT announced -- unlisted, backdated, already announced -- because
# an announcement is the one thing this script does that cannot be taken
# back: a server that has it has it, and there is nobody at a terminal to
# ask. Each says so out loud and names the way to send it by hand.

require 'json'
require 'time'
require_relative '../lib/publishing'
require_relative '../lib/atomic_write'
require_relative '../lib/i18n'
require_relative '../lib/site_config'
require_relative '../lib/path_glob'

# Cron mail reads stdout and stderr as one stream, and a block-buffered
# stdout lets every warning overtake the lines it belongs after.
$stdout.sync = true

SiteConfig.use_site_timezone!

# Held for the whole run -- publishing, the rebuild and the deploy are one
# operation as far as the site is concerned, and the sidebar cron or a
# person at the CLI must not walk into the middle of it. A tick that finds
# the lock held leaves quietly: nothing has been published, and cron is
# back in fifteen minutes (see lib/run_lock.rb).
require_relative '../lib/run_lock'
RunLock.acquire!(Publishing::ROOT, label: 'publish', busy_exit: 0, quiet_when_busy: true)

# A post is announced before the site is rebuilt (so the toot's URL and the
# comment thread exist in the same build), which means a failed deploy would
# otherwise leave a live announcement pointing at a page that was never
# uploaded -- and nothing would retry, because the post is no longer
# scheduled and the next run has nothing due. This marker is that retry.
# One definition, in Publishing, because the manual publish leaves this
# marker too now -- two copies of the same path is how they drift apart.
DEPLOY_PENDING = Publishing::DEPLOY_PENDING

# What makes a post due, asked in one place. The scan below asks it, and
# so does the loop at the moment it writes -- because between the two
# there is a whole run: a build and a deploy on a large archive take
# minutes, and the author is at their desk the whole time.
DUE_NOW = lambda do |path|
  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  raise JSON::ParserError, 'not a post object' unless post.is_a?(Hash)
  return nil unless post['state'] == 'draft' && post['scheduled']

  date = Time.parse(post['date'])
  return nil if date > Time.now

  [path, post, date]
end

due = PathGlob.under(Publishing::CONTENT_DIR, '*', '*.json').filter_map do |path|
  begin
    DUE_NOW.call(path)
  rescue StandardError => e
    # Every failure this file can produce, not just an unparseable one: a
    # post whose `date` is malformed or missing raises from Time.parse, and
    # any of them used to abort the whole run on every tick -- so no
    # scheduled post could ever publish again.
    warn I18n.t('cron.unreadable_post', path: path, error: "#{e.class}: #{e.message.lines.first.to_s.strip[0, 80]}")
    next
  end
end

# Dir.glob answers in directory order, which is the alphabet by slug and has
# nothing to do with when these posts were meant to go out. On an ordinary
# tick that is invisible -- one post is due, and one post in any order is the
# same order. It shows up after cron has been down: a morning's worth of
# posts comes back all at once, is published in the order of their names and
# announced in that order too. The timeline then reads backwards,
# permanently, and the queue the author arranged by hand was the one thing
# that said what the order should be.
due.sort_by! { |_path, _post, date| date }

# Written on EVERY tick, before anything is decided -- including the ticks
# where nothing is due, which are almost all of them. That is the point:
# a queue that never fires looks exactly like a queue whose time has not
# come, and the only difference is whether anything is running at all.
# Without this the engine could not tell the two apart, and neither could
# anyone else: a post can sit past its date indefinitely with nothing
# anywhere saying why. `doctor` reads this file.
Publishing.mark_scheduler_alive

if due.empty? && !File.exist?(DEPLOY_PENDING)
  # Said to a PERSON, and to nobody else. The documented crontab runs this
  # every fifteen minutes and the overwhelming majority of those ticks
  # have nothing to do; cron mails whatever the job writes, so one
  # sentence per tick is ninety-six mails a day and the ones that matter
  # drown in them. Moving it to stderr was not enough -- the documented
  # line pipes both streams together, which is how the mails kept coming.
  # A hand-run tick still answers "did it look?", because then there is a
  # terminal on the other end.
  warn I18n.t('cron.no_scheduled_due') if $stdout.tty?
  exit 0
end

# Written BEFORE anything is published, not after the deploy fails. A run
# killed between publishing and deploying -- docker stop, a Cloudron
# restart, systemctl -- left the post published and announced, the site
# not rebuilt, and nothing anywhere saying a deploy was owed: the next
# tick found nothing due and went back to sleep, and the page never
# appeared. The marker means "this run owes the site a deploy", which is
# true from the moment there is something to publish.
Publishing.mark_deploy_pending unless due.empty?

failures = 0
due.each do |path, _snapshot, _date|
  # Re-read at the moment of writing rather than trusting the copy the
  # scan took. The snapshot was written straight back, so an edit made
  # while this run worked was silently overwritten with the older text --
  # and a post DELETED in the meantime was recreated from the snapshot,
  # published, and announced to a timeline that cannot be taken back.
  # Anything that is no longer a due scheduled draft is simply left: it
  # stopped being this run's business somewhere in the last few minutes.
  fresh = begin
    File.exist?(path) ? DUE_NOW.call(path) : nil
  rescue StandardError => e
    warn I18n.t('cron.unreadable_post', path: path,
                                        error: "#{e.class}: #{e.message.lines.first.to_s.strip[0, 80]}")
    nil
  end
  next if fresh.nil?

  _, post, date = fresh
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
  unlisted = Publishing.unlisted?(updated)
  # An announcement that has already happened is not repeated. The post's
  # own fields are the record of it, and a second toot does not replace
  # the first -- it stands beside it, live, while the URL that gets stored
  # points at the new one and the older thread's replies become
  # unreachable from the page they belong to. A post arrives here carrying
  # those fields when it was announced once and later put back into the
  # queue: unpublish and re-schedule, or a date edited by hand or by a
  # script. Rarer than the window above, and worse when it happens, which
  # is why it is checked even though the window would usually catch it
  # first -- a backfilled post given today's date is inside the window and
  # still must not be announced twice.
  announced = Publishing.announced?(updated)
  # A post dated well outside the recency window is a backfill, not news:
  # an old thread rebuilt, an archive imported, a release post written
  # down after the fact. The interactive publish has asked about this
  # since 1.0 (it prompts, and the author can say yes); cron cannot ask,
  # so it declines on the author's behalf and says how to override. The
  # cost of being wrong here is one command; the cost the other way is a
  # timeline full of years-old posts that cannot be recalled.
  #
  # A cron that was down longer than the window is the case this trades
  # away: those posts publish silently. That is the deliberate half of the
  # bargain -- said out loud, per post, with the command that fixes it.
  backdated = !Publishing.within_recency_window?(date)
  silent = unlisted || announced || backdated
  fields = silent ? nil : Publishing.announce(updated, year: date.year.to_s)
  AtomicWrite.write_json(new_path, updated.merge(fields)) if fields
  puts I18n.t('cron.published_scheduled', slug: updated['slug'],
                                          date: date.strftime(I18n.t('date_time_format')))
  # One line, not three: a post can be all of unlisted, backdated and
  # already announced at once, and three reasons for one silence read as
  # three silences. The order is which reason to give when they overlap --
  # the author's own instruction first, then the fact that the
  # announcement already exists, then the date.
  #
  # Loud, but not a failure: nothing went wrong, and an exit code that
  # said otherwise would put this run in the same mail as a broken deploy
  # -- which is how the one mail that matters gets lost among the ones
  # that do not (the same reasoning as the unlisted skip above).
  if unlisted
    puts I18n.t('cron.unlisted_not_announced', slug: updated['slug'])
  elsif announced
    puts I18n.t('cron.already_announced', slug: updated['slug'])
  elsif backdated
    puts I18n.t('cron.backdated_not_announced', slug: updated['slug'])
  end
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
