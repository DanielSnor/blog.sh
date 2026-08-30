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
require_relative '../lib/import/run_notes'
require_relative '../lib/import/beehiiv'
require_relative '../lib/import/blogger'
require_relative '../lib/import/bluesky'
require_relative '../lib/import/threads'
require_relative '../lib/import/tumblr'
require_relative '../lib/import/twitter'
require_relative '../lib/import/wayback'
require_relative '../lib/import/wix'
require_relative '../lib/import/facebook'
require_relative '../lib/import/feed'
require_relative '../lib/import/ghost'
require_relative '../lib/import/mastodon'
require_relative '../lib/import/medium'
require_relative '../lib/import/movable_type'
require_relative '../lib/import/pixelfed'
require_relative '../lib/import/podcast'
require_relative '../lib/import/instagram'
require_relative '../lib/import/jekyll'
require_relative '../lib/import/livejournal'
require_relative '../lib/import/squarespace'
require_relative '../lib/import/substack'
require_relative '../lib/import/pages_note'

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
  ['beehiiv', -> { build_beehiiv }],
  ['blogger', -> { build_blogger }],
  ['bluesky', -> { build_bluesky }],
  ['facebook', -> { build_facebook }],
  ['ghost', -> { build_ghost }],
  ['instagram', -> { build_instagram }],
  ['jekyll', -> { build_jekyll }],
  ['livejournal', -> { build_livejournal }],
  ['mastodon', -> { build_mastodon }],
  ['medium', -> { build_medium }],
  ['movabletype', -> { build_movabletype }],
  ['pixelfed', -> { build_pixelfed }],
  ['podcast', -> { build_podcast }],
  ['squarespace', -> { build_squarespace }],
  ['substack', -> { build_substack }],
  ['threads', -> { build_threads }],
  ['tumblr', -> { build_tumblr }],
  ['twitter', -> { build_twitter }],
  ['wayback', -> { build_wayback }],
  ['wix', -> { build_wix }],
  ['feed', -> { build_feed }]
].freeze

# Display names come from the locale (import.source.*) -- the service names
# are proper nouns, but the parentheticals ("account archive") are prose
# and read wrong left in English inside an otherwise translated menu.
def source_name(key)
  t("import.source.#{key}")
end

# Which answers are paths is decided from the prompt's own NAME rather than
# from a flag repeated at twenty-two call sites: every path question here is
# `*_path_prompt` or `*_dir_prompt`, and `*_source_prompt` takes either a
# path or a URL (where completion simply finds nothing and costs nothing).
# An importer added later gets Tab completion by following the naming, and
# the five questions that ask for a handle, a blog name or a URL never get
# it by accident.
PATH_PROMPTS = /_(path|dir|source)_prompt\z/.freeze

# The rows an import question stands on: which source is being imported
# from, and what has been answered about it so far. Same running record the
# other three wizards keep -- a frame repaints over the last question, so
# without it a two-question source would show the second one alone.
def import_context
  @import_context ||= []
end

def import_frame
  return unless Tui.interactive?

  room = [Tui.term_height - 4, 2].max
  rows = import_context.size > room ? import_context.last(room) : import_context.dup
  Tui.frame(rows + [''])
end

# The prompt row, closed. A frame ends its last line without a newline so
# the question can stand on it, and a question read with gets ends the same
# way -- what closes the row is the Enter echoing back. Two runs never get
# that echo: a piped one, where nothing is echoed at all, and a terminal one
# ended with Ctrl-D, where nothing was typed. Both left the row open, and
# whatever was said next landed ON the question:
#
#   Číslo zdroje, ze kterého importovat: Cesta k rozbalenému Substack
#   exportu (adresář s posts.csv; prázdné = zrušit): Zrušeno, nic se nezapsalo.
#
# -- three questions and the verdict on one line, which is how the piped
# wizard read from the beginning. Same `puts unless interactive?` Wizard.ask
# makes at the same point in its own question, and for the same reason; the
# nil is the EOF half, which ask does not have to handle because it raises.
def close_prompt_row(answer)
  puts if answer.nil? || !Tui.interactive?
end

def ask(prompt_key)
  import_frame
  value = if prompt_key.match?(PATH_PROMPTS)
            answer = Tui.path_line(t(prompt_key))
            # The readline half is its own case: in a terminal path_line goes
            # through readline, which breaks the line itself -- on Ctrl-D as
            # much as on Enter -- so closing the row again here would put TWO
            # blank lines under the question where every other prompt has one.
            # Down a pipe path_line is the same print-and-gets as below and
            # breaks nothing, which is the half that does need closing.
            puts unless Tui.interactive?
            answer
          else
            print t(prompt_key)
            answer = $stdin.gets
            close_prompt_row(answer)
            answer
          end
  value = value.to_s.strip
  return nil if value.empty?

  import_context << format('  %s %s', Tui.paint("#{t(prompt_key).sub(/:\s*\z/, '')}:", :dim),
                           Tui.truncate_to_width(value, 60))
  value
end

def build_beehiiv
  path = ask('import.beehiiv_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  return Import::Beehiiv.new(path) if File.exist?(path)

  puts t('import.beehiiv_path_invalid', path: path)
  nil
end

def build_blogger
  path = ask('import.blogger_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  return Import::Blogger.new(path) if File.exist?(path)

  puts t('import.blogger_path_invalid', path: path)
  nil
end

def build_bluesky
  handle = ask('import.bluesky_handle_prompt')
  handle && Import::Bluesky.new(handle)
end

# The key is read from the environment rather than prompted for: it's a
# credential, it belongs in env.sh next to the other tokens, and a prompt
# would invite pasting it into shell history.
def build_threads
  dir = ask('import.threads_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  return Import::Threads.new(dir) if Import::Threads.posts_file(dir)

  puts t('import.threads_dir_invalid', dir: dir)
  nil
end

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
# The pattern prompt is the second place empty does not cancel: without
# a pattern only posts with an explicit front matter permalink get a
# redirect, which is a valid answer.
def build_jekyll
  dir = ask('import.jekyll_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  unless Dir.exist?(dir)
    puts t('import.jekyll_dir_invalid', dir: dir)
    return nil
  end

  print t('import.jekyll_permalink_prompt')
  pattern = $stdin.gets
  close_prompt_row(pattern)
  pattern = pattern.to_s.strip
  Import::Jekyll.new(dir, permalink: pattern.empty? ? nil : pattern)
end

# The password is a credential and comes from the environment, exactly
# like the Tumblr key: a prompt would invite pasting it into history.
def build_livejournal
  password = ENV['LJ_PASSWORD']
  if password.to_s.empty?
    puts t('import.livejournal_password_missing')
    return nil
  end

  username = ask('import.livejournal_user_prompt')
  username && Import::Livejournal.new(username, password: password)
end

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

# Same two-prompt shape as Jekyll, for the same reason: the file cannot
# tell you its old URL shape, and an empty pattern is a valid answer
# (no redirects, or only TypePad's own UNIQUE URL lines).
def build_movabletype
  path = ask('import.movabletype_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  unless File.exist?(path)
    puts t('import.movabletype_path_invalid', path: path)
    return nil
  end

  print t('import.movabletype_pattern_prompt')
  pattern = $stdin.gets
  close_prompt_row(pattern)
  pattern = pattern.to_s.strip
  Import::MovableType.new(path, url_pattern: pattern.empty? ? nil : pattern)
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
def build_facebook
  dir = ask('import.facebook_dir_prompt')
  return nil unless dir

  dir = File.expand_path(dir)
  # The wizard prints the sentence telling people to set this, so the
  # wizard has to read it: with it set, the scripted path took the
  # crossposts and the wizard produced a byte-identical run without them,
  # and the advice under the count was the only thing that changed.
  crossposts = %w[1 true yes].include?(ENV['FACEBOOK_CROSSPOSTS'].to_s.strip.downcase)
  return Import::Facebook.new(dir, include_crossposts: crossposts) if Import::Facebook.posts_dir(dir)

  puts t('import.facebook_dir_invalid', dir: dir)
  nil
end

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
  # Both files, not just the tweets: the adapter needs account.js for the
  # handle, and checking only one of them meant the wizard accepted a path,
  # printed "Reading Twitter/X (@" and died on the very next expression --
  # its own validation was what promised to cope. Asked here, the person
  # gets to type the path again.
  missing = %w[tweets.js account.js].reject { |name| File.exist?(File.join(dir, 'data', name)) }
  unless missing.empty?
    puts t('import.twitter_dir_invalid', dir: dir, missing: missing.map { |n| "data/#{n}" }.join(', '))
    return nil
  end

  Import::Twitter.new(dir)
end

def build_podcast
  source = ask('import.podcast_source_prompt')
  return nil unless source

  local = File.expand_path(source)
  return Import::Podcast.new(local) if File.exist?(local)
  return Import::Podcast.new(source) if source.start_with?('http://', 'https://')

  puts t('import.feed_source_invalid', source: source)
  nil
end

def build_squarespace
  path = ask('import.squarespace_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  return Import::Squarespace.new(path) if File.exist?(path)

  puts t('import.squarespace_path_invalid', path: path)
  nil
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
  url = $stdin.gets
  close_prompt_row(url)
  url = url.to_s.strip
  url = nil if url.empty?
  if url && !url.start_with?('http://', 'https://')
    puts t('import.ghost_url_invalid', url: url)
    return nil
  end

  Import::Substack.new(dir, site_url: url)
end

def build_wayback
  url = ask('import.wayback_url_prompt')
  return nil unless url

  unless url.start_with?('http://', 'https://')
    puts t('import.wayback_url_invalid', url: url)
    return nil
  end

  # Same environment variables as scripts/migrate_wayback.rb: the advice
  # the run prints ("raise WAYBACK_DELAY", "pass POST_PATTERN") has to
  # work for the person who followed it and started the wizard again.
  Import::Wayback.from_env(url)
end

def build_wix
  path = ask('import.wix_path_prompt')
  return nil unless path

  path = File.expand_path(path)
  return Import::Wix.new(path) if File.exist?(path)

  puts t('import.wix_path_invalid', path: path)
  nil
end

# The interactive menu is two levels -- twenty sources in one column
# was a kilometre of scrolling. The groups are by what the THING was
# (a blog you published, a network you posted to, a site that no
# longer exists), because that is the question the user can answer
# without reading the whole list. The non-interactive path below stays
# ONE flat list on purpose: scripted `printf "N\n"` runs keep working
# across group reshuffles.
GROUPS = [
  ['blogs', %w[beehiiv blogger ghost jekyll livejournal medium movabletype
               podcast squarespace substack tumblr wix feed]],
  ['social', %w[bluesky facebook instagram mastodon pixelfed threads twitter]],
  ['wayback', %w[wayback]]
].freeze

def ask_source
  puts
  if Tui.interactive?
    loop do
      group_index = Tui.menu(GROUPS.map { |key, _| t("import.group.#{key}") },
                             hint: t('import.menu_hint', count: GROUPS.size))
      return nil if group_index.nil?

      key, members = GROUPS[group_index]
      # A group of one needs no second question.
      choices = members.map { |name| SOURCES.find { |k, _| k == name } }.compact
      if choices.size == 1
        import_context.replace([Tui.paint(source_name(choices.first.first), :bold), ''])
        # The same blank line the two-question path below writes, and for the
        # same reason: Tui.menu closes the row it left open but writes no
        # blank, so a source that says something before its first question
        # (a missing API key) would start hard against the menu's keys line
        # in one branch and a line clear of it in the other.
        puts
        return choices.first
      end

      # The group's name goes into the frame rather than being printed
      # above it -- the menu paints from the top of the viewport now, so
      # anything printed first is painted over.
      # Single-key pick reaches row 9 at most -- with more rows (blogs has
      # 13) the hint stops at 9 rather than promising keys that don't exist.
      index = Tui.menu(choices.map { |k, _| source_name(k) },
                       header: [t("import.group.#{key}"), ''],
                       hint: t('import.menu_hint', count: [choices.size, 9].min))
      # Backing out of a group is not backing out of the import --
      # return to the group question instead of quitting the wizard.
      next if index.nil?

      # The chosen source opens the record every question below it stands on.
      import_context.replace([Tui.paint(source_name(choices[index].first), :bold), ''])

      puts
      return choices[index]
    end
  end

  SOURCES.each_with_index { |(key, _), i| puts "#{i + 1}) #{source_name(key)}" }
  puts
  print t('import.enter_number')
  input = $stdin.gets
  close_prompt_row(input)
  input = input.to_s.strip
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
#
# The safety net is for adapters the engine does NOT ship. Every reason our
# own adapters return belongs here, and for a long time eleven of them did
# not: each source added during 1.2 brought its own vocabulary and this list
# stayed where the first four sources had left it. The wizard then printed
# "skipped (crosspost): 1598" in Czech, one line above a Czech sentence
# reporting the same number -- and nobody noticed, because the big
# migrations run through migrate_*.rb, whose summary is English by design
# (lib/import/cli.rb). tests/test_gaps.rb now walks every adapter and fails
# if a reason it can return is missing here or from any of the three
# locales, so the next source cannot repeat it.
TRANSLATED_REASONS = %w[
  reply repost quote empty attachment not_a_post trashed boost reblog error undated comment
  retweet crosspost checkin no_content thread missing_html bad_frontmatter no_identity
  no_audio media_unfetchable unparsed bad_date misaligned_row site_furniture
].freeze

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
  # A preview counts what the run will go after, not what will arrive --
  # nothing is downloaded here, and one real archive promised 64 files of
  # which the source had kept none. Said out loud, or the number above
  # reads as a delivery.
  puts Tui.paint(t('import.media_not_verified'), :cyan) if dry_run && result.media.positive?
  # The number that separates a first import from a second one. Shown in
  # the preview too, where it is the honest half of the media count above:
  # some of them are already here and will not be fetched at all.
  puts Tui.paint(t('import.media_reused', count: result.media_reused), :cyan) if result.media_reused.to_i.positive?
  # Downloads that no longer matched the archive's copy under their name
  # and were discarded for it -- the source has drifted, and this line is
  # the only place that fact surfaces. Never set on a dry run, which
  # downloads nothing.
  if result.respond_to?(:media_superseded) && result.media_superseded.to_i.positive?
    puts Tui.paint(t('import.media_superseded', count: result.media_superseded), :yellow)
  end

  unless result.samples.empty?
    puts t('import.sample_slugs')
    result.samples.each { |slug| puts "  #{slug}" }
  end

  result.skipped.each do |reason, count|
    puts t('import.skipped', count: count, reason: reason_label(reason))
  end

  # Pages arrive out of the listings, out of the archive and out of the
  # feed -- which is what they are for, and also means nothing on the site
  # links to them. This sentence is the only thing that says so, and the
  # wizard lost it when the note moved out of the adapters: Cli.report got
  # it, and the wizard has a report of its own.
  pages_note = Import.pages_note(Array(result.respond_to?(:pages) ? result.pages : nil))
  puts Tui.paint(pages_note, :cyan) if pages_note

  # What the HTML parser could not represent -- an iframe, a video, a form
  # -- and a source that handed out the same id twice. Both were counted
  # all along and printed only by the scripted door, so the wizard, which
  # is the door most people use, reported an import full of holes as
  # "Wrote N post(s)" and no more. Said in the preview too, where it can
  # still change the answer to the confirmation below.
  dropped_note = Import.dropped_note(result.respond_to?(:dropped_elements) ? result.dropped_elements : nil)
  puts Tui.paint(dropped_note, :yellow) if dropped_note
  dupes_note = Import.duplicate_ids_note(result.respond_to?(:duplicate_ids) ? Array(result.duplicate_ids) : [])
  puts Tui.paint(dupes_note, :yellow) if dupes_note

  # An item that failed is a loss, not a category of skip -- and the count
  # alone leaves the reader to guess which of five thousand it was.
  errors = Array(result.respond_to?(:errors) ? result.errors : nil)
  unless errors.empty?
    puts Tui.paint(t('import.items_failed', count: errors.size), :yellow)
    errors.first(3).each { |line| puts "  #{line}" }
  end

  return if result.media_failures.empty?

  # Two different losses, said separately: a file missing from a post that
  # WAS written, and one from a post the run skipped entirely (a photo-only
  # post whose only image is gone maps to :empty). One line for both told
  # the author their skipped posts had been "written without" the file.
  skipped_failures = Array(result.skipped_media_failures)
  # Counted off one by one, not with Array#- : the same missing file can be
  # referenced by a post that WAS written and by one that was skipped, and
  # the set difference removes every occurrence -- so one shared file
  # erased the written post's loss from the report entirely.
  from_written = result.media_failures.dup
  skipped_failures.each do |path|
    i = from_written.index(path)
    from_written.delete_at(i) if i
  end
  unless from_written.empty?
    # A preview downloads nothing and writes nothing, so the sentence about
    # posts that "were written without them" is not available to it -- it
    # says what the real run would do instead.
    puts Tui.paint(t(dry_run ? 'import.media_failed_preview' : 'import.media_failed',
                     count: from_written.size), :yellow)
    from_written.first(3).each { |url| puts "  #{url}" }
  end
  unless skipped_failures.empty?
    # The same honesty as its sibling above: a preview downloads nothing,
    # so nothing "could not be downloaded" in it.
    puts Tui.paint(t(dry_run ? 'import.media_failed_skipped_preview' : 'import.media_failed_skipped',
                     count: skipped_failures.size), :yellow)
    skipped_failures.first(3).each { |url| puts "  #{url}" }
  end
  return
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
  answer = $stdin.gets
  close_prompt_row(answer)
  answer.to_s.strip == count.to_s
end

def run_import(adapter)
  # Asked per adapter capability, not per platform list, so any future
  # importer that stores original addresses gets the question for free.
  # The default is no: a wrong yes writes redirects to addresses that were
  # never this domain's to answer, a wrong no just loses a convenience the
  # re-import (source-id matched, so safe) can add back later.
  if adapter.respond_to?(:keep_permalinks=)
    puts
    # Tui.yes?, not a bare compare against the localized yes-char: the
    # Czech prompt reads [a/N], but a reader who presses 'y' out of habit
    # would otherwise get "no" silently and lose every old address. yes?
    # accepts y / j / a and the localized character alike.
    adapter.keep_permalinks = Tui.yes?(Tui.key_choice(t('import.keep_permalinks_prompt')))
  end

  puts
  puts t('import.dry_run_running', label: adapter.label)
  # An adapter counts as it goes -- snapshots read, items it could not
  # parse, pictures the Archive never saved -- and the wizard runs the SAME
  # adapter twice: once for the preview, once for real. Without putting the
  # counters back, the postscript after the real run reported both runs
  # added together, so "N image(s) are lost" said twice what was lost. Only
  # whole numbers are touched: those are the counters, and everything else
  # an adapter holds -- its paths, its parsed export -- has to survive.
  counters = Import::Run.counter_snapshot(adapter)
  preview = Import::Run.new(adapter, dry_run: true, on_scan: scan_reporter).call
  print "\r\e[2K" if Tui.interactive?
  report(preview, dry_run: true)
  # The adapter's own note -- scheduled posts becoming drafts, gigabytes
  # of podcast audio -- belongs in the preview, where it can still change
  # the answer to the question below.
  puts "  #{adapter.postscript}" if adapter.respond_to?(:postscript) && adapter.postscript

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
  # The preview is over; the adapter goes back to how it started so the
  # numbers below are this run's, not both runs'.
  Import::Run.restore_counters(adapter, counters)

  puts t('import.running', label: adapter.label)
  # Media is downloaded for real this time, so an archive of any size takes
  # a while -- a line per post is the progress report. The dry-run just
  # counted exactly how many posts will be written, which makes it the one
  # honest denominator available here.
  target = preview.written
  on_post = ->(written, post, _scanned) { puts "  #{written}/#{target} #{post['slug']}" }
  result = Import::Run.new(adapter, on_post: on_post).call
  report(result, dry_run: false)
  # ...and again here, because several of these notes only have numbers
  # in them AFTER the real run: the Wayback rescue counts the images the
  # Archive never saved as it fetches them, so "N image(s) are lost" --
  # the one line that says what the rescue actually cost -- could not be
  # printed anywhere the operator would see it. The preview's copy is
  # what changes the answer to the question above; this one is the
  # record of what happened.
  puts "  #{adapter.postscript}" if adapter.respond_to?(:postscript) && adapter.postscript
  # Whatever the run lost, the exit code has to carry -- scripts/*.rb have
  # done this since 1.2 (lib/import/cli.rb), and the wizard, which is what
  # people actually run, ended 0 on a source that died halfway and on every
  # item it failed to write. The status is set here and acted on at the very
  # end, so the offer to rebuild still happens.
  @lost = result.interrupted || Array(result.respond_to?(:errors) ? result.errors : nil).any?

  puts
  rebuild = Tui.key_choice(t('import.rebuild_prompt'))
  # Declining is where the import ends, so it owes the one trailing blank
  # line every command here ends with. Without it the last thing on screen
  # was the unfinished question itself -- and down a pipe the output ended
  # mid-line, with no newline at all.
  if rebuild == 'n'
    puts
    return
  end

  Publishing.rebuild_and_deploy(t('import.rebuilding'))
end

if Tui.interactive?
  puts SiteHeader.render(tool: './import.sh')
end

source = ask_source
if source.nil?
  # A blank line before the verdict, the way the interrupt handler below and
  # the cancelled confirmation in run_import both write one. The same
  # sentence was reached three ways and framed three ways: once with a blank
  # line above it and twice hard against whatever the screen last showed --
  # the menu's keys line, or the question that had just been left empty.
  puts
  puts t('import.cancelled')
  puts
  exit 0
end

adapter = source[1].call
if adapter.nil?
  puts
  puts t('import.cancelled')
  puts
  exit 0
end

begin
  run_import(adapter)
  exit 1 if @lost
rescue Interrupt
  # Ctrl-C during an hours-long run: say what state things are in, because
  # a half-finished import leaves real posts on disk.
  puts
  puts t('import.interrupted')
  puts
  exit 1
end
