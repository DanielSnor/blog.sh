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

require 'yaml'
require_relative '../lib/yaml_compat'
require_relative '../lib/site_config'

ROOT = File.expand_path('..', __dir__)

lang = begin
  data = YamlCompat.load_file(File.join(ROOT, 'config', 'site.yml'))
  data.is_a?(Hash) ? data.dig('site', 'lang') : nil
rescue StandardError
  nil
end

require_relative '../lib/i18n'
I18n.force_lang(lang.to_s.empty? ? 'en' : lang.to_s)

require_relative '../lib/tui'
require_relative '../lib/site_header'
require_relative '../lib/checker'

def paint_level(level)
  case level
  when :error then Tui.paint('❌', :red)
  when :warn then Tui.paint('⚠️ ', :yellow)
  else Tui.paint('✅', :green)
  end
end

puts SiteHeader.render
puts
puts Tui.paint(I18n.t('check.heading'), :bold)
puts

# One line per hundred posts on a pipe, a repainted counter on a terminal:
# a log full of counters is unreadable, and a terminal with no counter is
# indistinguishable from a stuck process.
tty = $stdout.tty?
progress = lambda do |done, total|
  next unless tty || (done % 100).zero? || done == total

  line = I18n.t('check.progress', done: done, total: total)
  tty ? print("\r#{line}\e[K") : puts(line)
end

findings = Checker.run(root: ROOT, progress: progress)
print("\r\e[K") if tty
puts

order = { error: 0, warn: 1, ok: 2 }
findings.sort_by.with_index { |f, i| [order.fetch(f.level, 3), i] }.each do |finding|
  puts "#{paint_level(finding.level)} #{finding.text}"
  puts Tui.paint("   #{finding.fix}", :dim) if finding.fix
end

errors = findings.count(&:error?)
warnings = findings.count(&:warn?)

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
