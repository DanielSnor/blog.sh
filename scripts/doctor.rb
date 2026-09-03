#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/doctor.rb -- prints what lib/doctor.rb finds. Run via
# `./blog.sh doctor`.
#
# Its own entry point rather than a case in manage_post.rb, for one
# reason that decides it: manage_post.rb calls
# SiteConfig.use_site_timezone! as it loads, and that aborts on a
# timezone the machine doesn't know. So does reading a config whose YAML
# won't parse. Both are conditions doctor exists to REPORT, and neither
# can be reported from a process that already exited explaining them
# halfway.
#
# For the same reason the language is resolved here, from the raw file,
# before anything touches I18n: I18n asks SiteConfig, SiteConfig aborts
# on a broken config, and the abort would replace the diagnosis with the
# first symptom of it.

require_relative '../lib/config_lang'
require_relative '../lib/site_config'

ROOT = File.expand_path('..', __dir__)

# The language, dug out of the file the way doctor promises -- tolerating
# failure, because the one scenario doctor exists for is a config that will
# not parse, and a parse fails on exactly that, forcing English over the
# cs/de diagnosis of the very syntax error it is about to report. How that
# is dug out, and why check needs the same, is in lib/config_lang.rb.
site_yml = File.join(ROOT, 'config', 'site.yml')
lang = ConfigLang.of(site_yml)

require_relative '../lib/i18n'
I18n.force_lang(lang.to_s.empty? ? 'en' : lang.to_s)

require_relative '../lib/tui'
require_relative '../lib/site_header'
require_relative '../lib/doctor'

online = ARGV.include?('--online')

# The one thing doctor does rather than reports, and it has to be asked for
# by name. Everything else here reads; this rewrites photographs that are
# already on somebody's website, so it never happens as a side effect of
# running a check. It prints what it changed and what that costs -- every
# rewritten file has a new checksum, so the next deploy uploads it again.
if ARGV.include?('--strip-location')
  require_relative '../lib/exif_location'

  # Which installation is about to be written to, before it is written to.
  puts SiteHeader.render
  puts
  found = Doctor.located_media(ROOT)
  if found.nil?
    puts I18n.t('doctor.media_location_no_dir')
    exit 0
  end
  if found.empty?
    puts Tui.paint(I18n.t('doctor.media_location_clean'), :green)
    exit 0
  end

  puts I18n.t('doctor.media_location_stripping', count: found.size)
  cleaned = found.count { |path| ExifLocation.strip_file(path) }
  failed = found.size - cleaned
  puts Tui.paint(I18n.t('doctor.media_location_stripped', count: cleaned), :green)
  puts Tui.paint(I18n.t('doctor.media_location_unwritable', count: failed), :yellow) if failed.positive?
  puts Tui.paint(I18n.t('doctor.media_location_redeploy'), :dim)
  exit(failed.zero? ? 0 : 1)
end

def paint_level(level)
  case level
  when :error then Tui.paint('❌', :red)
  when :warn then Tui.paint('⚠️ ', :yellow)
  else Tui.paint('✅', :green)
  end
end

# The identity block first -- doctor output gets pasted into issues and
# read in logs, where "which install said this" matters most. On a config
# too broken to name the site, SiteHeader degrades to the version line,
# which is exactly the case doctor exists for.
puts SiteHeader.render
puts
puts Tui.paint(I18n.t('doctor.heading'), :bold)
puts Tui.paint(I18n.t('doctor.running_online'), :dim) if online
puts

findings = Doctor.run(online: online)

# Problems first, then the things that merely want a look, then what is
# fine. A list in check order buries the one broken thing among twenty
# green lines -- and the broken thing is why anyone ran this.
order = { error: 0, warn: 1, ok: 2 }
findings.sort_by.with_index { |f, i| [order.fetch(f.level, 3), i] }.each do |finding|
  puts "#{paint_level(finding.level)} #{finding.text}"
  # The fix is indented under its finding and dimmed: it is the second
  # sentence of the same thought, not a separate item to scan.
  puts Tui.paint("   #{finding.fix}", :dim) if finding.fix
end

errors = findings.count(&:error?)
warnings = findings.count(&:warn?)
oks = findings.size - errors - warnings

puts
if errors.zero? && warnings.zero?
  puts Tui.paint(I18n.t('doctor.summary_clean', oks: oks), :green)
else
  puts I18n.t('doctor.summary', errors: errors, warnings: warnings, oks: oks)
end
puts Tui.paint(I18n.t('doctor.hint_online'), :dim) unless online
puts

# A non-zero exit only for real errors: warnings are advice, and a CI job
# or a cron wrapper that treats "still the example's about text" as a
# failed run would be crying wolf.
exit(errors.zero? ? 0 : 1)
