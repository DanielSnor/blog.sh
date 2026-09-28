#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/on_this_day.rb -- what the archive holds for one day of the year
# in earlier years, and what the on_this_day widget shows of it. Run via
# `./blog.sh on-this-day`, `--date MM-DD` (or YYYY-MM-DD, to see another
# year's view of the same archive) and `--json` for the same answer as data.
#
# The selection itself is lib/on_this_day.rb, the same code the build and
# the cron call, so what this prints is what a reader gets -- which is the
# reason it exists: the rule decides five rows out of forty on a busy day,
# and the author should be able to see why.
#
# It reads the archive on disk, like stats: no build needed, no network,
# and the site's own language (the addresses shown are the site's own).

require 'json'
require 'time'
require 'date'
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
require_relative '../lib/path_glob'
require_relative '../lib/on_this_day'

# A day is a day in the site's time zone: a post written at 23:30 in
# Prague is stored with its offset, and read in UTC it would belong to the
# next day.
SiteConfig.use_site_timezone!

def t(key, **vars)
  I18n.t("on_this_day.#{key}", **vars)
end

as_json = false
wanted = nil
args = ARGV.dup
until args.empty?
  arg = args.shift
  case arg
  when '--json' then as_json = true
  when '--date' then wanted = args.shift.to_s
  when /\A--date=(.*)\z/ then wanted = Regexp.last_match(1)
  else
    warn(t('unknown_option', option: arg))
    exit 2
  end
end

today = Date.today
date = if wanted.nil?
         today
       else
         begin
           case wanted
           when /\A(\d{4})-(\d{2})-(\d{2})\z/ then Date.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i)
           when /\A(\d{1,2})-(\d{1,2})\z/ then Date.new(today.year, Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
           else raise ArgumentError
           end
         rescue ArgumentError, Date::Error
           warn(t('bad_date', value: wanted.inspect))
           exit 2
         end
       end

content_dir = File.join(ROOT, 'content.nosync', 'posts')
posts = PathGlob.under(content_dir, '*', '*.json').sort.filter_map do |path|
  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  next unless OnThisDay.listed?(post)

  time = Time.parse(post['date'].to_s).getlocal
  OnThisDay.entry(post, time, slug: post['slug'].to_s, title: OnThisDay.display_title(post),
                              path: PostAddress.path(post))
rescue JSON::ParserError, ArgumentError, TypeError, SystemCallError
  # `check` names the files it cannot read; a date nobody can parse has no
  # day to be remembered on.
  nil
end

plan = OnThisDay.plan(posts, date)

if as_json
  # Never localized: the screen below is for a person, this is for whatever
  # reads it next.
  puts JSON.pretty_generate(plan)
  exit 0
end

puts SiteHeader.render
puts
if posts.empty?
  puts t('no_posts')
  exit 0
end

puts Tui.paint(t('heading', date: date.strftime(I18n.t('date_format'))), :bold)
years = plan['all'].map { |e| e['year'] }.uniq.size
if plan['all'].empty?
  puts "  #{t('nothing')}"
else
  puts "  #{t('summary', posts: plan['all'].size, years: years)}"
end

def ago(n)
  n == 1 ? I18n.t('js.on_this_day_ago_one') : I18n.t('js.on_this_day_ago_other', n: n)
end

def short(text, width = 64)
  text = text.to_s.gsub(/\s+/, ' ').strip
  text.length > width ? "#{text[0, width - 1]}…" : text
end

unless plan['windows'].empty?
  puts
  puts Tui.paint(t('windows', count: plan['windows'].size), :bold)
  plan['windows'].each do |window|
    from = Time.parse(window['from']).getlocal.strftime('%H:%M')
    to = Time.parse(window['to']).getlocal.strftime('%H:%M')
    to = '24:00' if to == '00:00'
    puts "  #{Tui.paint("#{from}–#{to}", :dim)}"
    window['rows'].each do |row|
      puts "    #{ago(row['ago'])} · #{row['year']}  #{short(row['title'])}"
    end
  end

  shown = plan['windows'].flat_map { |w| w['rows'].map { |r| r['path'] } }
  puts
  puts Tui.paint(t('all_heading'), :bold)
  plan['all'].each do |row|
    mark = shown.include?(row['path']) ? '●' : ' '
    puts "  #{row['year']} #{mark} #{short(row['title'], 56)}  #{Tui.paint(row['path'], :dim)}"
  end
  puts
  puts Tui.paint("  #{t('legend')}", :dim)
end

unless SiteConfig::Chrome.widgets(SiteConfig.data).key?('on_this_day')
  puts
  puts Tui.paint(t('widget_off'), :dim)
end
puts
