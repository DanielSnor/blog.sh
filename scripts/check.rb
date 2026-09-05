#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/check.rb -- prints what lib/checker.rb finds in the archive. Run
# via `./blog.sh check`.
#
# Its own entry point for the same reason doctor.rb has one: manage_post.rb
# applies the site timezone as it loads and aborts on a config it cannot
# read, and a run that exits explaining the config has not checked anything.
#
# Walking thousands of posts and media files takes long enough that silence
# would be indistinguishable from a hang, so it narrates -- the same rule
# the importers follow.

require_relative '../lib/config_lang'
require_relative '../lib/site_config'

ROOT = File.expand_path('..', __dir__)

# The same dig doctor does, and for a reason check now shares with it: a
# config that will not parse is something check REPORTS (Checker's
# check_config), so the sentence about it has to arrive in the language the
# file asks for -- which is inside the file that will not parse.
lang = ConfigLang.of(File.join(ROOT, 'config', 'site.yml'))

require_relative '../lib/i18n'
I18n.force_lang(lang.to_s.empty? ? 'en' : lang.to_s)

require_relative '../lib/tui'
require_relative '../lib/site_header'
require_relative '../lib/checker'

# A script that ASKS has to flush before it blocks. stdout is block
# buffered whenever it is not a terminal, so `cmd | tee log`, `cmd > log`
# and every wrapper that captures output leaves the question sitting in
# the buffer while the process waits for an answer to it. Reproduced on
# the import wizard: at the confirmation gate the log was 0 bytes -- and
# that gate is deliberately built so the answer IS a number from the
# preview, which was in the buffer too. All 1499 bytes arrived when the
# process finally exited.
$stdout.sync = true

# An unknown switch is refused rather than ignored. `--online` sat here
# unimplemented for a while and a run that quietly accepted it told its
# user that external links had been checked when nothing had left the
# machine -- worse than not offering the switch at all.
online = false
as_json = false
repair = false
ARGV.each do |arg|
  case arg
  when '--online' then online = true
  when '--json' then as_json = true
  when '--repair' then repair = true
  else
    warn(I18n.t('check.unknown_option', option: arg))
    exit 2
  end
end

def paint_level(level)
  case level
  when :error then Tui.paint('❌', :red)
  when :warn then Tui.paint('⚠️ ', :yellow)
  else Tui.paint('✅', :green)
  end
end

# --json prints the findings themselves rather than a screenful of them:
# every finding, uncapped, each with the kind it is and the data it is
# about. The screen shows twenty of a kind and totals the rest, which is
# right for reading and useless for anything that wants to act -- a script
# that adds redirect_from for dead links cannot work from "...and 23 more".
# Progress goes to stderr here, so stdout stays a document.
# Two modes, one run: --json is a document about the archive as it stands,
# --repair changes the archive. Asked for together, the repair used to be
# swallowed without a word and the person walked away believing the
# archive had been fixed.
if as_json && repair
  warn I18n.t('check.json_and_repair')
  exit 2
end

if as_json
  require 'json'
  progress = nil
  findings = Checker.run(root: ROOT, online: online, cap: nil)
  errors = findings.select(&:error?).sum(&:count)
  warnings = findings.select(&:warn?).sum(&:count)
  puts JSON.pretty_generate(
    'errors' => errors,
    'warnings' => warnings,
    'findings' => findings.map do |f|
      { 'level' => f.level.to_s, 'kind' => f.kind&.to_s, 'data' => f.data,
        'text' => f.text, 'fix' => f.fix }.compact
    end
  )
  exit(errors.zero? ? 0 : 1)
end

# One line per hundred posts on a pipe, a repainted counter on a terminal:
# a log full of counters is unreadable, and a terminal with no counter is
# indistinguishable from a stuck process.
tty = $stdout.tty?
progress = lambda do |done, total|
  next unless tty || (done % 100).zero? || done == total

  line = I18n.t('check.progress', done: done, total: total)
  tty ? print("\r#{line}\e[K") : puts(line)
end

online_progress = lambda do |done, total|
  next unless tty || (done % 50).zero? || done == total

  line = I18n.t('check.progress_online', done: done, total: total)
  tty ? print("\r#{line}\e[K") : puts(line)
end

# --repair walks the findings and offers, for each one, the single repair
# that finding allows: the old address written into the target post's
# redirect_from, a relative link rewritten to the address it means, a file
# nobody references moved to the trash. Nothing is applied without a key
# press, nothing is deleted, and a kind with no obvious answer -- a
# collision between two posts, an image the author has to look at -- is
# shown and passed over rather than guessed at.
if repair
  require_relative '../lib/repair'
  require_relative '../lib/run_lock'

  # The lock is held around each WRITE, not around the reading and the
  # deciding. A pass through a hundred findings is a conversation that can
  # last minutes; holding the whole installation for it would mean a
  # scheduled publish waits for somebody to finish reading, and the queue's
  # own tick is the thing that must not be blocked.
  # The same opening the plain check has, and the same counter. Without
  # them --repair spent minutes walking thousands of posts with nothing on
  # screen at all: no header naming the site it was about to change, and
  # no sign it was doing anything.
  puts SiteHeader.render
  puts
  puts Tui.paint(I18n.t('check.repair_heading'), :bold)
  puts
  puts Tui.paint(I18n.t('check.running_online'), :dim) if online
  findings = Checker.run(root: ROOT, progress: progress, online: online,
                         online_progress: online_progress, cap: nil)
  print("\r\e[K") if tty
  puts unless tty
  actionable = findings.reject { |f| f.level == :ok }
  if actionable.empty?
    puts Tui.paint(I18n.t('check.repair_nothing'), :green)
    exit 0
  end

  idx = Repair.index(Checker.load_posts(ROOT))
  applied = 0
  skipped = 0
  no_offer = 0
  failed = 0
  actionable.each do |finding|
    proposal = Repair.propose(finding, idx)
    puts
    puts "#{paint_level(finding.level)} #{finding.text}"
    if proposal.nil?
      no_offer += 1
      # Two of the refusals are worth a sentence, because the tool DID find
      # something and turned it down on purpose. Without this they read as
      # "the tool cannot do this", which is a different thing.
      reason = Repair.why_not(finding, idx)
      key = reason ? "check.repair_no_offer_#{reason}" : 'check.repair_no_offer'
      puts Tui.paint("   #{I18n.t(key)}", :dim)
      next
    end

    puts Tui.paint("   #{I18n.t("check.repair_#{proposal.action}", **proposal.data.transform_keys(&:to_sym))}", :bold)
    answer = Tui.key_choice("   #{I18n.t('check.repair_prompt')} ")
    case answer
    when 'q' then break
    when 'a', 'y', 'j' then
      done = RunLock.hold(ROOT, label: 'check --repair') { Repair.apply!(proposal, ROOT) }
      if done == RunLock::BUSY
        failed += 1
        puts Tui.paint("   #{I18n.t('check.repair_busy')}", :red)
      elsif done
        applied += 1
        puts Tui.paint("   #{I18n.t('check.repair_applied')}", :green)
      else
        # Counted, not just said: a run that changed nothing and a run whose
        # changes were refused must not add up to the same summary.
        failed += 1
        puts Tui.paint("   #{I18n.t('check.repair_failed')}", :red)
      end
    else
      skipped += 1
    end
  end

  puts
  puts I18n.t('check.repair_summary', applied: applied, skipped: skipped, no_offer: no_offer)
  puts Tui.paint(I18n.t('check.repair_summary_failed', count: failed), :red) if failed.positive?
  puts Tui.paint(I18n.t('check.repair_rebuild'), :bold) if applied.positive?
  exit 0
end

puts SiteHeader.render
puts
puts Tui.paint(I18n.t('check.heading'), :bold)
puts

puts Tui.paint(I18n.t('check.running_online'), :dim) if online

findings = Checker.run(root: ROOT, progress: progress, online: online,
                       online_progress: online_progress)
# On a terminal the counter has just been erased, and the cursor is sitting
# on the blank line it left -- printing another one here would leave two.
# Piped, the counters are real lines of output and want a separator.
print("\r\e[K") if tty
puts unless tty

order = { error: 0, warn: 1, ok: 2 }
findings.sort_by.with_index { |f, i| [order.fetch(f.level, 3), i] }.each do |finding|
  puts "#{paint_level(finding.level)} #{finding.text}"
  puts Tui.paint("   #{finding.fix}", :dim) if finding.fix
end

# Totalled through each finding's count rather than by counting lines:
# long lists are capped at twenty lines and the rest rides along in a
# "...and N more" finding, so the number of lines on the screen says how
# much was printed, not how much is wrong.
errors = findings.select(&:error?).sum(&:count)
warnings = findings.select(&:warn?).sum(&:count)

puts
if errors.zero? && warnings.zero?
  puts Tui.paint(I18n.t('check.summary_clean'), :green)
else
  puts I18n.t('check.summary', errors: errors, warnings: warnings)
end
puts

# Non-zero on real errors only, so this can hang off cron and only speak up
# when something is actually broken. Warnings are housekeeping -- an orphan
# media directory costs disk, not correctness, and a job that failed over
# one would be crying wolf.
exit(errors.zero? ? 0 : 1)
