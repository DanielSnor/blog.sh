#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/export.rb -- writes the archive out as a tree of markdown files.
# Run via `./blog.sh export`.
#
# Its own entry point for the same reason check.rb and doctor.rb have one:
# manage_post.rb reads the whole configuration as it loads and aborts on
# one it cannot parse, and "your config is broken" is the worst possible
# answer to "let me take my posts with me". Everything this needs is on
# disk in content.nosync and media.nosync, so it needs no env.sh either.
#
# Walking thousands of posts and copying their media takes minutes, so it
# narrates -- the same rule the importers follow.

require 'yaml'
require 'fileutils'
require_relative '../lib/yaml_compat'

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
require_relative '../lib/file_size'
require_relative '../lib/exporter'

# An unknown switch is refused rather than ignored, so a misspelled
# --no-drafts cannot quietly publish the drafts it was meant to hold back.
target = nil
drafts = true
dry_run = false
force = false
ARGV.each do |arg|
  case arg
  when '--no-drafts' then drafts = false
  when '--dry-run' then dry_run = true
  when '--force' then force = true
  when /\A--/
    warn(I18n.t('export.unknown_option', option: arg))
    exit 2
  else
    target = arg
  end
end

# tmp/ is gitignored, so the default lands somewhere that cannot be
# committed by accident -- an export contains drafts.
target = target.to_s.empty? ? File.join(ROOT, 'tmp', 'export') : File.expand_path(target)

puts SiteHeader.render
puts
puts Tui.paint(I18n.t('export.heading', path: target), :bold)
puts

# Not empty and not asked twice: an export is a directory somebody will
# hand to another engine, and mixing two of them produces a site that is
# neither. Nothing is ever deleted here -- --force writes alongside what
# is already there, which the message says out loud so nobody expects a
# clean slate.
#
# Dir.children rather than Dir.glob('*'): a glob without FNM_DOTMATCH does
# not see entries that begin with a dot, so a directory holding nothing but
# `.git` and `.gitignore` read as empty and the guard did not fire. That is
# not an exotic case -- it is a freshly cloned repository for the site being
# exported to, which is the single most likely destination anyone types
# here, and the one place where writing a whole Jekyll tree in unasked is
# hardest to notice and most annoying to undo.
if !dry_run && Dir.exist?(target) && !Dir.children(target).empty? && !force
  warn Tui.paint(I18n.t('export.target_not_empty', path: target), :red)
  warn Tui.paint("   #{I18n.t('export.target_not_empty_fix')}", :dim)
  exit 2
end

puts Tui.paint(I18n.t('export.dry_run_notice'), :dim) if dry_run
puts Tui.paint(I18n.t('export.no_drafts_notice'), :dim) unless drafts

# One line per hundred posts on a pipe, a repainted counter on a terminal:
# the same arrangement check uses, and for the same reason.
tty = $stdout.tty?
progress = lambda do |done, total|
  next unless tty || (done % 100).zero? || done == total

  line = I18n.t('export.progress', done: done, total: total)
  tty ? print("\r#{line}\e[K") : puts(line)
end

result = Exporter.run(root: ROOT, target: target, drafts: drafts,
                      dry_run: dry_run, progress: progress)

print("\r\e[K") if tty
puts unless tty

written = result.posts + result.drafts + result.pages
if written.zero?
  puts I18n.t('export.no_posts')
  puts
  exit 0
end

size = FileSize.human(result.bytes) || '0 B'
puts I18n.t(dry_run ? 'export.summary_dry' : 'export.summary',
            posts: result.posts, drafts: result.drafts, pages: result.pages,
            media: result.media, size: size, path: target)

unless result.fallbacks.empty?
  kinds = result.fallbacks.sort_by { |type, count| [-count, type] }
                .map { |type, count| "#{type} (#{count})" }.join(', ')
  puts Tui.paint(I18n.t('export.fallback_note', count: result.fallbacks.values.sum, kinds: kinds), :yellow)
end

puts Tui.paint(I18n.t('export.collisions', count: result.collisions), :yellow) if result.collisions.positive?

puts
puts Tui.paint(I18n.t('export.next_steps'), :dim)
puts
