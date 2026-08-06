#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/import.rb -- the import wizard, run via ./import.sh.
#
# A separate entry point from ./blog.sh on purpose. Writing is a daily
# loop; importing is a rare, bulk, hard-to-undo operation that drops
# thousands of files into content.nosync/ at once. Keeping it behind its
# own door means the authoring menu stays about authoring, and the
# dangerous thing needs deliberately opening.
#
# Every import is measured before it's made: the wizard always runs the
# adapter in dry-run first and shows what *would* be written, because the
# alternative -- finding out afterwards that 2000 posts got the wrong
# slugs -- has no cheap fix. Re-running an import is safe either way
# (PostWriter matches on source.platform/account/original_id and
# overwrites in place), but "safe" isn't the same as "what you wanted".

require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

require_relative '../lib/tui'
require_relative '../lib/site_header'
require_relative '../lib/i18n'
require_relative '../lib/publishing'
require_relative '../lib/import/run'
require_relative '../lib/import/bluesky'
require_relative '../lib/import/tumblr'
require_relative '../lib/import/twitter'
require_relative '../lib/import/feed'
require_relative '../lib/import/ghost'
require_relative '../lib/import/mastodon'
require_relative '../lib/import/medium'
require_relative '../lib/import/pixelfed'
require_relative '../lib/import/instagram'
require_relative '../lib/import/substack'

def t(key, **vars)
  I18n.t(key, **vars)
end

# Alphabetical by the name shown, so a growing list needs no judgement call
# about where the next source belongs -- and so nobody has to hunt for one.
#
# Note that the non-interactive path selects by position, so reordering this
# changes what `printf "4\n"` means. Nothing in the repo or the documented
# cron pipes a number today, but anyone who has scripted one should re-read
# their script after a change here.
SOURCES = [
  ['bluesky', -> { build_bluesky }],
  ['ghost', -> { build_ghost }],
  ['instagram', -> { build_instagram }],
  ['mastodon', -> { build_mastodon }],
  ['medium', -> { build_medium }],
  ['pixelfed', -> { build_pixelfed }],
  ['substack', -> { build_substack }],
  ['tumblr', -> { build_tumblr }],
  ['twitter', -> { build_twitter }],
  ['feed', -> { build_feed }]
].freeze

# Display names come from the locale (import.source.*) -- the service names
# are proper nouns, but the parentheticals ("account archive") are prose
# and read wrong left in English inside an otherwise translated menu.
def source_name(key)
  t("import.source.#{key}")
end

def ask(prompt_key)
  print t(prompt_key)
  value = $stdin.gets.to_s.strip
  value.empty? ? nil : value
end

def build_bluesky
  handle = ask('import.bluesky_handle_prompt')
  handle && Import::Bluesky.new(handle)
end

# The key is read from the environment rather than prompted for: it's a
# credential, it belongs in env.sh next to the other tokens, and a prompt
# would invite pasting it into shell history.
def build_tumblr
  api_key = ENV['TUMBLR_API_KEY']
  if api_key.to_s.empty?
    puts t('import.tumblr_key_missing')
    return nil
  end

  blog = ask('import.tumblr_blog_prompt')
  blog && Import::Tumblr.new(blog, api_key: api_key)
end

# One prompt for all three inputs it accepts: they are the same format --
# a WXR export is RSS 2.0 with extra elements -- so asking which kind it is
# would be asking the user something the file already says.
def build_mastodon
  dir = ask('import.mastodon_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  return Import::Mastodon.new(dir) if File.exist?(File.join(dir, 'outbox.json'))

  puts t('import.mastodon_dir_invalid', dir: dir)
  nil
end

# Pointed at the unpacked export as a whole rather than at the posts file:
# the media lives outside your_instagram_activity/, and so does the profile
# page the account name comes from. One prompt for both formats the
# download offers -- the export says which one it is, so asking would be
# asking the user something their own directory already answers.
def build_instagram
  dir = ask('import.instagram_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  return Import::Instagram.new(dir) if Import::Instagram.format_of(dir)

  puts t('import.instagram_dir_invalid', dir: dir)
  nil
end

def build_medium
  dir = ask('import.medium_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  return Import::Medium.new(dir) if Dir.exist?(File.join(dir, 'posts'))

  puts t('import.medium_dir_invalid', dir: dir)
  nil
end

def build_pixelfed
  path = ask('import.pixelfed_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  return Import::Pixelfed.new(path) if File.exist?(path)

  puts t('import.pixelfed_path_invalid', path: path)
  nil
end

def build_feed
  source = ask('import.feed_source_prompt')
  return nil unless source

  local = File.expand_path(source)
  return Import::Feed.new(local) if File.exist?(local)
  return Import::Feed.new(source) if source.start_with?('http://', 'https://')

  puts t('import.feed_source_invalid', source: source)
  nil
end

# Two prompts, because the export genuinely cannot answer the second one:
# every image in it is a "__GHOST_URL__/..." reference -- the site's own
# address, deliberately never spelled out -- and the files only exist on
# the live site. So the URL is required, and importing after the old site
# goes dark loses exactly the images.
def build_ghost
  path = ask('import.ghost_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  unless File.exist?(path)
    puts t('import.ghost_path_invalid', path: path)
    return nil
  end

  url = ask('import.ghost_url_prompt')
  return nil unless url

  unless url.start_with?('http://', 'https://')
    puts t('import.ghost_url_invalid', url: url)
    return nil
  end

  Import::Ghost.new(path, site_url: url)
end

def build_twitter
  dir = ask('import.twitter_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  unless File.exist?(File.join(dir, 'data', 'tweets.js'))
    puts t('import.twitter_dir_invalid', dir: dir)
    return nil
  end

  Import::Twitter.new(dir)
end

# The URL prompt is the one place empty does NOT cancel: the /p/<slug>
# paths that redirects need are derivable from the export alone, so the
# domain is a nice-to-have for provenance, not a requirement worth
# aborting over.
def build_substack
  dir = ask('import.substack_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  unless File.exist?(File.join(dir, 'posts.csv'))
    puts t('import.substack_dir_invalid', dir: dir)
    return nil
  end

  print t('import.substack_url_prompt')
  url = $stdin.gets.to_s.strip
  url = nil if url.empty?
  if url && !url.start_with?('http://', 'https://')
    puts t('import.ghost_url_invalid', url: url)
    return nil
  end

  Import::Substack.new(dir, site_url: url)
end

def ask_source
  puts
  if Tui.interactive?
    index = Tui.menu(SOURCES.map { |key, _| source_name(key) }, hint: t('import.menu_hint'))
    return nil if index.nil?

    puts
    return SOURCES[index]
  end

  SOURCES.each_with_index { |(key, _), i| puts "#{i + 1}) #{source_name(key)}" }
  puts
  print t('import.enter_number')
  input = $stdin.gets.to_s.strip
  # Range-checked rather than indexed straight off to_i: "" and "abc" both
  # become 0, and SOURCES[-1] is the *last* source -- so a piped run with no
  # answer would silently start importing from whatever happens to be at the
  # bottom of the list.
  return nil unless input.match?(/\A[1-9]\d*\z/) && input.to_i <= SOURCES.size

  SOURCES[input.to_i - 1]
end

# I18n.t aborts on a missing key by design, which is right for text the
# engine ships -- but a skip reason comes from an adapter, and a new adapter
# inventing one must not take the wizard down mid-summary. Translated when
# known, printed raw when not.
TRANSLATED_REASONS = %w[reply repost quote empty attachment page not_a_post trashed boost reblog error].freeze

def reason_label(reason)
  TRANSLATED_REASONS.include?(reason.to_s) ? t("import.reason.#{reason}") : reason.to_s
end

# Prints the same shape for the dry-run preview and the real result, so the
# second is directly comparable to the first -- the point of showing both.
def report(result, dry_run:)
  puts
  # Said before the counts, so the counts read as what they are -- a
  # partial tally, not the whole source. The dry-run case matters just as
  # much: the "type the number of posts" confirmation below quotes this
  # run's count, and confirming a partial preview should be a decision,
  # not an accident.
  puts Tui.paint(t('import.source_died', count: result.scanned, error: result.interrupted), :yellow) if result.interrupted
  puts Tui.paint(t(dry_run ? 'import.would_write' : 'import.written',
                   count: result.written, media: result.media), dry_run ? :cyan : :green)

  unless result.samples.empty?
    puts t('import.sample_slugs')
    result.samples.each { |slug| puts "  #{slug}" }
  end

  result.skipped.each do |reason, count|
    puts t('import.skipped', count: count, reason: reason_label(reason))
  end

  return if result.media_failures.empty?

  puts Tui.paint(t('import.media_failed', count: result.media_failures.size), :yellow)
  result.media_failures.first(3).each { |url| puts "  #{url}" }
end

# The reading pass has no per-post output to show -- it deliberately writes
# nothing -- so it reports the count as it goes. A silent terminal during the
# minutes it takes to page through a large archive is indistinguishable from
# a hung one, and the honest answer to "is it still working?" is a number
# that keeps moving. Rewritten in place on a TTY, one line per hundred when
# piped, so a log doesn't fill up with progress.
def scan_reporter
  lambda do |scanned, _written|
    if Tui.interactive?
      print "\r\e[2K  #{Tui.paint(t('import.scanned', count: scanned), :dim)}"
    elsif (scanned % 100).zero?
      puts "  #{t('import.scanned', count: scanned)}"
    end
  end
end

# The count has to be typed out, not answered with a keypress. Deleting a
# single post already makes you type its slug; writing two thousand of them
# was one 'y', which had the bigger action behind the weaker gate. Typing
# the number is also the one answer that can't be given without having read
# the preview -- which is the whole reason the preview runs.
#
# Anything else cancels, including a mistyped number: the run is repeatable,
# so a wrong cancel costs a re-read, while a wrong confirm costs an archive.
def confirmed?(count)
  print t('import.confirm_prompt', count: count)
  $stdin.gets.to_s.strip == count.to_s
end

def run_import(adapter)
  # Asked per adapter capability, not per platform list, so any future
  # importer that stores original addresses gets the question for free.
  # The default is no: a wrong yes writes redirects to addresses that were
  # never this domain's to answer, a wrong no just loses a convenience the
  # re-import (source-id matched, so safe) can add back later.
  if adapter.respond_to?(:keep_permalinks=)
    puts
    adapter.keep_permalinks = Tui.key_choice(t('import.keep_permalinks_prompt')) == t('cli.confirm_yes_char')
  end

  puts
  puts t('import.dry_run_running', label: adapter.label)
  preview = Import::Run.new(adapter, dry_run: true, on_scan: scan_reporter).call
  print "\r\e[2K" if Tui.interactive?
  report(preview, dry_run: true)

  if preview.written.zero?
    puts
    puts t('import.nothing_to_import')
    puts
    return
  end

  puts
  unless confirmed?(preview.written)
    puts
    puts t('import.cancelled')
    puts
    return
  end

  puts
  puts t('import.running', label: adapter.label)
  # Media is downloaded for real this time, so an archive of any size takes
  # a while -- a line per post is the progress report. The dry-run just
  # counted exactly how many posts will be written, which makes it the one
  # honest denominator available here.
  target = preview.written
  on_post = ->(written, post, _scanned) { puts "  #{written}/#{target} #{post['slug']}" }
  result = Import::Run.new(adapter, on_post: on_post).call
  report(result, dry_run: false)

  puts
  return if Tui.key_choice(t('import.rebuild_prompt')) == 'n'

  Publishing.rebuild_and_deploy(t('import.rebuilding'))
end

if Tui.interactive?
  puts SiteHeader.render(tool: './import.sh')
end

source = ask_source
if source.nil?
  puts t('import.cancelled')
  puts
  exit 0
end

adapter = source[1].call
if adapter.nil?
  puts t('import.cancelled')
  puts
  exit 0
end

begin
  run_import(adapter)
rescue Interrupt
  # Ctrl-C during an hours-long run: say what state things are in, because
  # a half-finished import leaves real posts on disk.
  puts
  puts t('import.interrupted')
  puts
  exit 1
end
