#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/stats.rb -- prints what lib/stats.rb counts. Run via
# `./blog.sh stats`, or `./blog.sh stats --json` for the same figures as
# machine-readable JSON.
#
# Its own entry point for the reason check.rb and export.rb have one:
# manage_post.rb reads the whole configuration as it loads and aborts on
# one it cannot parse, and everything counted here is on disk in
# content.nosync and media.nosync.

require 'yaml'
require 'json'
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
require_relative '../lib/file_size'
require_relative '../lib/stats'

as_json = false
ARGV.each do |arg|
  case arg
  when '--json' then as_json = true
  else
    warn(I18n.t('stats.unknown_option', option: arg))
    exit 2
  end
end

data = Stats.collect(root: ROOT)

if data.nil?
  # Down a pipe an empty archive is still an answer, and a script asking
  # for JSON must get JSON rather than a sentence.
  as_json ? puts(JSON.pretty_generate({})) : puts(I18n.t('stats.no_posts'))
  exit 0
end

if as_json
  # Never localized and never rounded for looks: the screen below is for
  # a person, this is for whatever reads it next.
  puts JSON.pretty_generate(data)
  exit 0
end

# Numbers written the way the language writes them -- 4 422 in Czech,
# 4,422 in English, 4.422 in German -- and only where they are long
# enough to be hard to read at a glance.
GROUP_FROM = 10_000

def num(value)
  return decimal(value) if value.is_a?(Float)

  digits = value.to_i.to_s
  return digits if value.to_i.abs < GROUP_FROM

  digits.reverse.scan(/\d{1,3}/).join(I18n.t('thousands_separator')).reverse
end

def decimal(value)
  format('%.1f', value).sub('.', I18n.t('decimal_point'))
end

def bar(count, max, width = 24)
  filled = max.zero? ? 0 : ((count.to_f / max) * width).round
  ('█' * [filled, 1].max).ljust(width)
end

def heading(key)
  puts
  puts Tui.paint(I18n.t("stats.#{key}"), :bold)
end

def date_of(iso)
  Time.parse(iso).strftime(I18n.t('date_format'))
end

puts SiteHeader.render
posts = data['posts']
heading('heading_archive')
puts "  #{I18n.t('stats.archive_line', total: num(posts['total']), published: num(posts['published']),
                                       drafts: num(posts['drafts']), scheduled: num(posts['scheduled']),
                                       pages: num(posts['pages']))}"
span = data['span']
puts "  #{I18n.t('stats.span_line', first: date_of(span['first']), last: date_of(span['last']),
                                    days: num(span['days']))}"
puts "  #{I18n.t('stats.busiest_line', year: span['busiest_year']['year'],
                                       count: num(span['busiest_year']['posts']))}"

heading('heading_years')
max_year = data['years'].values.max
data['years'].each { |year, count| puts "  #{year}  #{bar(count, max_year)} #{num(count)}" }

heading('heading_types')
total = posts['total']
max_type = data['types'].values.max
data['types'].each do |type, count|
  share = (count * 100.0 / total).round
  puts "  #{type.ljust(9)} #{bar(count, max_type, 18)} #{num(count)}#{share.positive? ? " (#{share} %)" : ''}"
end

heading('heading_words')
words = data['words']
puts "  #{I18n.t('stats.words_line', total: num(words['total']), mean: num(words['mean']),
                                     median: num(words['median']))}"
puts "  #{I18n.t('stats.longest_line', slug: words['longest']['slug'], words: num(words['longest']['words']))}"
# Under an hour the figure reads "0.0 hours", which is not an answer --
# a young archive gets minutes instead.
if words['reading_hours'] < 1
  puts "  #{I18n.t('stats.reading_line_minutes',
                   minutes: num((words['total'].to_f / Stats::READING_WORDS_PER_MINUTE).ceil))}"
else
  puts "  #{I18n.t('stats.reading_line', hours: decimal(words['reading_hours']))}"
end

heading('heading_tags')
tags = data['tags']
puts "  #{I18n.t('stats.tags_line', unique: num(tags['unique']), per_post: decimal(tags['per_post']))}"
tags['top'].each_slice(4) do |row|
  puts "  #{row.map { |tag, count| "#{tag} (#{num(count)})" }.join(' · ')}"
end

heading('heading_media')
media = data['media']
if media['files'].zero? && media['referenced'].zero?
  puts "  #{I18n.t('stats.media_none')}"
elsif media['files'].zero?
  # An installation whose media directory is elsewhere (or not restored
  # yet) still deserves the count its posts imply, rather than a zero
  # that reads like "you have no pictures".
  puts "  #{I18n.t('stats.media_referenced_line', referenced: num(media['referenced']),
                                                  posts: num(media['posts_with_media']))}"
else
  puts "  #{I18n.t('stats.media_line', files: num(media['files']), size: FileSize.human(media['bytes']),
                                       posts: num(media['posts_with_media']))}"
end

heading('heading_sources')
data['sources'].each_slice(4) do |row|
  puts "  #{row.map { |platform, count| "#{platform} (#{num(count)})" }.join(' · ')}"
end
puts
