# frozen_string_literal: true

require 'json'
require 'date'
require 'time'
require 'fileutils'
require_relative 'post_text'
require_relative 'post_address'
require_relative 'public_file'
require_relative 'path_glob'

# lib/on_this_day.rb -- which posts from earlier years stand on today's
# date, and which of them a reader is shown. Behind `./blog.sh on-this-day`
# and the on_this_day sidebar widget.
#
# One rule for every archive, with nothing to configure. It was worked out
# against sean.cz (6,643 posts over 23 years) and against samples of 100
# and 2,000 posts cut from it, and what decides how it behaves is not the
# size of an archive but how many years it spans -- that caps the rows --
# and how many posts one year has on one day -- that feeds the rotation.
#
# The rule, in the order it is applied:
#
# * Only the day itself. A day with nothing from an earlier year shows
#   nothing -- the widget hides, heading and all. A fallback to "this week"
#   was tried and dropped: on a small archive it showed one post seven days
#   in a row, and on five of those days it was a post from a date that had
#   not come yet.
# * One row per year, five rows at most. Round anniversaries (5, 10, 15
#   years...) always get one. The rest are spread along the years, with
#   today counted as a point that is already taken -- so a year's claim
#   grows with its age, and "a year ago" shows only when there is too
#   little older to fill the card. Spreading from both ends instead put
#   last year on every single day.
# * A year is represented by its titled post, the longest one first; an
#   untitled post only when the year has nothing titled that day. The
#   title decides inside a year and never between years: on sean.cz titles
#   mark eras (all of b2evolution, none of Twitter), and letting them pick
#   the years left a whole decade off the card.
# * The day rotates: one window for every five posts it has, three at
#   most, dividing the day evenly (midnight to midnight, in the site's
#   time zone). Anniversaries stay put; the other rows go first to years
#   the day has not shown yet, and a year shown again brings its next post.
#
# Everything here is data in, data out: it never prints, never reads the
# config and never decides a language. The build hands it posts in the
# language it is rendering, the cron hands it what the build left behind,
# and the command line hands it the archive as it is on disk.
module OnThisDay
  SLOTS = 5
  MAX_WINDOWS = 3
  ANNIVERSARY_EVERY = 5

  # Where the widget's data lands, in the root of every language's tree.
  FILE = PostAddress::CRON_FILES[:on_this_day]

  module_function

  # --- the posts that take part ------------------------------------------

  # A published post in the stream: not a draft, not a page, not unlisted.
  # The same three questions the build asks before a post reaches a listing,
  # answered by the same predicates, so a post hidden from the front page
  # cannot resurface here twenty years later.
  def listed?(post)
    post.is_a?(Hash) && !PostAddress.draft?(post) && !PostAddress.page?(post) && !PostAddress.unlisted?(post)
  end

  # What a reader sees as the post's name: its own title, then the title
  # of a link block, then the name cut from its opening words. The order
  # the build's post_title_for uses, so the widget, the page and the feed
  # never call one post three things.
  def display_title(post)
    return post['title'].to_s unless post['title'].to_s.strip.empty?

    block = PostText.link_title_block(post)
    return block['title'].to_s if block

    name, = PostText.name_and_rest(post.merge('title' => nil))
    name || post['slug'].to_s
  end

  # The facts the selection needs about one post, whatever else the caller
  # wants to carry along with it (a title and an address for a page, a slug
  # for the terminal). `time` is the post's moment in the SITE's time zone
  # -- a tweet stored at 23:30 UTC belongs to the next day in Prague, and
  # the day is what this whole module is about.
  def entry(post, time, **extra)
    {
      'day' => time.strftime('%m-%d'),
      'year' => time.year,
      'time' => time.iso8601,
      'titled' => !post['title'].to_s.strip.empty?,
      'words' => PostText.plain(post).split(/\s+/).reject(&:empty?).size
    }.merge(extra.transform_keys(&:to_s))
  end

  # The calendar days a date answers for. A post written on 29 February
  # would otherwise come round once in four years; in a year without the
  # day it is remembered on the 28th.
  def days_for(date)
    days = [date.strftime('%m-%d')]
    days << '02-29' if date.month == 2 && date.day == 28 && !Date.leap?(date.year)
    days
  end

  # Every post from an EARLIER year on this date, newest year first and in
  # the order they were written within a year.
  def of_day(entries, date)
    days = days_for(date)
    entries.select { |e| days.include?(e['day']) && e['year'].to_i < date.year }
           .sort_by { |e| [-e['year'].to_i, e['time'].to_s] }
  end

  # --- the selection -------------------------------------------------------

  def window_count(posts)
    return 0 if posts.zero?

    ((posts + SLOTS - 1) / SLOTS).clamp(1, MAX_WINDOWS)
  end

  # When each window starts and ends: equal parts of the day on the local
  # clock (0-24, 0-12-24, 0-8-16-24), so a day that loses or gains an hour
  # to daylight saving still changes at the hour the author would expect.
  def boundaries(date, count)
    step = 24 / count
    (0...count).map do |i|
      from = Time.local(date.year, date.month, date.day, i * step)
      to = if i == count - 1
             nxt = date + 1
             Time.local(nxt.year, nxt.month, nxt.day)
           else
             Time.local(date.year, date.month, date.day, (i + 1) * step)
           end
      [from, to]
    end
  end

  # The whole plan for a date: every window with its rows, and the full list
  # of the day behind them. Rows carry `ago` (years before `date`) on top of
  # whatever the entries brought.
  def plan(entries, date)
    day = of_day(entries, date)
    ago = ->(e) { date.year - e['year'].to_i }
    all = day.map { |e| e.merge('ago' => ago.call(e)) }
    count = window_count(all.size)
    return { 'date' => date.iso8601, 'windows' => [], 'all' => [] } if count.zero?

    by_age = all.group_by { |e| e['ago'] }
    rows = windows(by_age, count)
    timed = boundaries(date, count).zip(rows).map do |(from, to), picked|
      { 'from' => from.utc.iso8601, 'to' => to.utc.iso8601, 'rows' => picked }
    end
    { 'date' => date.iso8601, 'windows' => timed, 'all' => all }
  end

  def windows(by_age, count)
    ages = by_age.keys
    # The oldest anniversaries first, should there ever be more than there
    # are rows -- which takes thirty years of writing on one date.
    anchors = ages.select { |n| (n % ANNIVERSARY_EVERY).zero? }.sort.reverse.first(SLOTS)
    free = SLOTS - anchors.size
    shown = Hash.new(0)
    turns = Hash.new(0)
    (0...count).map do
      others = ages - anchors
      pick = spread(others - shown.keys, anchors, free)
      if pick.size < free
        again = (others - pick).sort_by { |n| [shown[n], -n] }
        pick += spread(again, anchors + pick, free - pick.size)
      end
      (anchors + pick).sort.map do |n|
        choice = representatives(by_age[n])[turns[n] % by_age[n].size]
        turns[n] += 1
        shown[n] += 1
        choice
      end
    end
  end

  # Farthest-point spreading along the years: each pick is the age farthest
  # from everything already taken -- today (age 0) included -- and a tie
  # goes to the older year.
  def spread(pool, taken, slots)
    chosen = []
    pool = pool.dup
    while chosen.size < slots && pool.any?
      best = pool.max_by { |n| [([0] + taken + chosen).map { |c| (c - n).abs }.min, n] }
      chosen << best
      pool.delete(best)
    end
    chosen
  end

  # A year's posts in the order it offers them: titled ones first, longer
  # before shorter, then the order they were written in, so the choice is
  # the same on every machine that asks.
  def representatives(entries)
    entries.sort_by { |e| [e['titled'] ? 0 : 1, -e['words'].to_i, e['time'].to_s, e['slug'].to_s, e['url'].to_s] }
  end

  # --- what the widget reads ------------------------------------------------

  # The page's file for a date: the windows with just what a row shows,
  # and the whole day for "everything from this day". An empty day is still
  # a file -- with no windows in it, which is how the page knows to hide
  # the card rather than keep yesterday's.
  def reader_json(posts, date)
    shape = ->(e) { { 'ago' => e['ago'], 'year' => e['year'], 'title' => e['title'].to_s, 'url' => e['url'].to_s } }
    made = plan(posts, date)
    {
      'date' => made['date'],
      'windows' => made['windows'].map { |w| w.merge('rows' => w['rows'].map(&shape)) },
      'all' => made['all'].map(&shape)
    }.to_json
  end

  # --- the catalogue ---------------------------------------------------------
  #
  # The build is the one place that knows what a post is called and where it
  # lives in each language -- a translation's own title and address, a
  # fallback's, the site's own. The cron that turns the day over at midnight
  # knows none of that and must not learn it a second time, so every build
  # leaves a catalogue per language behind (beside the build cache, outside
  # the published tree), and the cron only ever chooses from it.

  def catalogue_path(root, lang)
    File.join(root, ".on-this-day.#{lang}.json")
  end

  # `tree` is where the language's pages live under public.nosync: '' for the
  # site's own language, the language code for the others.
  def write_catalogue(root, lang, tree, posts)
    data = { 'lang' => lang.to_s, 'tree' => tree.to_s, 'posts' => posts }
    path = catalogue_path(root, lang)
    tmp = "#{path}.tmp"
    File.write(tmp, data.to_json)
    File.rename(tmp, path)
    path
  end

  def remove_catalogue(root, lang)
    path = catalogue_path(root, lang)
    File.delete(path) if File.exist?(path)
  end

  # Catalogues of languages the site no longer publishes: nothing rebuilds
  # them, so the cron would keep writing a tree nobody builds.
  def prune_catalogues(root, keep)
    PathGlob.under(root, '.on-this-day.*.json').each do |path|
      lang = File.basename(path).delete_prefix('.on-this-day.').delete_suffix('.json')
      File.delete(path) unless keep.include?(lang)
    end
  end

  def catalogues(root)
    PathGlob.under(root, '.on-this-day.*.json').sort.filter_map do |path|
      data = JSON.parse(File.read(path, encoding: 'utf-8'))
      next unless data.is_a?(Hash) && data['posts'].is_a?(Array)

      data
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end

  # Writes today's file into every tree a catalogue names, and only when it
  # changed: cron runs every half hour and the day turns over once. Answers
  # with what it did, one entry per language, for the cron's own summary.
  def refresh(root:, public_dir:, date: Date.today)
    catalogues(root).filter_map do |data|
      tree = data['tree'].to_s
      next if tree.include?('/') || tree.include?('..')

      dir = tree.empty? ? public_dir : File.join(public_dir, tree)
      next unless Dir.exist?(dir)

      path = File.join(dir, FILE)
      text = reader_json(data['posts'], date)
      changed = !File.exist?(path) || File.read(path, encoding: 'utf-8') != text
      PublicFile.write(path, text) if changed
      { lang: data['lang'], path: path, posts: of_day(data['posts'], date).size, changed: changed }
    end
  end
end
