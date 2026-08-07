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
require_relative '../lib/video_probe'
require_relative '../lib/embed_lookup'
require_relative '../lib/file_size'
require_relative '../lib/slug'
require_relative '../lib/content_type'
require_relative '../lib/post_text'
require_relative '../lib/search_query'
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

# Two things about a video decide whether a reader sees it, and neither is
# visible to the person attaching it: the codec inside, and the container
# around it. A phone records HEVC in a QuickTime .mov by default, so this
# is the ordinary case, not an exotic one.
#
# Said out loud, never refused. HEVC is not HEIC: a HEIC photo displays in
# Safari and nowhere else, while HEVC plays in the large majority of
# browsers -- refusing it would take away a video most readers could
# watch. The size limit already stops the genuinely undeployable files,
# and on real phone footage the two overlap almost completely (the one
# HEVC clip in the sample this was measured on was also the only one over
# 100 MB). What was missing was a sentence while the author can still act.
#
# One message per file, not two: an HEVC .mov is both, and the transcode
# below lands in .mp4 anyway, so saying "repack it" next to "re-encode it"
# would only offer a command that keeps the codec.
def check_video_playback(media_files)
  hevc = []
  quicktime = []
  media_files.each_key do |src|
    next unless src && File.exist?(src) && MarkdownParser.video_path?(src)

    if VideoProbe.hevc?(src)
      hevc << File.basename(src)
    elsif File.extname(src).downcase == '.mov'
      quicktime << File.basename(src)
    end
  end
  hevc.uniq!
  quicktime.uniq!

  # The command names a real file, the way the HEIC refusal does -- a
  # placeholder is one more thing to get wrong at the moment someone is
  # already annoyed. ffmpeg is not on a Mac by default (unlike sips), so
  # the message says where to get it.
  puts t('cli.video_hevc', files: hevc.join(', '), command: transcode_command(hevc.first)) if hevc.any?
  puts t('cli.video_quicktime', files: quicktime.join(', '), command: remux_command(quicktime.first)) if quicktime.any?
end

# The one thing writing a post does over the network, and it is asked once
# per embed: Funkwhale and Bandcamp are the two platforms whose player
# address their page address does not contain (see lib/embed_lookup.rb).
# The answer is stored in the post, so an edit never asks again and the
# build stays offline.
#
# A failure is a sentence, not an abort. Writing a post on a train has to
# end with a saved post: what is missing is a player, and the block still
# carries the address, so the page links it and re-saving retries.
def resolve_embed_lookups(blocks)
  pending = blocks.select { |block| Embed.needs_lookup?(block) }
  return if pending.empty?

  pending.each do |block|
    # Said before the call, not after: it can take seconds against a slow
    # instance, and silence would be indistinguishable from a hang.
    puts t('cli.embed_lookup_working', url: block['url'])
    next if EmbedLookup.resolve(block)

    puts t('cli.embed_lookup_failed', url: block['url'])
  end
end

def transcode_command(name)
  "ffmpeg -i #{name.to_s.shellescape} -c:v libx264 -crf 23 -c:a copy #{mp4_name(name).shellescape}"
end

def remux_command(name)
  "ffmpeg -i #{name.to_s.shellescape} -c copy #{mp4_name(name).shellescape}"
end

def mp4_name(name)
  "#{File.basename(name.to_s, File.extname(name.to_s))}.mp4"
end

# --- editor round-trip -------------------------------------------------

# Where the text from the last editor session waits until the post it
# belongs to is safely on disk. The temp directory the editor works in is
# gone the moment edit_in_editor returns, but every check on what was
# typed -- a second frontmatter header, an image line without its blank
# lines, an unparseable date, a content-loss confirmation -- runs after
# that and aborts. Without this copy those aborts threw the article away.
EDITOR_BUFFER_PATH = File.join(ROOT, '.last-edit.md')

# What the buffer was written by, next to the buffer itself rather than
# inside it. A marker line in the .md would travel with the text into the
# post if someone recovered the file by hand, and this file has to survive
# being read by a human with an editor.
#
# It is what makes recovery safe rather than merely possible: text from an
# interrupted `edit <slug>` restored into an `add` would silently create a
# SECOND post instead of continuing the first, and nothing afterwards could
# tell the two apart.
EDITOR_BUFFER_META_PATH = File.join(ROOT, '.last-edit.meta')

def keep_editor_buffer(text, origin = nil)
  # Atomic, like every post write: this file is the only copy of what was
  # just typed, and a plain write that runs out of disk truncates the
  # PREVIOUS buffer to nothing -- while the notice below still says the
  # text is safe.
  AtomicWrite.write(EDITOR_BUFFER_PATH, text)
  File.chmod(0o600, EDITOR_BUFFER_PATH)
  return unless origin

  AtomicWrite.write(EDITOR_BUFFER_META_PATH, JSON.generate(origin.merge('saved_at' => Time.now.iso8601)))
  File.chmod(0o600, EDITOR_BUFFER_META_PATH)
rescue SystemCallError
  nil # a buffer we can't write is not a reason to refuse the save
end

def discard_editor_buffer
  [EDITOR_BUFFER_PATH, EDITOR_BUFFER_META_PATH].each { |path| File.delete(path) if File.exist?(path) }
rescue SystemCallError
  nil
end

def editor_buffer_origin
  return nil unless File.exist?(EDITOR_BUFFER_META_PATH)

  JSON.parse(File.read(EDITOR_BUFFER_META_PATH, encoding: 'utf-8'))
rescue StandardError
  nil # an unreadable marker means "unknown origin", not a broken CLI
end

# Asked at the start of `add`/`edit`, before this session's editor can
# overwrite the buffer. Returns the text to open the editor with, or nil
# for "start from the usual template".
#
# The buffer has been written since the very first version of this file --
# what was missing was anyone ever offering it back. The engine said "your
# text is in .last-edit.md", and the author then had to copy it out by
# hand before the next add/edit overwrote it. Real use found that friction
# the hard way: a save aborted on a missing attachment, and a whole post
# had to be reassembled from a file the CLI was about to overwrite.
#
# No blank-Enter default anywhere here: every branch is an explicit key, so
# a stray return can neither restore old text into a new post nor throw
# away the only copy of something.
def offer_editor_buffer(kind, slug = nil)
  text = read_editor_buffer
  return nil unless text

  origin = editor_buffer_origin
  matches = origin && origin['kind'] == kind && origin['slug'].to_s == slug.to_s

  puts
  puts describe_editor_buffer(text, origin)
  # A buffer from a different operation is NOT offered for restoring: this
  # is the whole reason the marker file exists. Naming the command that
  # would restore it turns a refusal into directions.
  puts t('cli.buffer_belongs_elsewhere', command: buffer_command(origin)) unless matches

  loop do
    key = Tui.key_choice(t(matches ? 'cli.buffer_prompt' : 'cli.buffer_prompt_foreign'))
    case key
    when 'r'
      next puts(t('cli.buffer_belongs_elsewhere', command: buffer_command(origin))) unless matches

      puts t('cli.buffer_restored')
      return text
    when 'd'
      discard_editor_buffer
      puts t('cli.buffer_discarded')
      return nil
    when 'c'
      puts t('cli.buffer_kept_for_now', path: EDITOR_BUFFER_PATH)
      return nil
    else
      # A piped run has nothing more to say: continue rather than loop on
      # an empty stdin forever, and say what that means for the buffer.
      unless Tui.interactive?
        puts t('cli.buffer_kept_for_now', path: EDITOR_BUFFER_PATH)
        return nil
      end
    end
  end
end

def read_editor_buffer
  return nil unless File.exist?(EDITOR_BUFFER_PATH)

  text = File.read(EDITOR_BUFFER_PATH, encoding: 'utf-8')
  text.strip.empty? ? nil : text
rescue SystemCallError
  nil
end

# The first line that isn't frontmatter, so the author recognises the text
# without having to open the file -- a buffer is identified by what it says,
# not by its size.
def describe_editor_buffer(text, origin)
  lines = text.lines.map(&:chomp)
  preview = lines.find { |line| !line.strip.empty? && line.strip != '---' && !line.match?(/\A\w+:/) }
  when_saved = begin
    Time.parse(origin['saved_at']).getlocal.strftime(t('date_time_format'))
  rescue StandardError
    nil
  end
  t('cli.buffer_found',
    what: buffer_command(origin),
    when: when_saved ? t('cli.buffer_found_when', time: when_saved) : '',
    lines: lines.size,
    preview: preview.to_s.strip[0, 60])
end

def buffer_command(origin)
  case origin && origin['kind']
  when 'add' then './blog.sh add'
  when 'edit' then "./blog.sh edit #{origin['slug']}"
  else t('cli.buffer_unknown_origin')
  end
end

# Says where the text is if the process ends with the buffer still there.
# Every successful save discards it first, so this only speaks up when the
# post did not make it to disk -- whichever of the many aborts (or a
# Ctrl-C) got in the way, without each of them having to know about it.
def arm_editor_buffer_notice
  return if @editor_buffer_notice_armed

  @editor_buffer_notice_armed = true
  at_exit do
    # Existing is not enough -- an empty file is not a rescued post, and
    # promising one that isn't there is worse than saying nothing.
    warn t('cli.editor_buffer_kept', path: EDITOR_BUFFER_PATH) if File.size?(EDITOR_BUFFER_PATH)
  end
end

def edit_in_editor(initial_content, hint_comment, origin = nil)
  text = editor_round_trip(initial_content, hint_comment)
  # An editor closed on an untouched template has nothing worth keeping --
  # and writing it anyway would overwrite a buffer the author had just been
  # told was still there. Opening `add` to look at something, changing your
  # mind and quitting must not be how an interrupted post gets lost.
  if text != initial_content
    keep_editor_buffer(text, origin)
    arm_editor_buffer_notice
  end
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
    strip_editor_notes(File.read(path, encoding: 'utf-8'))
  end
end

# Removes the guide block and the author's own `//` notes -- OUTSIDE fenced
# code only.
#
# This used to be two gsubs over the whole file. `//` opens a comment in
# half the languages anyone would paste into a ```js fence, so saving a post
# deleted those lines from the code sample; the content-loss guard counts
# block TYPES, so a code block that merely lost lines looked untouched. The
# `<!--` one was worse: written `/m` and non-greedy, it ate everything up to
# the next `-->` anywhere in the post, prose and fence boundaries included.
# Editing such a post -- changing only its title -- was enough to lose them.
#
# Line-based rather than regex-based on purpose: every line that is not a
# note is passed through byte for byte, so nothing else can be reshaped by
# accident.
def strip_editor_notes(text)
  kept = []
  in_fence = false
  in_comment = false

  text.each_line do |line|
    if line.lstrip.start_with?('```')
      in_fence = !in_fence
      kept << line
      next
    end
    if in_fence
      kept << line
      next
    end
    if in_comment
      in_comment = false if line.include?('-->')
      next
    end
    if line.start_with?('<!--')
      in_comment = true unless line.include?('-->')
      next
    end
    next if line.start_with?('//')

    kept << line
  end

  kept.join
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
  # Offered before the template is built, because restoring means opening
  # the editor on the recovered text INSTEAD of the template.
  restored = offer_editor_buffer('add')
  template = restored || build_frontmatter(title: '', tags: '', type: '') + "First paragraph's text.\n"
  raw = edit_in_editor(template, FRONTMATTER_HINT, { 'kind' => 'add' })

  # Editor closed without saving (or saved untouched) leaves the template
  # byte-identical -- treat that as "nothing happened": no post, no toot,
  # no rebuild question. (This is how an accidental empty-template post once
  # made it all the way to a published Mastodon toot.)
  #
  # After a restore the comparison is against the RESTORED text, which is
  # the honest no-op test for that case: someone who recovers a draft and
  # closes the editor untouched has changed nothing this session either.
  if raw == template
    # Nothing is discarded here. An untouched editor wrote no buffer (see
    # edit_in_editor), so the only thing that could be deleted is text from
    # an EARLIER session -- recovered a moment ago, or left alone with [c].
    # Throwing that away would turn the action meant to protect it into the
    # one that loses it.
    warn t('cli.buffer_still_kept', path: EDITOR_BUFFER_PATH) if restored
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
  check_video_playback(media_files)
  resolve_embed_lookups(blocks)
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

def prompt_and_schedule(path, post, rebuild: true, raw: nil)
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
  # NOT `raw = ...`: this method's raw: keyword is the file's bytes as
  # they looked before the dialog opened -- the staleness guard's whole
  # evidence. Reusing the name here once overwrote that capture with the
  # typed date line, and the guard then compared the post file against
  # the answer "2026-12-24 08:00", failed by construction, and every
  # scheduling path in the CLI aborted with "changed on disk".
  answer = $stdin.gets
  # EOF is not Enter. With an offer on screen an empty line accepts, and
  # Ctrl-D (or a piped run whose input ran out) would otherwise schedule,
  # rebuild and deploy a post nobody confirmed.
  return false if answer.nil?

  input = answer.strip
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

  write_scheduled_date(path, post, date, raw: raw)
  rebuild_and_deploy(t('cli.updating_preview')) if rebuild
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
    choice = Tui.menu(rows, hint: t('cli.menu_hint_plain'))
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

  raw = File.read(path, encoding: 'utf-8')
  post = JSON.parse(raw)
  unless draft?(post)
    puts t('cli.schedule_only_drafts', slug: slug)
    puts
    return
  end

  if post['scheduled']
    unschedule_post(path, post, slug, raw: raw)
    return
  end

  # The bytes from before the prompt ride along, so the cron publishing
  # this exact post mid-dialog is caught -- the same guard every other
  # path into scheduling already carries.
  prompt_and_schedule(path, post, raw: raw)
end

# Shared by the CLI toggle above and the [n] action in the properties
# dialog -- the wizard lost the standalone `schedule` menu item, so
# without this the dialog could plan a post but never change its mind.
# `raw:` for the same reason write_scheduled_date takes it: this writes a
# captured post back after a prompt, and the cron may have published it in
# the meantime.
def unschedule_post(path, post, slug, raw: nil)
  abort_if_post_changed(path, raw, slug) if raw
  updated = post.dup
  updated.delete('scheduled')
  AtomicWrite.write_json(path, updated)
  puts t('cli.unscheduled_label', slug: slug)
  puts
end

# Writes `date` into a draft as its scheduled publish time. A date in
# another year moves the post, JSON and media together. Left in the old
# year's folder the two disagree: the build derives both the URL and the
# media lookup from the date, so the draft preview loses every image --
# and publishing it later hits the same missing media year that used to
# abort the cron. Shared by prompt_and_schedule and the queue screen,
# which rewrites times too. Returns the (possibly moved) path.
#
# `raw:` is the bytes the caller read before it started asking questions.
# Every caller here writes a captured copy of the post back, and the
# scheduled-publish cron runs every 15 minutes -- so between that read and
# this write the post may already be published, announced and live. Writing
# the capture then reverts it to a draft, drops the announcement URL (so
# `unpublish` could never delete the toot), lets the next deploy --prune
# take the live page down, and lets the next cron tick publish and announce
# it a second time. The check therefore belongs HERE, at the last
# instruction before the write, not at the top of a dialog that then waits
# for a keypress.
def write_scheduled_date(path, post, date, raw: nil, slug: nil)
  abort_if_post_changed(path, raw, slug || post['slug']) if raw
  updated = post.merge('date' => date.iso8601, 'scheduled' => true)
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
  new_path
end

# --- the queue screen -------------------------------------------------

# Every scheduled draft in publish order, with everything an action needs
# in hand. Re-collected before every redraw on purpose: the scheduled-
# publish cron runs every 15 minutes, and a post it published mid-session
# must drop out of the list rather than get swapped around as a stale
# copy.
def queue_entries
  Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
    raw = File.read(file, encoding: 'utf-8') rescue next
    post = JSON.parse(raw) rescue next
    next unless post.is_a?(Hash) && post['scheduled']

    time = Time.parse(post['date']) rescue next
    # The bytes travel with the entry, not just the parsed hash: every
    # write below happens after a prompt that can sit open for minutes,
    # and this is what the staleness guard compares against at the last
    # possible moment (see write_scheduled_date).
    { time: time, slug: post['slug'], path: file, post: post, raw: raw }
  end.sort_by { |entry| entry[:time] }
end

def queue_row(entry, index)
  time = entry[:time].getlocal.strftime(t('date_time_format'))
  overdue = entry[:time] <= Time.now ? "  #{t('cli.queue_overdue')}" : ''
  format('%2d.  %s  %s%s', index + 1, time, entry[:slug], overdue)
end

# Row selection, in both faces the pickers already have: the arrow-key
# menu in a terminal, a numbered list plus a read line when piped -- so
# the queue stays scriptable the same way everything else is.
def queue_pick(entries)
  rows = entries.each_with_index.map { |entry, i| queue_row(entry, i) }
  return Tui.menu(rows, hint: t('cli.queue_menu_hint')) if Tui.interactive?

  rows.each { |row| puts "  #{row}" }
  puts
  print t('cli.queue_pick_prompt')
  line = $stdin.gets&.strip.to_s
  puts
  index = line.to_i - 1
  line =~ /\A\d+\z/ && (0...entries.size).cover?(index) ? index : nil
end

# The whole queue as one screen: pick a post, act on it, come back to
# the list. Everything here changes only content JSON; the preview
# rebuild happens once, on the way out, not after every move -- with a
# multi-post reshuffle the intermediate states aren't worth a deploy
# each.
def cmd_queue
  dirty = false
  loop do
    entries = queue_entries
    if entries.empty?
      puts t('cli.queue_empty')
      puts
      break
    end

    puts Tui.paint(t('cli.props_queue_heading', count: entries.size), :bold)
    puts
    index = queue_pick(entries)
    if index.nil?
      puts
      break
    end

    puts
    dirty = true if queue_act(entries, index)
  end

  rebuild_and_deploy(t('cli.updating_preview')) if dirty
end

# Returns true when something changed that the closing rebuild must pick
# up. "Publish now" rebuilds inside publish_draft as always; only the
# compaction it may be followed by still needs the closing one.
def queue_act(entries, index)
  entry = entries[index]
  case Tui.key_choice(t('cli.queue_actions', slug: entry[:slug]))
  when 'u' then queue_swap(entries, index, index - 1)
  when 'd' then queue_swap(entries, index, index + 1)
  when 'p'
    freed = entry[:time]
    publish_draft(entry[:slug])
    queue_offer_compact(freed, entries[(index + 1)..])
  when 's'
    puts
    prompt_and_schedule(entry[:path], entry[:post], rebuild: false, raw: entry[:raw])
  when 'n'
    unschedule_post(entry[:path], entry[:post], entry[:slug], raw: entry[:raw])
    queue_offer_compact(entry[:time], entries[(index + 1)..])
  when '' then false
  else
    puts t('cli.queue_unknown')
    puts
    false
  end
end

# Moving a post earlier or later means exchanging times with its
# neighbour: the set of occupied slots never changes, only which post
# sits in which -- so a hand-picked 14:17 stays a 14:17, it just gets a
# different post. A neighbour whose time already passed is off limits:
# giving another post that time would schedule it into the past, and the
# cron owns it now anyway.
def queue_swap(entries, index, other_index)
  unless (0...entries.size).cover?(other_index)
    puts t(other_index.negative? ? 'cli.queue_already_first' : 'cli.queue_already_last')
    puts
    return false
  end

  entry, other = entries[index], entries[other_index]
  if entry[:time] <= Time.now || other[:time] <= Time.now
    puts t('cli.queue_swap_overdue')
    puts
    return false
  end

  write_scheduled_date(entry[:path], entry[:post], other[:time], raw: entry[:raw])
  write_scheduled_date(other[:path], other[:post], entry[:time], raw: other[:raw])
  puts Tui.paint(t('cli.queue_swapped', slug: entry[:slug],
                                        date: other[:time].getlocal.strftime(t('date_time_format'))), :green)
  puts
  true
end

# After a post leaves the queue its time is free again, and the posts
# behind it can each step forward into the gap -- every one takes over
# its predecessor's time, so again no slot appears or disappears. Asked,
# never automatic: a hand-picked date further down may be deliberate (an
# anniversary post), and moving it unasked would break the scheduler's
# one promise -- nothing moves a post's time except the author. A gap in
# the past offers nothing: stepping into it would publish immediately.
def queue_offer_compact(freed_time, rest)
  rest = Array(rest)
  return false if rest.empty? || freed_time <= Time.now

  answer = Tui.key_choice(t('cli.queue_compact_prompt', count: rest.size))
  return false unless answer.start_with?(t('cli.confirm_yes_char'))

  times = [freed_time] + rest.map { |entry| entry[:time] }
  rest.each_with_index do |entry, i|
    entry[:path] = write_scheduled_date(entry[:path], entry[:post], times[i], raw: entry[:raw])
  end
  puts Tui.paint(t('cli.queue_compacted'), :green)
  puts
  true
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

# The props actions that write the captured post back ([s]/[n]/[r]/[c])
# each run this first: if the file changed since the dialog read it, the
# capture is stale and writing it would clobber whatever changed it (the
# cron, another session). Refusing is the only safe answer -- the two
# versions can't be merged -- and it's the same guard edit_post uses.
def abort_if_post_changed(path, original_raw, slug)
  return if File.exist?(path) && File.read(path, encoding: 'utf-8') == original_raw

  abort t('cli.post_changed_while_editing', slug: slug)
end

def cmd_props(slug)
  network = SiteConfig.comment_network
  network_label = { mastodon: 'Mastodon', bluesky: 'Bluesky' }[network]

  loop do
    path = find_post_path(slug)
    abort t('cli.post_not_found', slug: slug) unless path

    # Read once per redraw, and kept to compare against just before any
    # action writes it back. The dialog can sit at its prompt for minutes
    # while the scheduled-publish cron runs every 15 -- so a captured post
    # can be stale by the time [s]/[n]/[r]/[c] act on it, and writing it
    # back would revert a post the cron just published, drop the
    # announcement URL it stored, and (via [s]) announce it a second time.
    # Same hazard edit_post guards against, same guard.
    original_raw = File.read(path, encoding: 'utf-8')
    post = JSON.parse(original_raw)
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
    # Old addresses are counted, not listed: a post renamed a few times
    # would push everything else off the screen, and the list is one
    # keypress away in [a].
    addresses = Array(post['former_slugs']).size
    props_line('addresses', addresses.positive? ? t('cli.props_addresses_count', count: addresses) : nil)
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
        prompt_and_schedule(path, post, raw: original_raw)
      when 'n'
        unless post['scheduled']
          puts t('cli.props_unknown_draft')
          next
        end
        unschedule_post(path, post, slug, raw: original_raw)
      when 'r'
        slug = rename_post(path, post, raw: original_raw)
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
      when 'c'
        toggle_pin(path, post, slug, raw: original_raw)
      when 'r'
        slug = rename_post(path, post, raw: original_raw)
      when 'a'
        props_addresses(path, slug)
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
def toggle_pin(path, post, slug, raw: nil)
  abort_if_post_changed(path, raw, slug) if raw
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
# The addresses a post used to answer at, and the one way to drop one.
#
# A former_slugs entry normally needs no attention: it is a redirect, it
# costs one stub page, and it keeps an old link alive. But an entry can go
# stale -- a NEW post takes that address, the build refuses to overwrite a
# live page with a stub (rightly) and says so on every single build. That
# warning had no cure: nothing in the CLI could remove the entry, and the
# only remaining option was hand-editing the post's JSON, which is exactly
# what this dialog exists to avoid.
#
# Taken addresses are marked as such, because that is the whole reason
# someone would come here: the marked one is the entry to drop.
def props_addresses(path, slug)
  loop do
    # Re-read at the top of every pass rather than trusting the copy the
    # dialog is holding: this screen writes the post back, and the window
    # between reading it and writing it is however long someone spends at
    # the picker -- with the scheduled-publish cron running every 15
    # minutes. The write below refuses if anything moved in between.
    raw = File.read(path, encoding: 'utf-8')
    post = JSON.parse(raw)
    entries = Array(post['former_slugs']).map(&:to_s)
    if entries.empty?
      puts t('cli.addresses_none')
      return
    end

    current = "#{File.basename(File.dirname(path))}/#{slug}"
    rows = entries.each_with_index.map { |former, i| address_row(former, current, i) }
    puts
    puts Tui.paint(t('cli.addresses_heading', count: entries.size), :dim)
    index = address_pick(rows)
    return if index.nil?

    former = entries[index]
    print t('cli.addresses_drop_confirm', address: former)
    next unless Tui.key_choice('') == t('cli.confirm_yes_char')

    abort_if_post_changed(path, raw, slug)
    remaining = entries - [former]
    updated = post.dup
    remaining.empty? ? updated.delete('former_slugs') : updated['former_slugs'] = remaining
    AtomicWrite.write_json(path, updated)
    puts Tui.paint(t('cli.addresses_dropped', address: former), :green)
    maybe_rebuild
  end
end

# "2019/old-title  — taken by another post" for the stale ones. Taken
# means: a post other than this one owns that year/slug today, so the
# build will never emit the stub and the warning repeats forever.
#
# The comparison is against the post's whole current address, not its
# slug: a post that moved between years keeps its slug, and the address it
# vacated is precisely the one another post can take.
def address_row(former, current, index)
  parts = former.split('/').reject(&:empty?)
  taken = parts.size == 2 && former != current &&
          File.exist?(File.join(CONTENT_DIR, parts[0], "#{parts[1]}.json"))
  note = if parts.size != 2
           "  #{t('cli.addresses_unusable')}"
         elsif taken
           "  #{t('cli.addresses_taken')}"
         else
           ''
         end
  format('%2d.  %s%s', index + 1, former, note)
end

# Same two faces as every other picker here: arrow keys in a terminal, a
# numbered list and a read line when piped.
def address_pick(rows)
  return Tui.menu(rows, hint: t('cli.addresses_menu_hint')) if Tui.interactive?

  rows.each { |row| puts "  #{row}" }
  puts
  print t('cli.addresses_pick_prompt')
  line = $stdin.gets&.strip.to_s
  puts
  index = line.to_i - 1
  line =~ /\A\d+\z/ && (0...rows.size).cover?(index) ? index : nil
end

# Returns the slug the caller should continue with: the new one after a
# rename, the old one after any kind of cancel.
def rename_post(path, post, raw: nil)
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
  # A slug is a filename (<slug>.json) and a URL segment; slugify keeps it
  # to safe characters but not to a safe length, so a pasted paragraph
  # reaches the write as a filename the filesystem rejects with a raw
  # ENAMETOOLONG. cmd_add caps its slug at eight words for readability;
  # this caps by bytes for correctness, well under any filesystem's limit.
  if new_slug.bytesize > 200
    puts t('cli.rename_too_long')
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

  # After the confirmation, before the first move. A capture written back
  # here is worse than elsewhere: `draft?(post)` reads the STALE state, so
  # a post the cron published two prompts ago is renamed as if it were a
  # draft -- no former_slugs, and the address it has been live at since
  # then dies with no redirect.
  abort_if_post_changed(path, raw, old_slug) if raw

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

  # Recovery is offered per post, not per command: text left over from
  # `edit <this slug>` continues here, text from anything else is named
  # rather than restored (see offer_editor_buffer).
  restored = offer_editor_buffer('edit', slug)
  opened_with = restored || frontmatter + body
  raw = edit_in_editor(opened_with, FRONTMATTER_HINT, { 'kind' => 'edit', 'slug' => slug })

  # Same no-op guard as cmd_add: editor closed without saving (or saved
  # untouched) means nothing to do -- skip the save and the rebuild question.
  if raw == opened_with
    # Same as cmd_add: an untouched editor wrote no buffer, so there is
    # nothing of this session's to clean up and possibly something of an
    # earlier one's to protect.
    puts t('cli.buffer_still_kept', path: EDITOR_BUFFER_PATH) if restored
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
  check_video_playback(media_files)
  fill_image_dimensions(blocks, media_files, media_dir)
  restore_posters(blocks, post['content'])
  # Before the lookup, not after it: a player the post already has is not
  # worth a network call, and asking anyway is what made an edit depend on
  # a service answering.
  restore_embed_lookups(blocks, post['content'])
  resolve_embed_lookups(blocks)

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
  #
  # The post's CURRENT address is subtracted, exactly as Publishing.publish
  # and rename_post do: a date edit that moves the post across a year keeps
  # the same slug, so "new_year/slug" would otherwise sit in its own
  # former_slugs and the build would try to redirect the live page to
  # itself -- a warning that fires on every build and no later edit clears.
  #
  # A date edit that moves a PUBLISHED post into another year also vacates
  # its old public address -- /posts/2019/slug/ stops being generated the
  # moment the post becomes /posts/2020/slug/. That is the same debt a
  # rename creates, and the stub mechanism has always been able to pay it;
  # nothing was writing the entry, so the old link just died. A draft
  # vacates nothing, exactly as in rename_post.
  vacated = new_year != year && !draft?(post) ? "#{year}/#{slug}" : nil
  former = (Array(post['former_slugs']).map(&:to_s) + [vacated].compact).uniq - ["#{new_year}/#{slug}"]
  updated['former_slugs'] = former unless former.empty?
  updated['unpublished_from'] = post['unpublished_from'] if post['unpublished_from']
  updated['redirect_from'] = post['redirect_from'] if post['redirect_from']
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
  # The ORIGINAL post's posters are read as well as the new blocks'. Since
  # restore_posters the two normally agree, but not always: a video whose
  # block has no markdown form at all (an import with no youtube_id and an
  # empty embed_html) is dropped by the round-trip, and its poster with it.
  # Keeping the file in that case is deliberate -- the author confirmed
  # losing the block, not deleting a file they can't name in markdown, and
  # a restore from trash would otherwise come back without its image.
  keep = (blocks.flat_map { |b| [b.dig('media', 0, 'url'), b.dig('poster', 0, 'url')] } +
          post['content'].map { |b| b.dig('poster', 0, 'url') }).compact.to_set

  # The post first, its unreferenced media second. Pruning ahead of the
  # write meant a failure in between left a post that still names files
  # that are already gone; this order can at worst leave a file nothing
  # references, which the next save collects.
  AtomicWrite.write_json(new_path, updated)
  if Dir.exist?(new_media_dir)
    Dir.children(new_media_dir).each do |f|
      File.delete(File.join(new_media_dir, f)) unless keep.include?(f)
    end
  end
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

  # No git, no backup elsewhere -- deleted posts go to trash/<year>/<slug>/
  # instead of straight away, so a mistake can be undone via `restore`.
  # Deleting the same year+slug a second time overwrites that version in
  # trash; trash only ever holds the most recent deletion of each post.
  #
  # Keyed by year AND slug, because content is: the same slug in two years
  # is two posts (backdating makes that ordinary), and a trash keyed by
  # slug alone made deleting the older one destroy the newer one's trashed
  # copy AND its whole media directory -- the undo for a deliberate delete,
  # gone without a word.
  trash_dir = File.join(TRASH_DIR, year, slug)
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
# Every trashed copy of a slug: the year-keyed ones, plus a flat
# trash/<slug>/ left over from an installation that deleted a post before
# the trash grew years. Both are restorable -- an upgrade must not strand
# somebody's undo.
def trashed_paths(slug)
  (Dir.glob(File.join(TRASH_DIR, '*', slug, 'post.json')) +
   [File.join(TRASH_DIR, slug, 'post.json')]).select { |f| File.file?(f) }.uniq.sort
end

# Mirrors pick_among_years, over what is in the trash rather than what is
# published: a number picks, anything else cancels.
def pick_among_trashed(slug, paths)
  readable = paths.filter_map { |f| (summary = post_summary(f)) && [f, summary] }
  abort t('cli.nothing_in_trash', slug: slug) if readable.empty?

  paths = readable.map(&:first)
  rows = readable.map { |(_, summary)| summary_row(summary) }
  puts t('cli.ambiguous_slug', slug: slug, count: paths.size)

  if Tui.interactive?
    choice = Tui.menu(rows, hint: t('cli.menu_hint_plain'))
    abort t('cli.cancelled_empty') if choice.nil?
    puts
    return paths[choice]
  end

  rows.each_with_index { |row, i| puts "#{i + 1}) #{row}" }
  puts
  print t('cli.enter_number')
  input = $stdin.gets&.strip.to_s
  puts
  abort t('cli.cancelled_empty') unless input =~ /\A\d+\z/ && (1..paths.size).cover?(input.to_i)
  paths[input.to_i - 1]
end

def cmd_restore(slug)
  found = trashed_paths(slug)
  abort t('cli.nothing_in_trash', slug: slug) if found.empty?

  # Two years of the same slug can sit in the trash at once now, so the
  # same rule as everywhere else applies: never guess, show both and ask.
  trash_json = found.size == 1 ? found.first : pick_among_trashed(slug, found)
  trash_dir = File.dirname(trash_json)

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

# A plain draft shows no date, the same rule the properties dialog
# follows: a draft's time is set by publishing or scheduling, so the
# timestamp in its JSON is bookkeeping, not a fact about the post. Dashes
# rather than blanks, so the column still lines up and reads as
# deliberately empty. A scheduled draft does have a time -- schedule gave
# it one -- and keeps showing it.
def row_date(post)
  return '----------' if post[:state] == DRAFT && !post[:scheduled]

  Time.parse(post[:date]).strftime('%Y-%m-%d')
end

def summary_row(post)
  "#{row_date(post)}  [#{post[:type]}]#{state_marker(post)}  #{post[:slug]}  #{post[:title]}"
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

# --- browsing the archive --------------------------------------------
#
# `list` prints the whole archive and scrolls it past you -- fine down a
# pipe, useless as a way to look around 4000 posts. This is the same data
# as a screen you can stay in: filters, a live search that speaks the same
# query language as the site's search box, a look at the post under the
# cursor, and Enter to open it.

# The keys this screen claims. Deliberately none of the letters that mean
# an ACTION elsewhere in the CLI -- p is "publish" in three dialogs and x
# is "delete" in two, and a key whose meaning depends on which screen you
# are looking at is a key that will eventually be pressed on the wrong
# one. Preview is the space bar, the way every file manager does it.
BROWSE_HOT_KEYS = ['/', 't', 's', 'g', 'z', ' '].freeze

# The title is what a person recognises a post by, so it goes where the
# eye lands. Over half of an imported archive has no title at all (a
# tweet, a photo) -- those show the slug instead, dimmed, because it is
# derived from the text and reads well enough to pick from. `list` keeps
# the slug-first row: on the command line the slug is the thing you copy
# into the next command.
def browse_row(post)
  title = post[:title].to_s.strip
  label = title.empty? ? Tui.paint(post[:slug], :dim) : title
  "#{row_date(post)}  [#{post[:type]}]#{state_marker(post)}  #{label}"
end

def browse_posts
  Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).filter_map do |file|
    summary = post_summary(file)
    # Keyed by year/slug, not slug: backdating makes the same slug in two
    # years easy (the archive really has such pairs), and a slug-keyed
    # index let one post's text answer searches for the other.
    summary&.merge(path: file, key: "#{File.basename(File.dirname(file))}/#{summary[:slug]}")
  end.sort_by { |post| post[:date].to_s }.reverse
end

# Built on the first search and not before it: reading and folding every
# post costs a couple of seconds on a large archive, and someone who only
# came to scroll through last month should not pay for a search they never
# ran. Keeping the plain text as well as the folded form is what lets the
# screen show WHY a post matched.
def browse_index(posts)
  Tui.spinner(t('cli.browse_indexing', count: posts.size)) do
    posts.each_with_object({}) do |summary, index|
      begin
        post = JSON.parse(File.read(summary[:path], encoding: 'utf-8'))
        text = PostText.plain(post).gsub(/\s+/, ' ').strip
        index[summary[:key]] = { text: text, folded: PostText.searchable(post, text) }
      rescue JSON::ParserError, SystemCallError
        # post_summary already warned about this file; a post that cannot
        # be read simply matches nothing.
        index[summary[:key]] = { text: '', folded: '' }
      end
    end
  end
end

def browse_state_match?(post, state)
  case state
  when 'draft' then post[:state] == DRAFT && !post[:scheduled]
  when 'scheduled' then !post[:scheduled].nil? && post[:scheduled] != false
  when 'pinned' then !!post[:pinned]
  else post[:state] != DRAFT
  end
end

def browse_filtered(posts, filters, index, tokens)
  posts.select do |post|
    next false if filters[:type] && post[:type] != filters[:type]
    next false if filters[:state] && !browse_state_match?(post, filters[:state])
    next false if filters[:tag] && post[:tags].none? { |tag| Slug.fold(tag) == Slug.fold(filters[:tag]) }
    next true if tokens.empty?

    SearchQuery.match?(index.to_h.dig(post[:key], :folded).to_s, tokens)
  end
end

def browse_status(filters, query, searching, shown, total)
  if searching
    return [t('cli.browse_searching', query: query),
            t('cli.browse_of_total', count: shown, total: total)]
  end

  parts = []
  parts << t('cli.browse_filter_type', value: filters[:type]) if filters[:type]
  parts << t('cli.browse_filter_state', value: t("cli.browse_state_#{filters[:state]}")) if filters[:state]
  parts << t('cli.browse_filter_tag', value: filters[:tag]) if filters[:tag]
  parts << t('cli.browse_filter_search', query: query) unless query.to_s.strip.empty?
  return [t('cli.browse_heading'), t('cli.browse_total', count: total)] if parts.empty?

  [t('cli.browse_filter_prefix', filters: parts.join(' · ')),
   t('cli.browse_of_total', count: shown, total: total)]
end

# Folding character by character, keeping the position each folded
# character came from -- so a hit found in the folded text can be shown
# from the original, with its diacritics and capitals intact. Whitespace
# is passed through as a single space rather than folded away, which is
# what Slug.fold does to a lone space and would otherwise glue every word
# to the next one.
def fold_with_offsets(text)
  folded = +''
  offsets = []
  text.each_char.with_index do |char, position|
    piece = char.match?(/\s/) ? ' ' : Slug.fold(char)
    piece.each_char { offsets << position }
    folded << piece
  end
  [folded, offsets]
end

# One line of the post's own text around the first word that matched --
# the answer to "why is this in my results?", which a full-text search
# owes the reader. Only ever computed for the row under the cursor, and
# cached, because folding a post character by character is not something
# to repeat on every arrow key.
def browse_context(entry, tokens, width, cache, slug)
  return nil if entry.nil? || tokens.empty?

  cache[slug] ||= begin
    text = entry[:text].to_s
    folded, offsets = fold_with_offsets(text)
    token = tokens.reject(&:negated).find { |candidate| folded.include?(candidate.text) }
    if token.nil? || text.empty?
      ''
    else
      at = offsets[folded.index(token.text)] || 0
      start = [at - 30, 0].max
      fragment = text[start, width].to_s.strip
      "#{start.positive? ? '…' : ''}#{fragment}#{start + width < text.length ? '…' : ''}"
    end
  end
  cache[slug].empty? ? nil : cache[slug]
end

def browse_pick_type(posts)
  counts = posts.group_by { |post| post[:type] }.transform_values(&:size).sort_by { |type, count| [-count, type] }
  rows = [format('%-14s %d', t('cli.browse_filter_none'), posts.size)] +
         counts.map { |type, count| format('%-14s %d', type, count) }
  index = Tui.menu(rows, hint: t('cli.browse_menu_hint'))
  return :cancel if index.nil?

  index.zero? ? nil : counts[index - 1].first
end

BROWSE_STATES = %w[published draft scheduled pinned].freeze

def browse_pick_state(posts)
  counts = BROWSE_STATES.map { |state| [state, posts.count { |post| browse_state_match?(post, state) }] }
  rows = [format('%-14s %d', t('cli.browse_filter_none'), posts.size)] +
         counts.map { |state, count| format('%-14s %d', t("cli.browse_state_#{state}"), count) }
  index = Tui.menu(rows, hint: t('cli.browse_menu_hint'))
  return :cancel if index.nil?

  index.zero? ? nil : counts[index - 1].first
end

# 1893 tags on a real archive, so this is a scrollable list of its own,
# ordered by how much of the archive each one covers -- and a tag can be
# typed instead, which is faster than arrowing to it.
def browse_pick_tag(posts)
  counts = Hash.new(0)
  posts.each { |post| post[:tags].each { |tag| counts[tag] += 1 } }
  return nil if counts.empty?

  entries = counts.sort_by { |tag, count| [-count, Slug.fold(tag)] }
  width = entries.map { |tag, _| tag.length }.max.clamp(8, 32)
  rows = [format("%-#{width}s %d", t('cli.browse_filter_none'), posts.size)] +
         entries.map { |tag, count| format("%-#{width}s %d", tag, count) }
  choice = Tui.menu(rows, hint: t('cli.browse_tag_menu_hint'), allow_text: true,
                          text_prompt: t('cli.browse_tag_prompt'))
  return :cancel if choice.nil?
  return choice.strip if choice.is_a?(String)

  choice.zero? ? nil : entries[choice - 1].first
end

# The post as its own text, wrapped to the terminal: the same markdown
# `edit` opens, so there is one answer in this engine to "what does this
# post say" rather than a second renderer to keep in step. Media lines are
# the exception -- an absolute path into media.nosync is noise in a
# preview, where the file name and the alt text are the whole point.
def browse_preview_lines(post, markdown, width)
  markdown.split("\n").flat_map do |line|
    case line
    when /\A!!\[(.*?)\]\((.*?)\)\z/
      [t('cli.browse_preview_media', file: File.basename(Regexp.last_match(2)),
                                     caption: Regexp.last_match(1).empty? ? t('cli.browse_preview_no_caption') : Regexp.last_match(1))]
    when /\A!\[(.*?)\]\((.*?)(?: "(.*)")?\)\z/
      [t('cli.browse_preview_image', file: File.basename(Regexp.last_match(2)),
                                     alt: Regexp.last_match(1).empty? ? t('cli.browse_preview_no_caption') : Regexp.last_match(1))]
    else
      wrap_to_width(line, width)
    end
  end
end

def wrap_to_width(line, width)
  return [''] if line.strip.empty?

  out = []
  current = +''
  line.split(/\s+/).each do |word|
    # A URL longer than the terminal is one "word" -- broken here rather
    # than left for the row truncation, which would hide the rest of it.
    word.scan(/.{1,#{width}}/m).each do |piece|
      if current.empty?
        current = +piece
      elsif current.length + 1 + piece.length <= width
        current << ' ' << piece
      else
        out << current
        current = +piece
      end
    end
  end
  out << current unless current.empty?
  out
end

def browse_preview(summary)
  post = JSON.parse(File.read(summary[:path], encoding: 'utf-8'))
  year = File.basename(File.dirname(summary[:path]))
  markdown = MarkdownWriter.blocks_to_markdown(post['content'], File.join(MEDIA_DIR, year, summary[:slug]))
  width = [Tui.term_width - 4, 40].max
  header = [Tui.paint(post['title'].to_s.empty? ? summary[:slug] : post['title'], :bold),
            "#{row_date(summary)}  ·  [#{summary[:type]}]#{state_marker(summary)}  ·  #{summary[:slug]}"]
  header << t('cli.browse_preview_tags', tags: post['tags'].join(', ')) unless (post['tags'] || []).empty?
  lines = header + [''] + browse_preview_lines(post, markdown, width)
  state = { selected: 0, offset: 0 }
  Tui.browse(state, keys: t('cli.browse_preview_keys'), empty: t('cli.browse_preview_empty'), cursor: false) do
    [lines, [t('cli.browse_preview_status'), '']]
  end
  puts
rescue JSON::ParserError, SystemCallError => e
  puts t('cli.unreadable_post', path: summary[:path], error: e.message.lines.first.to_s.strip[0, 100])
  puts
end

def cmd_browse(filters = {})
  # Piped runs keep the line-based list they always got: there is no
  # screen to scroll and no keys to press.
  return cmd_list(filters) unless Tui.interactive?

  posts = browse_posts
  if posts.empty?
    puts t('cli.no_posts_to_pick')
    puts
    return
  end

  active = { type: filters[:type], state: filters[:drafts] ? 'draft' : nil, tag: filters[:tag] }
  index = nil
  contexts = {}
  view = []
  state = { selected: 0, offset: 0, query: '' }

  loop do
    result = Tui.browse(state,
                        keys: t('cli.browse_keys'),
                        empty: t('cli.browse_empty'),
                        hot_keys: BROWSE_HOT_KEYS,
                        search_hint: t('cli.browse_search_keys'),
                        context: lambda { |row|
                          post = view[row]
                          post && browse_context(index.to_h[post[:key]], SearchQuery.parse(state[:query]),
                                                 [Tui.term_width - 12, 40].max, contexts, post[:key])
                        }) do |query, searching|
      tokens = SearchQuery.parse(query)
      view = browse_filtered(posts, active, index, tokens)
      [view.map { |post| browse_row(post) }, browse_status(active, query, searching, view.size, posts.size)]
    end

    break if result.nil?

    kind, value, row = result
    if kind == :enter
      selected = view[value]
      next if selected.nil?

      # Everything below prints, so the frame this screen would repaint
      # over is gone -- the next pass starts a fresh one.
      state.delete(:lines)
      puts
      post_crossroads(selected[:slug])
      Tui.pause_and_clear(t('cli.wizard_continue_prompt'))
      posts = browse_posts
      # The screen comes back with the query still active, so the index
      # must come back with it -- nilling it made every post match
      # nothing and the archive showed "(nothing matches)" for a query
      # that had results a moment earlier. Rebuilt, not kept: the edit
      # may have changed exactly the text being searched.
      index = state[:query].to_s.strip.empty? ? nil : browse_index(posts)
      contexts.clear
      next
    end

    case value
    when '/'
      # The index is built here, before the typing starts, so the wait
      # happens once and in the open rather than under the first keystroke.
      index ||= browse_index(posts)
      contexts.clear
      state[:searching] = true
    when 't', 's', 'g'
      state.delete(:lines)
      puts
      picked = case value
               when 't' then browse_pick_type(posts)
               when 's' then browse_pick_state(posts)
               else browse_pick_tag(posts)
               end
      key = { 't' => :type, 's' => :state, 'g' => :tag }.fetch(value)
      active[key] = picked unless picked == :cancel
      state[:selected] = 0
      state[:offset] = 0
      print "\e[2J\e[H"
    when 'z'
      active.each_key { |name| active[name] = nil }
      state[:query] = ''
      state[:selected] = 0
      state[:offset] = 0
      contexts.clear
    when ' '
      selected = row && view[row]
      next if selected.nil?

      state.delete(:lines)
      puts
      browse_preview(selected)
      print "\e[2J\e[H"
    end
  end
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

# Markdown has no way to write a video's poster image, so re-parsing an
# edited post hands back a video block without one -- and the content-loss
# safeguard doesn't notice, because it counts block TYPES and a video that
# stays a video looks untouched. The file itself was never at risk (the
# cleanup list reads the original blocks too, for exactly this reason), but
# the JSON quietly lost the reference to it: 52 imported videos on sean.cz
# carry a poster, and no editor of a post could have put it back.
#
# Nothing renders a poster today, which is why this was a slow leak rather
# than a visible bug -- and why it had to be fixed before a renderer starts
# using the field, not after.
#
# The key is whatever the markdown could still name: a local video's file,
# or the video's own URL for an embedded one. Those are the only parts of
# the block that survive the round-trip, so they're the only honest way to
# recognise the same video coming back.
def restore_posters(blocks, original_blocks)
  posters = {}
  Array(original_blocks).each do |b|
    key = b.dig('media', 0, 'url') || b['url']
    posters[key] ||= b['poster'] if key && b['poster']
  end
  return if posters.empty?

  blocks.each do |b|
    next if b['poster']

    poster = posters[b.dig('media', 0, 'url') || b['url']]
    b['poster'] = poster if poster
  end
end

# The player address of a Funkwhale/Bandcamp embed, carried over from the
# stored post the same way a poster is -- and for the same reason: markdown
# cannot express it, so the round-trip hands back a block without it.
#
# Without this the re-lookup that follows decides whether a WORKING player
# survives an ordinary edit, and that lookup can fail for reasons that have
# nothing to do with the post: a laptop on a train, a service having a bad
# minute. Adding a sentence to a post then deleted its player, and the
# message said "editing and saving again retries" while doing the opposite.
# A block that never had a player still has none here, so its lookup runs
# as before.
def restore_embed_lookups(blocks, original_blocks)
  stored = {}
  Array(original_blocks).each do |block|
    url = block['url'].to_s
    stored[url] ||= block['embed_src'] if !url.empty? && block['embed_src']
  end
  return if stored.empty?

  blocks.each do |block|
    next if block['embed_src']

    src = stored[block['url'].to_s]
    block['embed_src'] = src if src
  end
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
  ['queue', t('cli.wizard_menu_queue')],
  ['browse', t('cli.wizard_menu_browse')],
  ['restore', t('cli.wizard_menu_restore')],
  ['rebuild', t('cli.wizard_menu_rebuild')]
].freeze

# The wizard's one post-shaped entry: pick a post, then choose between
# its text and its properties. Enter goes straight to the editor, so the
# common path costs a single extra keypress; the CLI pays nothing --
# `./blog.sh edit` skips this crossroads entirely and `props` is its own
# command.
def wizard_post_entry
  post_crossroads(pick_slug_interactively)
end

# The crossroads itself, reached from the wizard's post entry and from
# Enter in the archive browser -- both have a post in hand at that point
# and the same two things to do with it.
def post_crossroads(slug)
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
  when 'queue' then cmd_queue
  when 'restore' then cmd_restore(pick_trash_interactively)
  when 'browse' then cmd_browse({})
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
      index = Tui.menu(WIZARD_MENU.map { |_, desc| desc },
                       hint: t('cli.wizard_menu_hint', count: WIZARD_MENU.size))
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
  when 'queue'
    cmd_queue
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
  when 'list', 'browse'
    filters = {}
    ARGV.each do |arg|
      filters[:type] = Regexp.last_match(1) if arg =~ /\A--type=(.+)\z/
      filters[:tag] = Regexp.last_match(1) if arg =~ /\A--tag=(.+)\z/
      filters[:drafts] = true if arg == '--drafts'
    end
    # Same filters, two ways to read the answer: `list` prints it,
    # `browse` puts you inside it. Down a pipe they are the same command,
    # because a screen you can't press keys in is just a list.
    command == 'browse' ? cmd_browse(filters) : cmd_list(filters)
  when 'help'
    print_usage
  when 'version', '--version', '-v'
    puts "blog.sh #{BlogSh::VERSION}"
  else
    print_usage
    exit 1
  end
end
