#!/usr/bin/env ruby
# Manual authoring tool: add / edit / delete / list posts by hand, via
# $EDITOR on a markdown-with-frontmatter file, sharing the exact same
# content-block + PostWriter path as the migration scripts. No network, no
# server -- runs entirely as a local CLI, so none of the admin-server CSRF/
# binding concerns apply.

require 'json'
require 'time'
require 'fileutils'
require 'tmpdir'
require 'set'
require 'securerandom'
require 'shellwords'
require_relative '../lib/post_writer'
require_relative '../lib/atomic_write'
require_relative '../lib/mastodon_poster'
require_relative '../lib/bluesky_poster'
require_relative '../lib/site_config'
require_relative '../lib/markdown_parser'
require_relative '../lib/markdown_writer'
require_relative '../lib/media_dimensions'
require_relative '../lib/heic_converter'
require_relative '../lib/file_size'
require_relative '../lib/slug'
require_relative '../lib/content_type'
require_relative '../lib/publishing'
require_relative '../lib/publish_slots'
require_relative '../lib/tui'
require_relative '../lib/site_header'
require_relative '../lib/qr_code'
require_relative '../lib/preview_server'
require_relative '../lib/i18n'
require_relative '../lib/version'

SiteConfig.use_site_timezone!

def t(key, **vars)
  I18n.t(key, **vars)
end

ROOT = File.expand_path('..', __dir__)
CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
MEDIA_DIR = File.join(ROOT, 'media.nosync')
INCOMING_DIR = File.join(ROOT, 'incoming')
TRASH_DIR = File.join(ROOT, 'trash')
SITE_BASE_URL = ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')
# Optional (`get`, not `fetch`) so the wizard header degrades quietly
# instead of aborting the whole CLI over a config field it only wants
# to display, not require.
SITE_SHORT_NAME = SiteConfig.get('site', 'short_name')
SITE_DESCRIPTION = SiteConfig.get('site', 'description')

DRAFT = 'draft'
PUBLISHED = 'published'

def draft?(post)
  post['state'] == DRAFT
end

# The preview address is protected by a random token: the draft text does
# physically sit on the public site (otherwise it couldn't be opened from an
# iPad, which is the whole reason this exists), but it can't be guessed or
# reached from anywhere else. The build also adds noindex to it.
def draft_url(post)
  "#{SITE_BASE_URL.to_s.chomp('/')}/draft/#{post['draft_token']}/#{post['slug']}/"
end

def published_url(slug, year)
  "#{SITE_BASE_URL.to_s.chomp('/')}/posts/#{year}/#{slug}/"
end

# --- frontmatter ------------------------------------------------------
#
# Both directions of the markdown round-trip live in lib/: text -> blocks
# in lib/markdown_parser.rb (shared with build_blog.rb), blocks -> markdown
# in lib/markdown_writer.rb (used by `blog.sh edit` below). What stays here
# is authoring validation tied specifically to this CLI.

FRONTMATTER_KEYS = %w[title tags type date pinned].freeze

# A key the parser doesn't know is silently dropped -- `pined: true` would
# do nothing at all and never say so. Every key the author typed is checked
# against the list above, and an unknown one stops the save while the text
# is still recoverable (the editor buffer holds it).
def abort_on_unknown_frontmatter(meta)
  unknown = meta.keys.reject { |k| FRONTMATTER_KEYS.include?(k.to_s) }
  return if unknown.empty?

  abort t('cli.unknown_frontmatter_key', keys: unknown.join(', '), known: FRONTMATTER_KEYS.join(', '))
end

# "true"/"yes"/"1" are all true, everything else false -- a frontmatter
# value is text the author typed, not a YAML boolean.
def truthy_frontmatter?(value)
  %w[true yes 1].include?(value.to_s.strip.downcase)
end

# Text pasted into the editor along with its own header hides underneath
# the one already prepared: parse_frontmatter treats the first (empty)
# header as the real one and everything else as body. No title is produced
# then, and the slug is derived from the text's first eight words instead --
# exactly how a cheat-sheet-titled post once ended up with a slug like
# "title-markdown-cheat-sheet-tags".
def frontmatter_key_line?(line)
  FRONTMATTER_KEYS.any? { |k| line.to_s.strip.start_with?("#{k}:") }
end

def frontmatter_in_body?(body)
  lines = body.to_s.lstrip.split("\n")
  return false if lines.empty?

  # Either the pasted header is complete including its separators, or the
  # leading one got lost during paste and the body starts right at a key --
  # same failure mode as the cheat-sheet slug example above.
  start = lines.first.strip == '---' ? 1 : 0
  return false if start.zero? && !frontmatter_key_line?(lines.first)

  finish = lines[start, 12].to_a.index { |l| l.strip == '---' }
  return false unless finish

  lines[start, finish].to_a.any? { |l| frontmatter_key_line?(l) }
end

def abort_on_double_frontmatter(body)
  return unless frontmatter_in_body?(body)

  abort t('cli.double_frontmatter_error')
end

# Pauses so a still-in-transit photo (e.g. being SFTP'd into incoming/ from
# an iPad/iPhone while the post is being written away from the Mac) can
# actually arrive before the post gets written -- loops, re-checking after
# each Enter, until every missing source exists or the author types the
# cancel word.
def wait_for_missing_images(missing)
  return if missing.empty?

  loop do
    pending = missing.reject { |src| File.exist?(src) }
    return if pending.empty?

    puts t('cli.missing_images_wait', count: pending.size)
    pending.each { |src| puts "  - #{src}" }
    print t('cli.missing_images_prompt', cancel_word: t('cli.cancel_word'))
    input = $stdin.gets
    # nil is EOF, not an empty answer: a closed stdin (a piped run whose
    # input ran out, an SSH session that timed out) can never deliver the
    # files, and re-checking it in a tight loop only burns a CPU core until
    # someone kills the process. Give up instead.
    abort t('cli.missing_images_eof') if input.nil?

    abort t('cli.cancelled_nothing_saved') if input.strip.downcase == t('cli.cancel_word')
  end
end

# Deletes each source image that was actually copied this run, but only if it
# came from incoming/ -- that's a disposable SFTP staging area, so once a
# photo has been copied into media/ its incoming/ copy is just clutter
# (keeping incoming/ empty makes it obvious which uploads are still pending).
# Sources outside incoming/ (e.g. a normal Mac path) are the author's own
# files and are never touched.
#
# extra_sources: originals a HEIC conversion consumed. Their converted
# stand-ins are what media_files points at (a temp path, never touched
# here), but the staged .heic was used up exactly like a directly-copied
# photo -- in converted form -- so the same "empty incoming/ means nothing
# pending" rule applies to it.
def cleanup_incoming(media_files, extra_sources = [])
  (media_files.keys + extra_sources).each do |src|
    next unless src

    expanded = File.expand_path(src)
    next unless expanded.start_with?("#{File.expand_path(INCOMING_DIR)}/")

    File.delete(expanded) if File.exist?(expanded)
  end
end

# Converts -- or refuses -- HEIC photos among the freshly attached media,
# by media.convert_heic in config/site.yml. Runs after
# wait_for_missing_images (the files provably exist) and before
# fill_image_dimensions, so a converted photo is measured as the JPEG the
# page will actually serve and reserves layout space like any other image.
# Detection is by content, so a HEIC smuggled in as .jpg is caught too.
#
# Refusal is the default and aborts BEFORE anything is copied or deleted:
# a HEIC on the page would show as a broken image everywhere but Safari,
# and the author's text survives the abort in the editor buffer. Returns
# the original files a successful conversion consumed, for
# cleanup_incoming.
def convert_heic_attachments(blocks, media_files)
  heic = media_files.keys.select { |src| src && HeicConverter.heic?(src) }
  return [] if heic.empty?

  names = heic.map { |src| File.basename(src) }.join(', ')
  command = HeicConverter.suggested_command(heic.first)
  unless SiteConfig.get('media', 'convert_heic', default: false) == true
    abort t('cli.heic_refused', files: names, command: command)
  end

  tool = HeicConverter.tool
  abort t('cli.heic_no_tool', files: names, command: command) unless tool

  # One temp dir per process, removed at exit: the converted files must
  # outlive this pass (PostWriter copies them much later in the save).
  @heic_tmpdir ||= begin
    dir = Dir.mktmpdir('blog-sh-heic')
    at_exit { FileUtils.remove_entry(dir) if Dir.exist?(dir) }
    dir
  end

  heic.map do |src|
    filename = media_files[src]
    target = "#{File.basename(filename, '.*')}.jpg"
    dest = File.join(@heic_tmpdir, target)
    unless HeicConverter.convert(src, dest)
      abort t('cli.heic_convert_failed', file: File.basename(src), tool: tool[0],
                                         command: HeicConverter.suggested_command(src))
    end

    media_files.delete(src)
    media_files[dest] = target
    # The blocks already reference the pre-conversion filename (NN.heic);
    # the number is kept, only the extension follows the real bytes.
    blocks.each do |b|
      media = (b['media'] || []).first
      media['url'] = target if media && media['url'] == filename
    end
    puts t('cli.heic_converted', file: File.basename(src), target: target, tool: tool[0])
    src
  end
end

# Refuses a file the deploy could never place, at the one moment the author
# can still do something about it. Runs right after the HEIC pass, so the
# bytes measured are the bytes the page will carry, and -- like that pass --
# before anything is copied: the abort leaves the source where it is and the
# text in the editor buffer.
#
# Saving with a warning and refusing at deploy time would be the worse pair
# of halves: the post is on the site's list, the announcement for a
# scheduled one is already public, and the fix is only available to whoever
# is watching the deploy. One limit for every backend, so this is the same
# answer wherever the site is hosted -- see lib/file_size.rb.
#
# Only what this save brings in. A file already sitting in the post's media
# directory was accepted once; re-refusing it would lock an old post out of
# editing, and the deploy names it there instead.
def check_attachment_sizes(media_files)
  # The SOURCE name, like the HEIC refusal uses: media_files maps to the
  # stored name (01.pdf), which the author has never seen and cannot act on.
  sized = media_files.filter_map do |src, _filename|
    next unless src && File.exist?(src)

    [File.basename(src), File.size(src)]
  end
  return if sized.empty?

  limit = ->(bytes) { FileSize.human(bytes) }
  describe = ->(list) { list.map { |(name, bytes)| "#{name} (#{limit.call(bytes)})" }.join(', ') }

  hard = sized.select { |(_, bytes)| FileSize.classify(bytes) == :hard }
  abort t('cli.media_too_large', files: describe.call(hard), limit: limit.call(FileSize::HARD_LIMIT)) if hard.any?

  soft = sized.select { |(_, bytes)| FileSize.classify(bytes) == :soft }
  puts t('cli.media_large', files: describe.call(soft), limit: limit.call(FileSize::HARD_LIMIT)) if soft.any?
end

# --- editor round-trip -------------------------------------------------

# Where the text from the last editor session waits until the post it
# belongs to is safely on disk. The temp directory the editor works in is
# gone the moment edit_in_editor returns, but every check on what was
# typed -- a second frontmatter header, an image line without its blank
# lines, an unparseable date, a content-loss confirmation -- runs after
# that and aborts. Without this copy those aborts threw the article away.
EDITOR_BUFFER_PATH = File.join(ROOT, '.last-edit.md')

def keep_editor_buffer(text)
  File.write(EDITOR_BUFFER_PATH, text)
  File.chmod(0o600, EDITOR_BUFFER_PATH)
rescue SystemCallError
  nil # a buffer we can't write is not a reason to refuse the save
end

def discard_editor_buffer
  File.delete(EDITOR_BUFFER_PATH) if File.exist?(EDITOR_BUFFER_PATH)
rescue SystemCallError
  nil
end

# Says where the text is if the process ends with the buffer still there.
# Every successful save discards it first, so this only speaks up when the
# post did not make it to disk -- whichever of the many aborts (or a
# Ctrl-C) got in the way, without each of them having to know about it.
def arm_editor_buffer_notice
  return if @editor_buffer_notice_armed

  @editor_buffer_notice_armed = true
  at_exit do
    warn t('cli.editor_buffer_kept', path: EDITOR_BUFFER_PATH) if File.exist?(EDITOR_BUFFER_PATH)
  end
end

def edit_in_editor(initial_content, hint_comment)
  text = editor_round_trip(initial_content, hint_comment)
  keep_editor_buffer(text)
  arm_editor_buffer_notice
  text
end

def editor_round_trip(initial_content, hint_comment)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'post.md')
    File.write(path, "#{hint_comment}#{initial_content}")
    editor = ENV['EDITOR'] || ENV['VISUAL'] || 'nano --breaklonglines --softwrap'
    ok = system(*Shellwords.split(editor), path)
    # The default nano flags postdate the 2007-vintage nano Apple still
    # ships -- when the *default* editor rejects them, retry bare nano
    # before giving up. A user's own $EDITOR gets no second-guessing.
    ok ||= ENV['EDITOR'].nil? && ENV['VISUAL'].nil? && system('nano', path)
    unless ok
      abort("$EDITOR (#{editor}) failed -- set the EDITOR environment variable " \
            'to an editor that exists here (e.g. export EDITOR=vim) and rerun.')
    end
    edited = File.read(path, encoding: 'utf-8')
    edited = edited.gsub(/^<!--.*?-->\n/m, '')
    edited.gsub(%r{^//.*\n?}, '')
  end
end

# Full syntax reference. The in-editor hint just links to it, so the hint
# doesn't bloat and can't drift from what the parser actually supports.
# A generated page (build_blog.rb, CHEAT_SHEET_PATH), not a post -- it can't
# be deleted or unpublished through blog.sh, it exists for as long as
# templates/markdown-cheat-sheet.<lang>.md does (localized by site.lang,
# falling back to English -- see cheat_sheet_source in build_blog.rb).
CHEAT_SHEET_URL = "#{SITE_BASE_URL.to_s.chomp('/')}/markdown/".freeze

FRONTMATTER_HINT = t('cli.frontmatter_hint', cheat_sheet_url: CHEAT_SHEET_URL)

# No `date:` line: publishing time now comes from exactly one of two
# places -- "now" at the moment of publish, or the schedule dialog's own
# date prompt -- so showing a third, editable date in the frontmatter
# would just be a confusing extra path to the same decision. The parser
# still honors a `date:` line if someone types one in by hand (backdating
# an import, say); this only stops the template from suggesting it.
def build_frontmatter(title:, tags:, type:, pinned: nil)
  lines = ['---']
  lines << "title: #{title}"
  lines << "tags: #{tags}"
  lines << "type: #{type}" if type
  # Only shown when the post already carries it: a key that appears on
  # every new post would suggest pinning is part of writing one, when it
  # is a decision about an existing post.
  lines << "pinned: #{pinned}" unless pinned.nil?
  lines << '---'
  "#{lines.join("\n")}\n\n"
end

# --- Mastodon comments -----------------------------------------------------

# Sends the "reply here to comment" announcement (a Mastodon toot or a
# Bluesky post, whichever network the site configured -- see
# SiteConfig.comment_network) and returns the post fields to store, or
# nil (e.g. when SITE_BASE_URL or the network's token isn't set). Never
# raises: a failed announcement must not block publishing the post
# itself. Composition and dispatch live in lib/publishing.rb, shared
# with the scheduled-publish cron.
TOOT_RECENCY_WINDOW = 24 * 60 * 60 # seconds; posts dated further from "now" than this (e.g. backfilled from an old thread) don't get an auto announcement

def announce_post(post, year:, date:, force: false)
  if SITE_BASE_URL.to_s.empty?
    warn t('cli.base_url_missing_toot')
    return nil
  end

  if !force && (date - Time.now).abs > TOOT_RECENCY_WINDOW
    warn t('cli.backdated_no_toot')
    return nil
  end

  Tui.spinner(t('cli.announcing')) { Publishing.announce(post, year: year) }
end

# --- commands ------------------------------------------------------------

def cmd_add
  # created_at == date is what marks a draft's date as auto-suggested
  # (see publish_draft, and unpublish, which restores that equality on
  # purpose). With no date: line typed, created_at is therefore written
  # from the very same Time object as date below. When the author *does*
  # type one, created_at keeps this pre-editor creation timestamp, the
  # two fields differ, and publish_draft leaves the typed date alone.
  # (Writing both from one object matters: this value is truncated to
  # minutes and taken before the editor opens, so comparing it against a
  # post-editor, seconds-precise date could never come out equal -- for a
  # long time every draft published as if hand-dated because of that.)
  suggested = Time.parse(Time.now.strftime('%Y-%m-%d %H:%M'))
  template = build_frontmatter(title: '', tags: '', type: '') +
             "First paragraph's text.\n"
  raw = edit_in_editor(template, FRONTMATTER_HINT)

  # Editor closed without saving (or saved untouched) leaves the template
  # byte-identical -- treat that as "nothing happened": no post, no toot,
  # no rebuild question. (This is how an accidental empty-template post once
  # made it all the way to a published Mastodon toot.)
  if raw == template
    discard_editor_buffer
    warn t('cli.template_unchanged')
    warn ''
    return
  end

  meta, body = MarkdownParser.parse_frontmatter(raw)
  abort_on_double_frontmatter(body)
  abort_on_unknown_frontmatter(meta)

  if body.strip.empty?
    discard_editor_buffer
    warn t('cli.empty_content')
    warn ''
    return
  end

  date = meta['date'].to_s.empty? ? Time.now : Time.parse(meta['date'])
  title = meta['title'].to_s.empty? ? nil : meta['title']
  tags = meta['tags'].to_s.split(',').map(&:strip).reject(&:empty?)
  type = meta['type'].to_s.empty? ? nil : meta['type']

  blocks, media_files, missing = MarkdownParser.parse_body(body, nil, incoming_dir: INCOMING_DIR)
  wait_for_missing_images(missing)
  heic_consumed = convert_heic_attachments(blocks, media_files)
  check_attachment_sizes(media_files)
  fill_image_dimensions(blocks, media_files)

  slug_source = title || (blocks.find { |b| b['type'] == 'text' } || {})['text']
  slug = Slug.slugify(slug_source.to_s.split(/\s+/).first(8).join(' '))
  slug = "post-#{date.to_i}" if slug.empty?

  # An existing <year>/<slug>.json would be replaced wholesale by
  # PostWriter.write -- same path, so the build's duplicate check never
  # sees a second file. A new post whose title happens to match an old
  # one gets a numeric suffix instead of eating it (and with it the
  # media directory, which is keyed by year/slug too).
  #
  # The media directory counts as taken too, even with no post owning it:
  # a leftover media.nosync/<year>/<slug>/ (a post deleted by hand, or an
  # earlier save that died mid-way) would otherwise take this post's
  # photos -- PostWriter skips a copy whose destination name already
  # exists, while the source in incoming/ is cleaned up regardless, so the
  # new photo ended up nowhere and the post showed the old one.
  base_slug = slug
  serial = 2
  while File.exist?(File.join(CONTENT_DIR, date.year.to_s, "#{slug}.json")) ||
        Dir.exist?(File.join(MEDIA_DIR, date.year.to_s, slug))
    slug = "#{base_slug}-#{serial}"
    serial += 1
  end

  # `add` never publishes directly any more: it always creates a draft only
  # visible through a hidden preview address, and publishing is a separate,
  # deliberate decision (draft_decision_loop). The Mastodon toot is therefore
  # only sent alongside that decision -- it used to go out immediately at
  # creation, which doesn't make sense for drafts.
  post = {
    'slug' => slug,
    'title' => title,
    'date' => date.iso8601,
    'created_at' => (meta['date'].to_s.empty? ? date : suggested).iso8601,
    'state' => DRAFT,
    'draft_token' => SecureRandom.hex(8),
    'tags' => tags,
    'content' => blocks,
    'source' => { 'platform' => 'manual' }
  }
  post['type'] = type if type
  post['pinned'] = true if truthy_frontmatter?(meta['pinned'])

  path = PostWriter.write(post, media_files: media_files)
  discard_editor_buffer
  cleanup_incoming(media_files, heic_consumed)
  puts t('cli.wrote_draft', path: path)

  final_slug = File.basename(path, '.json')
  unless rebuild_and_deploy(t('cli.generating_preview'))
    warn t('cli.draft_saved_preview_pending', slug: final_slug)
    warn ''
    return
  end

  draft_decision_loop(final_slug)
end

# After every draft change, it builds and deploys without asking -- the
# preview has to be on the live site, or it couldn't be opened from an iPad,
# which is the whole point.
def draft_decision_loop(slug)
  if SITE_BASE_URL.to_s.empty?
    warn t('cli.base_url_missing_preview')
    warn ''
    return
  end

  loop do
    path = find_post_path(slug)
    return unless path

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    return unless draft?(post)

    # No extra `puts` before "Preview:" -- rebuild_and_deploy (called right
    # before this, whether from cmd_add or the 'e' branch below) already
    # ended with a blank line after "Done:", so another one would double up.
    puts Tui.paint(t('cli.preview_label', url: draft_url(post)), :cyan)
    if Tui.interactive? && (qr = QrCode.render(draft_url(post)))
      puts
      puts qr
      puts Tui.paint(t('cli.qr_hint'), :dim)
    end
    puts
    slot = next_publish_slot(slug)
    prompt = slot ? t('cli.what_next_prompt_slot', slot: slot.strftime(t('date_time_format'))) : t('cli.what_next_prompt')
    case Tui.key_choice(prompt)
    when 'p' then return publish_draft(slug)
    when 'e' then edit_post(slug)
    when 's'
      puts
      return if prompt_and_schedule(path, post)
    when 'd', ''
      puts
      puts t('cli.left_as_draft', slug: slug)
      puts
      return
    when 'x'
      next unless delete_post(slug)

      rebuild_and_deploy(t('cli.updating_preview'))
      return
    else puts t('cli.unknown_choice_pde')
    end
  end
end

# Asks for a publish date and schedules the draft under it. Shared by the
# [s] dialog choice and the standalone `schedule` command -- both ask the
# same question, and since the frontmatter no longer offers a date field,
# asking is the only way either of them can get one. Returns true when
# scheduled, false on cancel/invalid input: the dialog uses that to come
# around again, the standalone command just ends. The preview is rebuilt
# because the entered date becomes the post's date and shows on the draft
# page.
#
# No leading blank line here: the two callers arrive with different things
# above them. pick_from_list already ends with one, while the dialog's
# key_choice leaves the cursor right under the echoed keypress -- so that
# branch prints its own.
# Times already claimed by scheduled drafts, so the next offer skips
# them -- that is what turns a set of slots into a queue.
def scheduled_entries(except_slug: nil)
  Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
    post = JSON.parse(File.read(file, encoding: 'utf-8')) rescue next
    next unless post.is_a?(Hash) && post['scheduled'] && post['slug'] != except_slug

    time = Time.parse(post['date']) rescue next
    [time, post['slug']]
  end
end

# The configured? check comes FIRST and the archive is walked at most
# once: this runs on every redraw of the draft dialog, and on a
# 3000-post archive each pass costs a third of a second -- a site with no
# slots configured was paying it for nothing.
def next_publish_slot(slug = nil, entries = nil)
  return nil unless PublishSlots.configured?

  PublishSlots.next_free(taken: (entries || scheduled_entries(except_slug: slug)).map(&:first))
end

# The occupied slots the offer had to walk past, in order, with the post
# sitting in each.
#
# Without this the offer states a result and hides its reasoning: a site
# with Saturday morning in its slots, whose Saturday is already taken, is
# offered Sunday evening and reads as a feature that skips Saturdays. That
# is the worst failure mode available -- correct behaviour that looks
# broken -- and it cost a real "scheduling seems broken" report against a
# queue that was working exactly as designed.
#
# Walks the calendar the same way next_free does (each step asks for the
# slot after the previous one), so the two can never disagree about what
# the slots are.
def slots_passed_over(slot, entries)
  return [] if slot.nil? || entries.nil? || entries.empty?

  by_minute = entries.each_with_object({}) { |(time, slug), acc| acc[time.to_i / 60] = slug }
  passed = []
  cursor = Time.now
  while (candidate = PublishSlots.next_free(taken: [], from: cursor)) && candidate < slot
    slug = by_minute[candidate.to_i / 60]
    passed << [candidate, slug] if slug
    cursor = candidate
  end
  passed
end

# Position in the queue, for the confirmation line: which scheduled post
# (if any) goes out immediately before this one.
def queue_position(time, entries)
  earlier = entries.select { |entry| entry.first <= time }.sort_by(&:first)
  return nil if earlier.empty?

  { count: earlier.size + 1, slug: earlier.last[1], date: earlier.last[0] }
end

def prompt_and_schedule(path, post)
  # Read once when slots are configured (the offer needs it); a site
  # without slots pays nothing here and reads the archive only after it
  # has actually scheduled something, for the queue line.
  entries = PublishSlots.configured? ? scheduled_entries(except_slug: post['slug']) : nil
  slot = next_publish_slot(post['slug'], entries)
  if slot
    # The offer changes what an empty line means (it used to cancel), so
    # the prompt spells out both the accepting key and the cancel word
    # rather than letting the change happen silently.
    puts t('cli.schedule_slot_offer', slot: slot.strftime(t('date_time_format')))
    # Why this slot and not an earlier one. Said before the prompt, not in
    # the confirmation afterwards, because that is when the author is
    # deciding whether the offer looks right.
    passed = slots_passed_over(slot, entries)
    if passed.any?
      # One slot per line, like the queue block in the properties dialog:
      # joined into a sentence, two of them already ran past the width of a
      # terminal and read as prose to be skimmed rather than a list to be
      # checked against.
      puts t('cli.schedule_slots_taken')
      passed.each { |time, slug| puts "     #{time.strftime(t('date_time_format'))} → '#{slug}'" }
      puts
    end
    puts t('cli.schedule_slot_keys', cancel_word: t('cli.cancel_word'))
    print '> '
  else
    print t('cli.schedule_date_prompt')
  end
  raw = $stdin.gets
  # EOF is not Enter. With an offer on screen an empty line accepts, and
  # Ctrl-D (or a piped run whose input ran out) would otherwise schedule,
  # rebuild and deploy a post nobody confirmed.
  return false if raw.nil?

  input = raw.strip
  return false if input.empty? && slot.nil?
  return false if input.downcase == t('cli.cancel_word')

  date = if input.empty?
           slot
         else
           begin
             Time.parse(input)
           rescue ArgumentError
             nil
           end
         end
  if date.nil?
    puts t('cli.schedule_date_invalid')
    return false
  end
  if date <= Time.now
    puts t('cli.schedule_date_not_future')
    return false
  end

  updated = post.merge('date' => date.iso8601, 'scheduled' => true)

  # A date in another year moves the post, JSON and media together. Left
  # in the old year's folder the two disagree: the build derives both the
  # URL and the media lookup from the date, so the draft preview loses
  # every image -- and publishing it later hits the same missing media
  # year that used to abort the cron.
  new_year = date.year.to_s
  new_path = File.join(CONTENT_DIR, new_year, "#{post['slug']}.json")
  if File.expand_path(new_path) != File.expand_path(path)
    abort t('cli.post_already_exists', slug: post['slug'], path: new_path) if File.exist?(new_path)

    FileUtils.mkdir_p(File.dirname(new_path))
    Publishing.relocate_media(post['slug'], File.basename(File.dirname(path)), new_year)
    AtomicWrite.write_json(new_path, updated)
    File.delete(path)
  else
    AtomicWrite.write_json(new_path, updated)
  end
  rebuild_and_deploy(t('cli.updating_preview'))
  puts Tui.paint(t('cli.scheduled_label', slug: post['slug'], date: date.strftime(t('date_time_format'))), :green)
  position = queue_position(date, entries || scheduled_entries(except_slug: post['slug']))
  if position
    puts t('cli.schedule_queue_position', count: position[:count], slug: position[:slug],
                                          date: position[:date].strftime(t('date_time_format')))
  end
  puts t('cli.schedule_cron_note')
  puts
  true
end

def announce_on_publish(post, year, date)
  force = false
  if (date - Time.now).abs > TOOT_RECENCY_WINDOW
    answer = Tui.key_choice(t('cli.date_outside_window_prompt', date: date.strftime(t('date_format'))))
    return nil unless answer.start_with?(t('cli.confirm_yes_char'))

    force = true
  end

  announce_post(post, year: year, date: date, force: force)
end

def publish_draft(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  unless draft?(post)
    puts t('cli.already_published', slug: slug, url: published_url(slug, Time.parse(post['date']).year))
    puts
    return
  end

  # If the date is still whatever the template suggested at creation time,
  # the author never touched it, so it publishes with the current time.
  # If they overwrote it, that's a deliberate decision left alone -- so
  # publishing into the past works too.
  #
  # A date in the FUTURE is neither, and never a hand-picked publication
  # date: `schedule` is the only thing that sets one, as an instruction to
  # the cron. Publishing by hand overtakes that plan, so it means now --
  # otherwise the post lands on the site dated days ahead, and the CLI
  # calls it "backdated" while doing it. Covers both the still-scheduled
  # draft and one whose schedule was just cancelled with [n], which keeps
  # the date the schedule gave it.
  future = Time.parse(post['date']) > Time.now
  untouched = future || (post['created_at'] && post['date'] == post['created_at'])
  date = untouched ? Time.now : Time.parse(post['date'])
  puts(untouched ? t('cli.publish_date_now', date: date.strftime(t('date_time_format')))
                 : t('cli.publish_date_kept', date: date.strftime(t('date_time_format'))))

  new_year = date.year.to_s
  new_path, updated = Publishing.publish(path, post, date: date)

  fields = announce_on_publish(updated, new_year, date)
  if fields
    updated.merge!(fields)
    AtomicWrite.write_json(new_path, updated)
  end

  puts t('cli.published_label', path: new_path)
  rebuild_and_deploy(t('cli.publishing')) || return
  # No extra `puts` before "Done:" -- rebuild_and_deploy ended with a blank
  # line after its own "Done: uploaded...", same doubling as
  # draft_decision_loop above.
  puts Tui.paint(t('cli.done_label', url: published_url(slug, new_year)), :green)
  puts t('cli.backdated_note') unless untouched
  puts
end

# The answer sticks for the rest of the run. publish/edit/delete resolve
# the slug again at every internal step (draft_decision_loop, publish_draft,
# delete_post each take a slug, not a path), so one command asked the same
# "which year?" question two or three times -- and answering differently
# silently retargeted it mid-flow, up to and including trashing the post
# the author had not picked. Re-resolved automatically when the chosen file
# moves (a year-changing edit) or goes away (a delete), so a stale answer
# can't outlive its post.
RESOLVED_PATHS = {}

def find_post_path(slug)
  chosen = RESOLVED_PATHS[slug]
  return chosen if chosen && File.exist?(chosen)

  matches = Dir.glob(File.join(CONTENT_DIR, '*', "#{slug}.json")).sort
  return matches.first if matches.size <= 1

  RESOLVED_PATHS[slug] = pick_among_years(slug, matches)
end

# The same slug can legitimately live in several years (backdating makes
# that easy), and glob order used to decide which post edit/delete/toot
# acted on -- always the oldest, silently. Never guess between them: show
# every match and make the author choose. A number picks that post;
# anything else cancels, same contract as the other pickers.
def pick_among_years(slug, paths)
  # An unreadable file is dropped rather than shown: post_summary has
  # already named it, and a row and its path must stay index-aligned.
  readable = paths.filter_map { |f| (summary = post_summary(f)) && [f, summary] }
  abort t('cli.post_not_found', slug: slug) if readable.empty?

  paths = readable.map(&:first)
  rows = readable.map { |(_, summary)| summary_row(summary) }
  puts t('cli.ambiguous_slug', slug: slug, count: paths.size)

  if Tui.interactive?
    choice = Tui.menu(rows, hint: t('cli.menu_hint'))
    abort t('cli.cancelled_empty') if choice.nil?
    puts
    return paths[choice]
  end

  rows.each_with_index { |row, i| puts "#{i + 1}) #{row}" }
  puts
  print t('cli.enter_number')
  input = $stdin.gets&.strip.to_s
  puts
  # "".to_i and "abc".to_i are both 0 and [-1] is the LAST element -- only
  # a plain in-range number counts, anything else cancels (see the import
  # menu incident this comment style comes from).
  abort t('cli.cancelled_empty') unless input =~ /\A\d+\z/ && (1..paths.size).cover?(input.to_i)
  paths[input.to_i - 1]
end

# A standalone (re-)send of the comment toot -- works for any published
# slug, not just at the moment of publish. Typically for imported posts
# without a toot, or when the original one was lost/deleted. Rejects a
# draft, since the toot carries published_url and would point at a
# nonexistent page before publishing. An existing mastodon_url is never
# overwritten -- there's no reason for a second toot on the same post (see
# unpublish, where the old one can be deleted).
def cmd_toot(slug)
  if SiteConfig.comment_network == :bluesky
    puts t('cli.use_bluesky_command')
    puts
    return
  end

  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  if draft?(post)
    warn t('cli.still_draft_toot', slug: slug)
    warn ''
    return
  end

  if post['mastodon_url']
    puts t('cli.already_has_toot', url: post['mastodon_url'])
    puts
    return
  end

  year = File.basename(File.dirname(path))
  date = Time.parse(post['date'])
  fields = announce_on_publish(post, year, date)
  unless fields
    warn t('cli.toot_failed')
    warn ''
    return
  end

  AtomicWrite.write_json(path, post.merge(fields))
  puts t('cli.tooted', url: fields['mastodon_url'])
  puts
end

# The Bluesky counterpart of cmd_toot: a standalone (re-)send of the
# announcement, for sites whose comment network is Bluesky. Same rules --
# published posts only, an existing announcement is never overwritten.
def cmd_bluesky(slug)
  unless SiteConfig.comment_network == :bluesky
    puts t('cli.use_toot_command')
    puts
    return
  end

  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  if draft?(post)
    warn t('cli.still_draft_toot', slug: slug)
    warn ''
    return
  end

  if post['bluesky_url']
    puts t('cli.already_has_bluesky', url: post['bluesky_url'])
    puts
    return
  end

  year = File.basename(File.dirname(path))
  date = Time.parse(post['date'])
  fields = announce_on_publish(post, year, date)
  unless fields
    warn t('cli.bluesky_failed')
    warn ''
    return
  end

  AtomicWrite.write_json(path, post.merge(fields))
  puts t('cli.bluesky_posted', url: fields['bluesky_url'])
  puts
end

# `publish` no longer publishes directly -- it opens the same preview/decision
# loop as `add`/`edit`, so before a draft is actually sent out, it can still
# be looked at one more time or sent back to editing. The actual publishing
# only happens via the [p] choice in draft_decision_loop, which calls publish_draft.
def cmd_publish(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  unless draft?(post)
    puts t('cli.already_published', slug: slug, url: published_url(slug, Time.parse(post['date']).year))
    puts
    return
  end

  draft_decision_loop(slug)
end

# Marks a draft for automatic publishing by cron
# (scripts/publish-scheduled.sh) once its date arrives -- or cancels the
# mark when run on an already scheduled post (a toggle). Asks for the
# date, exactly as the [s] dialog choice does: it used to require one set
# to the future via `edit` beforehand, which stopped being a usable route
# when the frontmatter template dropped its date field.
def cmd_schedule(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  unless draft?(post)
    puts t('cli.schedule_only_drafts', slug: slug)
    puts
    return
  end

  if post['scheduled']
    unschedule_post(path, post, slug)
    return
  end

  prompt_and_schedule(path, post)
end

# Shared by the CLI toggle above and the [n] action in the properties
# dialog -- the wizard lost the standalone `schedule` menu item, so
# without this the dialog could plan a post but never change its mind.
def unschedule_post(path, post, slug)
  updated = post.dup
  updated.delete('scheduled')
  AtomicWrite.write_json(path, updated)
  puts t('cli.unscheduled_label', slug: slug)
  puts
end

# The reverse of publish_draft: moves a published post back to draft. Also
# deletes its associated Mastodon toot (by design -- otherwise a link to a
# nonexistent page would hang around the web until the post is republished),
# and resets created_at to the current date, so the post behaves as
# "untouched" -- the next publish_draft therefore gives it a new date (now),
# same as a freshly-created draft, instead of the old one it first went out
# under.
def cmd_unpublish(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  if draft?(post)
    puts t('cli.already_draft', slug: slug, url: draft_url(post))
    puts
    return
  end

  puts "#{post['date']}  #{post['title']}"
  print t('cli.confirm_unpublish', slug: slug)
  confirmation = $stdin.gets&.strip
  unless confirmation == slug
    puts t('cli.cancelled')
    puts
    return
  end

  if post['mastodon_url']
    puts t('cli.deleting_toot', url: post['mastodon_url'])
    warn t('cli.delete_toot_failed') unless MastodonPoster.delete(post['mastodon_url'])
  end
  if post['bluesky_uri']
    puts t('cli.deleting_bluesky', url: post['bluesky_url'])
    warn t('cli.delete_bluesky_failed') unless BlueskyPoster.delete(post['bluesky_uri'])
  end

  updated = post.merge('state' => DRAFT, 'draft_token' => SecureRandom.hex(8), 'created_at' => post['date'],
                       # The address this post just vacated. If it publishes again under a
                       # different slug (renamed while a draft), Publishing.publish turns
                       # this into a former_slugs redirect -- otherwise the old public URL
                       # would 404 with no trace, exactly what renames promise not to do.
                       # Publishing back under the same address just consumes the marker.
                       'unpublished_from' => "#{File.basename(File.dirname(path))}/#{slug}")
  updated.delete('mastodon_url')
  updated.delete('bluesky_url')
  updated.delete('bluesky_uri')
  AtomicWrite.write_json(path, updated)
  puts t('cli.reverted_to_draft', path: path)

  final_slug = File.basename(path, '.json')
  unless rebuild_and_deploy(t('cli.updating_preview'))
    warn t('cli.draft_saved_preview_pending', slug: final_slug)
    warn ''
    return
  end

  draft_decision_loop(final_slug)
end

# --- properties and actions ------------------------------------------
#
# One place that answers "what is the state of this post, and what can be
# done TO it" -- as opposed to editing its text. Attributes (type, tags,
# the pin) are shown but deliberately not edited here: they live in the
# frontmatter of `edit`, prefilled with their current values, one
# keystroke away from the text they describe. The actions are the guarded
# operations that each used to be its own wizard menu item -- gathering
# them under the post is what let the menu shrink to activities.

def props_line(key, value)
  puts format('  %-12s %s', t("cli.props_label_#{key}"), value) unless value.to_s.empty?
end

def props_title(post)
  post['title'] || post['content'].find { |b| b['type'] == 'text' }&.fetch('text', '')&.slice(0, 60) || post['slug']
end

def cmd_props(slug)
  network = SiteConfig.comment_network
  network_label = { mastodon: 'Mastodon', bluesky: 'Bluesky' }[network]

  loop do
    path = find_post_path(slug)
    abort t('cli.post_not_found', slug: slug) unless path

    post = JSON.parse(File.read(path, encoding: 'utf-8'))
    year = File.basename(File.dirname(path))

    puts
    puts "  #{Tui.paint(props_title(post), :bold)}"
    puts "  #{draft?(post) ? t('cli.props_draft_banner') : "posts/#{year}/#{post['slug']}/"}"
    puts
    if draft?(post)
      # No created/date line for a plain draft, on purpose: a draft has no
      # time -- its date is set by publishing or scheduling, and showing
      # anything earlier would suggest it means something.
      props_line('scheduled', post['scheduled'] ? Time.parse(post['date']).getlocal.strftime(t('date_time_format')) : nil)
    else
      props_line('state', t('cli.props_state_published', date: Time.parse(post['date']).getlocal.strftime(t('date_time_format'))))
    end
    props_line('type', ContentType.dominant(post))
    props_line('tags', (post['tags'] || []).join(', '))
    props_line('pinned', truthy_frontmatter?(post['pinned']) ? t('cli.props_pinned_yes') : nil)
    announced = post['mastodon_url'] || post['bluesky_url']
    props_line('announced', if announced then announced
                            elsif draft?(post) then t('cli.props_announces_on_publish')
                            else t('cli.props_not_announced')
                            end)
    # The whole queue, after the property list rather than inside it: it is
    # a block, not a field, and until now the only way to see what goes out
    # when was opening every draft in turn -- which is also how an offered
    # slot could look like the wrong one.
    if post['scheduled'] && (queue = scheduled_entries.sort_by(&:first)).size > 1
      puts
      puts Tui.paint(t('cli.props_queue_heading', count: queue.size), :dim)
      queue.each do |time, queued_slug|
        mark = queued_slug == post['slug'] ? '→' : ' '
        puts "  #{mark} #{time.getlocal.strftime(t('date_time_format'))}  #{queued_slug}"
      end
    end

    puts
    puts Tui.paint(t('cli.props_attributes_hint'), :dim)
    puts

    if draft?(post)
      case Tui.key_choice(t(post['scheduled'] ? 'cli.props_actions_scheduled' : 'cli.props_actions_draft'))
      when 'p' then return publish_draft(slug)
      when 's'
        puts
        prompt_and_schedule(path, post)
      when 'n'
        unless post['scheduled']
          puts t('cli.props_unknown_draft')
          next
        end
        unschedule_post(path, post, slug)
      when 'r' then slug = rename_post(path, post)
      when 'x'
        # Same shape as the [x] branch of draft_decision_loop: a deleted
        # draft only changes the preview, so the rebuild needs no asking.
        next unless delete_post(slug)

        rebuild_and_deploy(t('cli.updating_preview'))
        return
      when '' then return
      else puts t(post['scheduled'] ? 'cli.props_unknown_scheduled' : 'cli.props_unknown_draft')
      end
    else
      case Tui.key_choice(network_label ? t('cli.props_actions_published', network: network_label) : t('cli.props_actions_published_plain'))
      when 'u'
        cmd_unpublish(slug)
        # A cancelled confirmation leaves the post published -- come back
        # to the dialog rather than ending it. After a real unpublish the
        # draft decision loop has already offered everything there is.
        p2 = find_post_path(slug)
        return if p2.nil? || draft?(JSON.parse(File.read(p2, encoding: 'utf-8')))
      when 't'
        unless network_label
          puts t('cli.props_unknown_published_plain')
          next
        end
        puts
        network == :bluesky ? cmd_bluesky(slug) : cmd_toot(slug)
      when 'c' then toggle_pin(path, post, slug)
      when 'r' then slug = rename_post(path, post)
      when 'x'
        cmd_delete(slug)
        # Cancelled (the post still exists) -> stay in the dialog.
        return unless find_post_path(slug)
      when '' then return
      else puts t(network_label ? 'cli.props_unknown_published' : 'cli.props_unknown_published_plain')
      end
    end
  end
end

# The pin is the one boolean attribute, and flipping a boolean through a
# whole editor session was exactly the friction the dialog exists to
# remove -- so after its first real use it graduated to an action. The
# header still carries `pinned:` and still works; this is the short way.
# Unpinning deletes the key rather than writing false, so an unpinned
# post looks like every other unpinned post.
def toggle_pin(path, post, slug)
  if truthy_frontmatter?(post['pinned'])
    updated = post.dup
    updated.delete('pinned')
    AtomicWrite.write_json(path, updated)
    puts Tui.paint(t('cli.pin_off', slug: slug), :green)
  else
    # Only one pin ever shows (the build takes the newest and warns), so
    # a second one deserves a heads-up naming the first -- not a refusal:
    # pinning the newer post is almost always the intent, and unpinning
    # the other one is one [c] away.
    other = load_posts_summary.find { |p| p[:pinned] && p[:slug] != slug }
    AtomicWrite.write_json(path, post.merge('pinned' => true))
    puts Tui.paint(t('cli.pin_on', slug: slug), :green)
    puts t('cli.pin_other', slug: other[:slug]) if other
  end
  maybe_rebuild
end

# Renaming is an ACTION with a guard, not an attribute: a published slug
# is a public address, so the old one has to keep answering. The post
# records every address it ever had (former_slugs, as "year/slug" frozen
# at rename time), and the build turns each into a one-page redirect stub
# -- the cost of a rename is one extra page, not a broken link. A draft
# has no public address yet, so its rename records nothing; only its
# preview URL changes, which is why that path redeploys the preview.
#
# Returns the slug the caller should continue with: the new one after a
# rename, the old one after any kind of cancel.
def rename_post(path, post)
  old_slug = post['slug']
  year = File.basename(File.dirname(path))

  puts
  print t('cli.rename_prompt')
  input = $stdin.gets&.strip.to_s
  if input.empty?
    puts t('cli.cancelled')
    return old_slug
  end

  new_slug = Slug.slugify(input)
  if new_slug.empty?
    puts t('cli.rename_unusable', input: input)
    return old_slug
  end
  if new_slug == old_slug
    puts t('cli.rename_same')
    return old_slug
  end

  # Same guard as edit and publish: the address and the media directory
  # are both keyed by year/slug, and neither may land on another post's.
  new_path = File.join(CONTENT_DIR, year, "#{new_slug}.json")
  new_media_dir = File.join(MEDIA_DIR, year, new_slug)
  if File.exist?(new_path) || Dir.exist?(new_media_dir)
    # Not the shared post_already_exists text: that one says "continuing
    # would overwrite it -- resolve manually", and a refused rename
    # neither continues nor needs resolving. Picking another slug does.
    puts t('cli.rename_taken', slug: new_slug)
    return old_slug
  end

  if draft?(post)
    puts t('cli.rename_confirm_draft', old: old_slug, new: new_slug)
  else
    puts t('cli.rename_confirm', old_url: published_url(old_slug, year), new_url: published_url(new_slug, year))
  end
  unless Tui.key_choice(t('cli.rename_go')) == t('cli.confirm_yes_char')
    puts t('cli.cancelled')
    return old_slug
  end

  updated = post.merge('slug' => new_slug)
  unless draft?(post)
    former = Array(post['former_slugs']).map(&:to_s) + ["#{year}/#{old_slug}"]
    # A rename back to an earlier slug must not leave that address
    # redirecting to itself.
    updated['former_slugs'] = (former.uniq - ["#{year}/#{new_slug}"])
  end

  # Media first, replacement JSON second, old JSON last -- the same order
  # edit_post uses, for the same reason: no step may remove the only copy
  # of anything before its replacement exists.
  PostWriter.move_media_dir(File.join(MEDIA_DIR, year, old_slug), new_media_dir)
  AtomicWrite.write_json(new_path, updated)
  File.delete(path)

  puts Tui.paint(t('cli.renamed_label', slug: new_slug), :green)
  if draft?(post)
    rebuild_and_deploy(t('cli.updating_preview'))
  else
    maybe_rebuild
  end
  new_slug
end

def cmd_edit(slug)
  edit_post(slug)
  path = find_post_path(slug)
  return unless path

  draft_decision_loop(slug) if draft?(JSON.parse(File.read(path, encoding: 'utf-8')))
end

def edit_post(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  # Kept to compare against just before the save: an editor session is
  # open-ended, and the scheduled-publish cron runs every 15 minutes. The
  # post below was read BEFORE the editor opened, so writing it back after
  # the cron published the post would revert it to a scheduled draft, drop
  # the announcement URL it just stored, and let the next cron run publish
  # -- and announce -- the same post a second time.
  original_raw = File.read(path, encoding: 'utf-8')
  post = JSON.parse(original_raw)
  year = File.basename(File.dirname(path))
  media_dir = File.join(MEDIA_DIR, year, slug)

  date = Time.parse(post['date'])
  frontmatter = build_frontmatter(
    title: post['title'].to_s,
    tags: (post['tags'] || []).join(', '),
    type: post['type'],
    # Shown with its current value so the author can see the state, not
    # just set it -- and only for a published post: pinning a draft that
    # nothing links to yet would have nowhere to show.
    # A draft is offered the key only if it already carries a pin --
    # otherwise pinning something nobody can see yet has nowhere to show.
    # Offering it when set matters: without the line in the header, saving
    # would drop a pin the post had (unpublish keeps it).
    pinned: (draft?(post) && !truthy_frontmatter?(post['pinned'])) ? nil : truthy_frontmatter?(post['pinned'] || 'false')
  )
  body = MarkdownWriter.blocks_to_markdown(post['content'], media_dir)

  raw = edit_in_editor(frontmatter + body, FRONTMATTER_HINT)

  # Same no-op guard as cmd_add: editor closed without saving (or saved
  # untouched) means nothing to do -- skip the save and the rebuild question.
  if raw == frontmatter + body
    discard_editor_buffer
    puts t('cli.no_changes')
    puts
    return
  end

  meta, new_body = MarkdownParser.parse_frontmatter(raw)
  abort_on_double_frontmatter(new_body)
  abort_on_unknown_frontmatter(meta)

  new_date = meta['date'].to_s.empty? ? date : Time.parse(meta['date'])
  new_title = meta['title'].to_s.empty? ? nil : meta['title']
  new_tags = meta['tags'].to_s.split(',').map(&:strip).reject(&:empty?)
  new_type = meta['type'].to_s.empty? ? nil : meta['type']

  blocks, media_files, missing = MarkdownParser.parse_body(new_body, media_dir, incoming_dir: INCOMING_DIR)
  wait_for_missing_images(missing)
  heic_consumed = convert_heic_attachments(blocks, media_files)
  check_attachment_sizes(media_files)
  fill_image_dimensions(blocks, media_files, media_dir)

  # Checks for a drop in every block type, not just images: markdown can't
  # express a link card or a foreign embed (Instagram), so saving would
  # otherwise silently delete them.
  counts = lambda { |list| list.each_with_object(Hash.new(0)) { |b, h| h[b['type']] += 1 } }
  before = counts.call(post['content'])
  after = counts.call(blocks)
  lost = before.filter_map { |type, n| [type, n - after[type]] if n > after[type] }
  if lost.any?
    puts
    puts t('cli.content_loss_warning', summary: lost.map { |type, n| "#{n}x #{type}" }.join(', '))
    # The word is compared against the locale's own confirm_word -- the
    # Czech prompt says to type "ano", so comparing against a hardcoded
    # 'yes' aborted exactly the users who followed the instruction.
    print t('cli.confirm_continue_yes', word: t('cli.confirm_word'))
    abort t('cli.cancelled_nothing_saved') unless $stdin.gets&.strip&.downcase == t('cli.confirm_word')
  end

  new_year = new_date.year.to_s
  new_dir = File.join(CONTENT_DIR, new_year)
  FileUtils.mkdir_p(new_dir)
  new_path = File.join(new_dir, "#{slug}.json")
  new_media_dir = File.join(MEDIA_DIR, new_year, slug)

  # Same guard as Publishing.publish: a date edit that moves the post
  # into a year where another post already owns this slug must not
  # overwrite that post's JSON (and displace its media directory).
  if new_dir != File.dirname(path) && File.exist?(new_path)
    abort t('cli.post_already_exists', slug: slug, path: new_path)
  end

  updated = {
    'slug' => slug,
    'title' => new_title,
    'date' => new_date.iso8601,
    'state' => post['state'] || 'published',
    'tags' => new_tags,
    'content' => blocks,
    'source' => post['source'] || { 'platform' => 'manual' }
  }
  updated['type'] = new_type if new_type
  updated['pinned'] = true if truthy_frontmatter?(meta['pinned'])
  # Same survival rule as the announcement URLs below: former_slugs is not
  # representable in the frontmatter, so a save that forgot to carry it
  # over would silently break every redirect the post has accumulated --
  # and dropping unpublished_from would lose the redirect an unpublished
  # post's old address is still owed.
  updated['former_slugs'] = post['former_slugs'] if post['former_slugs']
  updated['unpublished_from'] = post['unpublished_from'] if post['unpublished_from']
  updated['mastodon_url'] = post['mastodon_url'] if post['mastodon_url']
  updated['bluesky_url'] = post['bluesky_url'] if post['bluesky_url']
  updated['bluesky_uri'] = post['bluesky_uri'] if post['bluesky_uri']
  updated['created_at'] = post['created_at'] if post['created_at']
  updated['draft_token'] = post['draft_token'] if post['draft_token']
  updated['scheduled'] = true if post['scheduled']

  # Before ANY of the moving, copying and pruning below: if the file changed
  # under the editor -- the scheduled-publish cron runs every 15 minutes --
  # this save would overwrite whatever changed it. Refusing is the only safe
  # answer; the two versions can't be merged without guessing which state
  # and which mastodon_url is the real one. It has to happen here rather
  # than next to the write, because by then media has already been copied
  # and unreferenced files deleted, and "nothing was saved" would be a lie.
  # The text isn't lost either way: the editor buffer holds it and the
  # notice armed at edit time says where.
  if !File.exist?(path) || File.read(path, encoding: 'utf-8') != original_raw
    abort t('cli.post_changed_while_editing', slug: slug)
  end

  # Media move first, replacement JSON second, old JSON last. The old
  # order deleted the post's only file and *then* moved its media -- so a
  # date edit into a year with no media.nosync/<year>/ yet (the mv raises
  # ENOENT there) destroyed the post: nothing in trash, nothing in the
  # editor's temp file, nothing to restore.
  Publishing.relocate_media(slug, year, new_year) if new_dir != File.dirname(path)

  FileUtils.mkdir_p(new_media_dir) if media_files.any?
  media_files.each do |src, filename|
    FileUtils.cp(src, File.join(new_media_dir, filename))
  end

  # Not just images: a video's file lives in the same directory, and some
  # imported blocks additionally carry a poster for it. If those weren't
  # counted here, cleanup would delete them after editing and the page
  # would be left with a link to a nonexistent file.
  #
  # The poster is also taken from the ORIGINAL post: it can't be written in
  # markdown, so the round-trip can't carry it over, and it would always
  # come out orphaned based on the new blocks alone. This affects 52
  # imported videos, and the author can't remove that file, so cleanup must
  # not remove it on their behalf.
  keep = (blocks.flat_map { |b| [b.dig('media', 0, 'url'), b.dig('poster', 0, 'url')] } +
          post['content'].map { |b| b.dig('poster', 0, 'url') }).compact.to_set
  if Dir.exist?(new_media_dir)
    Dir.children(new_media_dir).each do |f|
      File.delete(File.join(new_media_dir, f)) unless keep.include?(f)
    end
  end

  AtomicWrite.write_json(new_path, updated)
  discard_editor_buffer
  File.delete(path) if File.expand_path(new_path) != File.expand_path(path)
  # Housekeeping only, and it runs last on purpose: an incoming/ the CLI
  # user can't unlink in must not be able to abort a save that already
  # succeeded.
  cleanup_incoming(media_files, heic_consumed)
  puts
  puts t('cli.edited_label', path: new_path)
  draft?(updated) ? rebuild_and_deploy(t('cli.updating_preview')) : maybe_rebuild
end

# Confirm-by-typing-slug + move to trash, shared by the standalone
# `delete` command and the [x] choice in draft_decision_loop. Returns
# true on an actual delete, false when the user cancelled -- callers
# decide separately whether/how to rebuild (the two call sites want
# different rebuild behavior, see cmd_delete vs draft_decision_loop).
def delete_post(slug)
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  text = post['content'].find { |b| b['type'] == 'text' }
  puts "#{post['date']}  #{post['title'] || text&.fetch('text', '')&.slice(0, 60)}"
  print t('cli.confirm_delete', slug: slug)
  confirmation = $stdin.gets&.strip
  unless confirmation == slug
    puts t('cli.cancelled')
    puts
    return false
  end

  year = File.basename(File.dirname(path))
  media_dir = File.join(MEDIA_DIR, year, slug)

  # No git, no backup elsewhere -- deleted posts go to trash/<slug>/ instead
  # of straight away, so a mistake can be undone via `restore`. Deleting the
  # same slug a second time overwrites the old version in trash -- trash
  # only ever holds the most recent deletion.
  trash_dir = File.join(TRASH_DIR, slug)
  FileUtils.rm_rf(trash_dir)
  FileUtils.mkdir_p(trash_dir)
  FileUtils.mv(path, File.join(trash_dir, 'post.json'))
  FileUtils.mv(media_dir, File.join(trash_dir, 'media')) if Dir.exist?(media_dir)

  puts t('cli.deleted_label', slug: slug, path: trash_dir)
  true
end

def cmd_delete(slug)
  return unless delete_post(slug)

  maybe_rebuild
end

# The reverse of cmd_delete: moves the post and its media back into place,
# based on the year in the post's date. Won't overwrite an existing post
# with the same slug -- that conflict (a new post was created under the same
# slug after the old one was deleted) has to be resolved by hand.
def cmd_restore(slug)
  trash_dir = File.join(TRASH_DIR, slug)
  trash_json = File.join(trash_dir, 'post.json')
  abort t('cli.nothing_in_trash', slug: slug) unless File.exist?(trash_json)

  post = JSON.parse(File.read(trash_json, encoding: 'utf-8'))
  year = Time.parse(post['date']).year.to_s
  new_dir = File.join(CONTENT_DIR, year)
  new_path = File.join(new_dir, "#{slug}.json")
  abort t('cli.post_already_exists', slug: slug, path: new_path) if File.exist?(new_path)

  FileUtils.mkdir_p(new_dir)
  FileUtils.mv(trash_json, new_path)

  trash_media = File.join(trash_dir, 'media')
  if Dir.exist?(trash_media)
    FileUtils.mkdir_p(File.join(MEDIA_DIR, year))
    FileUtils.mv(trash_media, File.join(MEDIA_DIR, year, slug))
  end
  FileUtils.rm_rf(trash_dir)

  puts t('cli.restored_label', path: new_path)

  if draft?(post)
    unless rebuild_and_deploy(t('cli.updating_preview'))
      warn t('cli.draft_saved_preview_pending', slug: slug)
      warn ''
      return
    end
    draft_decision_loop(slug)
  else
    maybe_rebuild
  end
end

# One post file -> the summary row that `list` and the pick_*_interactively
# menus work with. Shared by the content and trash listings -- the two only
# differ in where they glob.
# Returns nil for a file that can't be read as a post, after naming it.
# One truncated JSON used to make every listing and every picker die with
# a JSON::ParserError that named no file -- so the commands you would
# reach for to find the bad post were exactly the ones that stopped
# working. Skipping it keeps the rest of the archive usable; the build
# still refuses to run until it's dealt with.
def post_summary(file)
  post = JSON.parse(File.read(file, encoding: 'utf-8'))
  # Valid JSON of the wrong shape is as unusable as unparseable JSON, and
  # left to itself it crashes further along with no file named.
  raise JSON::ParserError, "not a post object (#{post.class})" unless post.is_a?(Hash)

  { slug: post['slug'], date: post['date'], title: post['title'],
    type: ContentType.dominant(post), tags: post['tags'] || [],
    state: post['state'] || PUBLISHED, scheduled: post['scheduled'],
    pinned: truthy_frontmatter?(post['pinned']) }
rescue JSON::ParserError, SystemCallError => e
  warn t('cli.unreadable_post', path: file, error: e.message.lines.first.to_s.strip[0, 100])
  nil
end

def state_marker(post)
  # Pin rides alongside the state, not instead of it: a pinned draft
  # (the pin survives unpublish) has to show both, or the list would be
  # the one place that can't answer "which post is pinned?" -- the exact
  # question that sends someone here.
  marks = []
  if post[:scheduled]
    marks << Tui.paint('[SCHEDULED]', :cyan)
  elsif post[:state] == DRAFT
    marks << Tui.paint('[DRAFT]', :yellow)
  end
  marks << Tui.paint('[PINNED]', :green) if post[:pinned]
  marks.empty? ? '' : "  #{marks.join(' ')}"
end

def summary_row(post)
  date = Time.parse(post[:date]).strftime('%Y-%m-%d')
  "#{date}  [#{post[:type]}]#{state_marker(post)}  #{post[:slug]}  #{post[:title]}"
end

def load_posts_summary
  Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map { |f| post_summary(f) }
end

def cmd_list(filters)
  posts = load_posts_summary.select do |p|
    next false if filters[:tag] && !p[:tags].map(&:downcase).include?(filters[:tag].downcase)
    next false if filters[:type] && p[:type] != filters[:type]
    next false if filters[:drafts] && p[:state] != DRAFT

    true
  end
  posts.sort_by! { |p| p[:date] }
  posts.reverse!
  posts.each { |p| puts summary_row(p) }
  drafts = posts.count { |p| p[:state] == DRAFT }
  puts t('cli.post_count', count: posts.size, drafts_suffix: drafts.positive? ? t('cli.drafts_suffix', count: drafts) : '')
  puts
end

# How many posts the pick_*_interactively menus offer. Was 10 back when
# Tui.menu printed every item it was handed, so the list had to fit on
# screen by construction; now that the menu scrolls, the only real cost
# of a longer list is how far you might have to arrow through it -- and
# typing a slug directly still short-circuits that entirely.
RECENT_LIST_COUNT = 50

def recent_posts(limit)
  posts = load_posts_summary
  posts.sort_by! { |p| p[:date] }
  posts.reverse!
  posts.first(limit)
end

# Shared by pick_slug_interactively/pick_draft_interactively: numbers the
# given posts, lets the user answer with either that number or a literal
# slug typed directly (unchanged behavior for anything that isn't a plain
# in-range digit).
def pick_from_list(posts, empty_message)
  abort "#{empty_message}\n\n" if posts.empty?

  # In a terminal: an arrow-key menu (digits still quick-select, typing
  # letters falls back to entering a slug). Piped input keeps the
  # numbered list exactly as before.
  if Tui.interactive?
    choice = Tui.menu(posts.map { |p| summary_row(p) },
                      hint: t('cli.menu_hint'), allow_text: true,
                      text_prompt: t('cli.enter_number_or_slug'))
    abort t('cli.cancelled_empty') if choice.nil?
    puts
    return choice.is_a?(Integer) ? posts[choice][:slug] : choice
  end

  posts.each_with_index do |p, i|
    puts "#{i + 1}) #{summary_row(p)}"
  end
  puts
  print t('cli.enter_number_or_slug')
  input = $stdin.gets&.strip.to_s
  abort t('cli.cancelled_empty') if input.empty?
  puts

  if input =~ /\A\d+\z/ && (1..posts.size).cover?(input.to_i)
    posts[input.to_i - 1][:slug]
  else
    input
  end
end

# Lets `edit`/`delete` be called with no slug: shows the RECENT_LIST_COUNT
# most recent posts regardless of state.
def pick_slug_interactively
  pick_from_list(recent_posts(RECENT_LIST_COUNT), t('cli.no_posts_to_pick'))
end

# Lets `publish` be called with no slug: publishing an already-published post
# doesn't make sense, so this offers drafts only -- unlike edit/delete's
# pick_slug_interactively, which shows recent posts of any state.
def pick_draft_interactively
  drafts = load_posts_summary.select { |p| p[:state] == DRAFT }
  drafts.sort_by! { |p| p[:date] }
  drafts.reverse!
  pick_from_list(drafts.first(RECENT_LIST_COUNT), t('cli.no_drafts_to_publish'))
end

# Lets `unpublish` be called with no slug: offers only published posts --
# reverting a draft to draft makes no sense, symmetric with pick_draft_interactively.
def pick_published_interactively
  published = load_posts_summary.reject { |p| p[:state] == DRAFT }
  published.sort_by! { |p| p[:date] }
  published.reverse!
  pick_from_list(published.first(RECENT_LIST_COUNT), t('cli.no_published_posts'))
end

def trash_summary
  Dir.glob(File.join(TRASH_DIR, '*', 'post.json')).filter_map { |f| post_summary(f) }
end

# Lets `restore` be called with no slug: offers the trash's contents, same
# pattern as the other pick_*_interactively helpers.
def pick_trash_interactively
  trashed = trash_summary
  trashed.sort_by! { |p| p[:date] }
  trashed.reverse!
  pick_from_list(trashed.first(RECENT_LIST_COUNT), t('cli.trash_empty'))
end

# Said out loud at the moment it happens. The post is saved and the file
# is copied either way -- since the build stopped treating "size unknown"
# as a tracking pixel, the image renders instead of vanishing -- but the
# page can't reserve space for it, and a HEIC won't display anywhere
# except Safari. (Whether to refuse or convert those is a per-installation
# choice: media.convert_heic, handled in convert_heic_attachments above --
# so by the time this runs, a HEIC only reaches here on an install that
# left the conversion off.)
def warn_unreadable_image(file)
  return unless file

  warn t('cli.image_dimensions_unknown', file: File.basename(file.to_s))
  warn t('cli.image_heic_hint') if File.extname(file.to_s).downcase.match?(/\A\.hei[cf]\z/)
end

def fill_image_dimensions(blocks, media_files, media_dir = nil)
  reverse = media_files.invert
  blocks.each do |b|
    next unless %w[image video].include?(b['type'])
    next if (b['media'] || []).empty?

    media = b['media'].first
    # Newly-attached images are read from their original source path (the
    # copy into media_dir hasn't happened yet at this point). Images that
    # already lived in media_dir (untouched during this edit) have no entry
    # in media_files, so fall back to reading the file that's still there --
    # without this, every re-edit of a post with existing images would wipe
    # their width/height and cause build_blog.rb's degenerate_image? filter
    # to silently drop them from the rendered page.
    src = reverse[media['url']] || (media_dir && File.join(media_dir, media['url'].to_s))
    src = nil unless src && File.exist?(src)
    dims = src ? (b['type'] == 'video' ? MediaDimensions.video(src) : MediaDimensions.image(src)) : nil
    if dims
      media['width'], media['height'] = dims
    else
      media.delete('width')
      media.delete('height')
      warn_unreadable_image(src || media['url'])
    end
  end
end

# Build and deploy as one step -- the mechanics (and the reasoning for
# the built-in --prune) live in Publishing.rebuild_and_deploy, shared
# with the scheduled-publish cron.
def rebuild_and_deploy(reason = nil)
  Publishing.rebuild_and_deploy(reason || t('cli.default_rebuild_reason'))
end

def maybe_rebuild
  puts
  if Tui.key_choice(t('cli.rebuild_prompt')) == 'n'
    puts
    return
  end

  rebuild_and_deploy
end

# A manual build+deploy not tied to a specific post -- e.g. after a manual
# template edit, when nothing else would otherwise trigger a rebuild.
def cmd_rebuild
  rebuild_and_deploy
end

def print_usage
  puts t('cli.usage', recent_count: RECENT_LIST_COUNT)
end

# --- interactive wizard ---------------------------------------------

# [internal name for dispatch, menu label]. The menu lists ACTIVITIES,
# not every operation the engine has: publish, schedule, unpublish,
# delete and the announcement all happen to one post the author already
# has in hand, so they live in that post's properties dialog (and the
# draft dialog) rather than as five more entries here. The CLI commands
# for each still exist unchanged -- only the menu stopped listing them.
# `restore` stays: a post in trash is not reachable through the picker,
# so it genuinely needs its own way in.
WIZARD_MENU = [
  ['add', t('cli.wizard_menu_add')],
  ['post', t('cli.wizard_menu_post')],
  ['list', t('cli.wizard_menu_list')],
  ['restore', t('cli.wizard_menu_restore')],
  ['rebuild', t('cli.wizard_menu_rebuild')]
].freeze

# The wizard's one post-shaped entry: pick a post, then choose between
# its text and its properties. Enter goes straight to the editor, so the
# common path costs a single extra keypress; the CLI pays nothing --
# `./blog.sh edit` skips this crossroads entirely and `props` is its own
# command.
def wizard_post_entry
  slug = pick_slug_interactively
  path = find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  summary = post_summary(path)
  puts summary_row(summary) if summary
  puts
  case Tui.key_choice(t('cli.edit_what_prompt'))
  when '', 'e' then cmd_edit(slug)
  when 'v' then cmd_props(slug)
  else
    puts t('cli.cancelled')
    puts
  end
end

def run_wizard_choice(command)
  case command
  when 'add' then cmd_add
  when 'post' then wizard_post_entry
  when 'restore' then cmd_restore(pick_trash_interactively)
  when 'list' then cmd_list({})
  when 'rebuild' then cmd_rebuild
  end
# Plenty of cmd_*/pick_*_interactively paths end in `abort` (cancellation,
# "not found", an empty list...) -- correct behavior for a one-shot CLI, but
# here, uncaught, it would end the whole wizard instead of returning to the
# menu. `abort`/`exit` raise SystemExit, not StandardError, hence the
# explicit rescue.
rescue SystemExit
  nil
end

# Which engine, which site, which domain. Lives in lib/site_header.rb so
# ./import.sh prints the identical block -- see the reasoning there.
def wizard_header
  SiteHeader.render
end

def run_wizard
  # In a terminal the wizard is an arrow-key menu (digits still work as
  # quick select, Esc exits). Piped input keeps the numbered prompt.
  if Tui.interactive?
    loop do
      # Reprinted every iteration, not just once at startup: each
      # pause_and_clear wipes the screen, and without this the site
      # identity (which blog am I even connected to?) would vanish
      # from view after the very first action -- the whole point for
      # anyone managing more than one site.
      puts wizard_header
      puts
      puts t('cli.wizard_prompt_action')
      puts
      index = Tui.menu(WIZARD_MENU.map { |_, desc| desc }, hint: t('cli.menu_hint'))
      # Esc leaves the cursor on the line right under the hint, so the shell
      # prompt lands flush against the menu. One blank line to sit on the
      # way out -- which is also what the piped branch below already does
      # with its `puts` after reading the choice.
      if index.nil?
        puts
        break
      end

      puts
      run_wizard_choice(WIZARD_MENU[index].first)
      Tui.pause_and_clear(t('cli.wizard_continue_prompt'))
    end
    return
  end

  puts wizard_header
  loop do
    puts
    puts t('cli.wizard_prompt_action')
    puts
    WIZARD_MENU.each_with_index { |(_, desc), i| puts "  #{i + 1}) #{desc}" }
    puts "  #{t('cli.wizard_exit_option')}"
    puts
    print t('cli.wizard_choice_prompt')
    choice = $stdin.gets&.strip.to_s
    puts

    break if choice.empty? || choice == '0'

    index = choice.to_i - 1
    unless choice =~ /\A\d+\z/ && (0...WIZARD_MENU.size).cover?(index)
      puts t('cli.wizard_unknown_choice')
      next
    end

    run_wizard_choice(WIZARD_MENU[index].first)
  end
end

# --- CLI dispatch ----------------------------------------------------------

command = ARGV.shift

# `help` and `version` are the two commands a fresh (or broken) install
# must be able to answer before any config exists -- SiteConfig.get above
# degrades to defaults for them, and "which version is this?" is asked
# precisely when something else is already wrong. Everything else -- the
# wizard included -- still requires config/site.yml, and asking for it here
# keeps the abort message as the first thing said.
SiteConfig.data unless ['help', '--help', '-h', 'version', '--version', '-v'].include?(command)

if command.nil?
  run_wizard
else
  case command
  when 'add'
    cmd_add
  when 'edit'
    slug = ARGV.shift || pick_slug_interactively
    cmd_edit(slug)
  when 'props'
    slug = ARGV.shift || pick_slug_interactively
    cmd_props(slug)
  when 'delete'
    slug = ARGV.shift || pick_slug_interactively
    cmd_delete(slug)
  when 'restore'
    slug = ARGV.shift || pick_trash_interactively
    cmd_restore(slug)
  when 'publish'
    slug = ARGV.shift || pick_draft_interactively
    cmd_publish(slug)
  when 'schedule'
    slug = ARGV.shift || pick_draft_interactively
    cmd_schedule(slug)
  when 'unpublish'
    slug = ARGV.shift || pick_published_interactively
    cmd_unpublish(slug)
  when 'toot'
    slug = ARGV.shift || pick_published_interactively
    cmd_toot(slug)
  when 'bluesky'
    slug = ARGV.shift || pick_published_interactively
    cmd_bluesky(slug)
  when 'rebuild'
    cmd_rebuild
  when 'preview'
    # A local static server over the build output -- the quickest way to
    # look at the site before deploying anywhere.
    unless Dir.exist?(File.join(ROOT, 'public.nosync'))
      abort t('cli.preview_missing_public')
    end
    port = (ARGV.shift || '8000').to_i
    puts t('cli.preview_serving', url: "http://localhost:#{port}/")
    # The serve loop below blocks forever -- with stdout piped (not a TTY)
    # the URL line would sit in the buffer the whole time, so push it out.
    $stdout.flush
    PreviewServer.serve(File.join(ROOT, 'public.nosync'), port)
  when 'list'
    filters = {}
    ARGV.each do |arg|
      filters[:type] = Regexp.last_match(1) if arg =~ /\A--type=(.+)\z/
      filters[:tag] = Regexp.last_match(1) if arg =~ /\A--tag=(.+)\z/
      filters[:drafts] = true if arg == '--drafts'
    end
    cmd_list(filters)
  when 'help'
    print_usage
  when 'version', '--version', '-v'
    puts "blog.sh #{BlogSh::VERSION}"
  else
    print_usage
    exit 1
  end
end
