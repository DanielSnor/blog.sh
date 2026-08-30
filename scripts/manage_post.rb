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
require 'stringio'
require_relative '../lib/post_writer'
require_relative '../lib/post_versions'
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
require_relative '../lib/post_address'
require_relative '../lib/address_guard'
require_relative '../lib/publishing'
require_relative '../lib/run_lock'
require_relative '../lib/publish_slots'
require_relative '../lib/path_glob'
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
  "#{SITE_BASE_URL.to_s.chomp('/')}#{draft_path(post)}"
end

def published_url(slug, year, page: false)
  "#{SITE_BASE_URL.to_s.chomp('/')}#{published_path(slug, year, page: page)}"
end

# The site-relative halves, split off so the local-preview hint below can
# put the SAME page under a different origin. Split rather than derived by
# string surgery on the finished URL: a base_url that itself contained
# "/posts/" would make that surgery cut in the wrong place.
def draft_path(post)
  "/draft/#{post['draft_token']}/#{post['slug']}/"
end

# A page is served at the root, without a year -- so every message built
# from a year told the author about an address the site never answered at,
# and a rename recorded a redirect from one.
def published_path(slug, year, page: false)
  page ? "/#{slug}/" : "/posts/#{year}/#{slug}/"
end

# An install that never answered "where does this go?" still carries the
# template's address, so every URL printed above says example.com -- a
# domain the author does not own and cannot open. doctor already names
# this state (base_url_placeholder) and the two have to agree on what
# counts as it, hence the same literal comparison.
PLACEHOLDER_BASE_URL = 'https://example.com'

def placeholder_base_url?
  SITE_BASE_URL.to_s.chomp('/') == PLACEHOLDER_BASE_URL
end

# `./blog.sh preview` serves the build on 8000 unless told otherwise. The
# number is repeated here rather than shared with that command on purpose:
# what this prints is the address of the DEFAULT invocation, which is the
# one the hint is telling somebody to run.
LOCAL_PREVIEW_PORT = 8000

# Printed under a preview or a publish line, and only where the canonical
# address is still the template's: on a real site that address IS the
# answer, and a second one under every post would be noise.
def puts_local_preview_hint(site_path)
  return unless placeholder_base_url?

  puts Tui.paint(t('cli.local_preview_hint', url: "http://localhost:#{LOCAL_PREVIEW_PORT}#{site_path}"), :dim)
end

# --- frontmatter ------------------------------------------------------
#
# Both directions of the markdown round-trip live in lib/: text -> blocks
# in lib/markdown_parser.rb (shared with build_blog.rb), blocks -> markdown
# in lib/markdown_writer.rb (used by `blog.sh edit` below). What stays here
# is authoring validation tied specifically to this CLI.

FRONTMATTER_KEYS = %w[title tags type date pinned hero page unlisted series series_part toc].freeze

# What the site does with lead images when a post says nothing. Read here
# so the header can show a post's effective answer rather than a blank.
SITE_HERO = SiteConfig.get('layout', 'hero', default: false)

# A key the parser doesn't know is silently dropped -- `pined: true` would
# do nothing at all and never say so. Every key the author typed is checked
# against the list above, and an unknown one stops the save while the text
# is still recoverable (the editor buffer holds it).
def abort_on_unknown_frontmatter(meta)
  unknown = meta.keys.reject { |k| FRONTMATTER_KEYS.include?(k.to_s) }
  return if unknown.empty?

  abort t('cli.unknown_frontmatter_key', keys: unknown.join(', '), known: FRONTMATTER_KEYS.join(', '))
end

# `unlisted` and `page` are NOT read with this: they decide whether a post
# is exposed, and PostAddress.flag? is the loose rule the build judges them
# by. Answering the same question two ways is how an edit turned a hidden
# post public. `pinned`, `hero` and `toc` stay strict on purpose -- a typo
# that fails to pin or fails to draw a table of contents costs nothing.
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
  left = []
  (media_files.keys + extra_sources).each do |src|
    next unless src

    expanded = File.expand_path(src)
    next unless expanded.start_with?("#{File.expand_path(INCOMING_DIR)}/")
    next unless File.exist?(expanded)

    begin
      File.delete(expanded)
    rescue SystemCallError
      # Deleting needs write permission on the DIRECTORY, not on the file,
      # so an incoming/ owned by whoever uploads into it (a separate SFTP
      # account is the usual arrangement) refuses this to the account that
      # runs the CLI. The comment at the call site has always said this
      # must not abort a save that already succeeded -- it now does not.
      left << File.basename(expanded)
    end
  end
  return if left.empty?

  # Said out loud rather than swallowed: "an empty incoming/ means nothing
  # is pending" is the whole point of the tidying, and a file left behind
  # quietly makes that untrue.
  warn t('cli.incoming_not_cleaned', files: left.join(', '))
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
  # The LENGTH of the run that opened the current block, or nil outside one.
  # This used to be a boolean flipped by any line starting with ```, which
  # counts parity rather than matching CommonMark's rule that a fence closes
  # only on a run at least as long as the one that opened it. MarkdownWriter
  # relies on that rule -- fence_for wraps a sample containing ``` in a
  # four-backtick fence -- so the two inner ``` lines of a perfectly
  # ordinary post about markdown flipped the tracker back to "outside", and
  # every // line between them was deleted as an author's note. Which is
  # exactly what the comment above says this function exists to prevent.
  fence = nil
  in_comment = false

  text.each_line do |line|
    run = line.lstrip[/\A`{3,}/]&.length
    if fence
      # A closing fence carries nothing after it; an opening one may carry
      # an info string (```js), which is why the tail is checked here only.
      fence = nil if run && run >= fence && line.lstrip[run..].to_s.strip.empty?
      kept << line
      next
    end
    if run
      fence = run
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
    # The one line starting with // that is content rather than an
    # instruction: it marks where the teaser stops and the body begins, so
    # the rule that keeps notes out of posts must not eat it. Matched
    # against the parser's own pattern rather than a second copy of the
    # string -- two definitions of the same marker is one too many.
    if MarkdownParser::TEASER_END_RE.match?(line.strip)
      kept << line
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
# The value the `hero:` line should show, or nil for "don't offer the key".
# A post that carries the field keeps it visible whatever the site does:
# the header is what the save is rebuilt from, so a line left out is a
# field deleted -- and this one arrived in a release where it was neither
# in the header nor in the list of fields a save carries over, which meant
# editing a post silently gave it back the site's answer.
def hero_frontmatter_value(post)
  own = post.key?('hero') ? truthy_frontmatter?(post['hero']) : nil
  return own unless own.nil?

  SITE_HERO ? true : nil
end

PAGE_TYPE = 'page'

# `type: page` is how a page is written, because that is how it is thought
# about: a page is a kind of post, not a flag on one. Inside it stays the
# `page` field, and the content TYPE stays derived -- a page never appears
# in a /type/ listing, so it has no use for one.
#
# `page: true` is still read, so pages written before this keep working
# and an import that sets the field needs no translation.
def frontmatter_type_and_page(meta)
  type = meta['type'].to_s.strip
  return [nil, true] if type.casecmp(PAGE_TYPE).zero?

  [type.empty? ? nil : type, PostAddress.flag?(meta['page'])]
end

# The tag list as one frontmatter line, and back off it.
#
# The comma is both the separator and a character a tag may legitimately
# contain, so a tag with one in it came back as TWO tags on the next save
# -- no warning, no confirmation, and no way back through the CLI. Six
# posts in the author's own live archive carry such a tag.
#
# Quoted on the way out only when it has to be: the line is a thing people
# edit by hand, and `tags: kolo, vylety` must stay that. On the way in a
# quoted run is one tag whatever is inside it, and everything else splits
# on commas exactly as before.
def tags_to_frontmatter(tags)
  Array(tags).map do |tag|
    text = tag.to_s.strip
    text.include?(',') ? %("#{text.gsub('"', '\\"')}") : text
  end.join(', ')
end

def tags_from_frontmatter(value)
  text = value.to_s
  tags = []
  current = +''
  in_quotes = false
  i = 0
  # Walked rather than split on a regex: with an alternation, `[^,]+`
  # matches from the space before an opening quote and the quoted branch
  # never gets a look in. A dozen lines that are obviously right beat
  # three that are nearly.
  while i < text.length
    char = text[i]
    if in_quotes && char == '\\' && text[i + 1] == '"'
      current << '"'
      i += 2
      next
    elsif char == '"'
      in_quotes = !in_quotes
    elsif char == ',' && !in_quotes
      tags << current.strip
      current = +''
    else
      current << char
    end
    i += 1
  end
  tags << current.strip
  tags.reject(&:empty?)
end

def build_frontmatter(title:, tags:, type:, pinned: nil, hero: nil, page: nil,
                      unlisted: nil, series: nil, series_part: nil, toc: nil)
  lines = ['---']
  lines << "title: #{title}"
  lines << "tags: #{tags}"
  # A page says so on the type line, which is where somebody looks to find
  # out what kind of thing they are editing -- and it is the only line it
  # needs, since a page's content type is never used.
  lines << "type: #{page ? PAGE_TYPE : type}" if page || type
  # Only shown when the post already carries it: a key that appears on
  # every new post would suggest pinning is part of writing one, when it
  # is a decision about an existing post.
  lines << "pinned: #{pinned}" unless pinned.nil?
  # Same rule, one reason further: the site-wide layout.hero already
  # decides this for every post, so the line is worth showing only where
  # it can actually be acted on -- a site that uses heroes, or a post that
  # has already said something of its own.
  lines << "hero: #{hero}" unless hero.nil?
  # Same rule as the pin: shown with its current value so the state can be
  # read as well as changed, and left off a draft that has not claimed it
  # -- a draft is unlisted already, by being a draft.
  lines << "unlisted: #{unlisted}" unless unlisted.nil?
  lines << "series: #{series}" unless series.nil?
  lines << "series_part: #{series_part}" unless series_part.nil?
  lines << "toc: #{toc}" unless toc.nil?
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
def announce_post(post, year:, date:, force: false)
  # An unlisted post is not announced, and force does not open this door the
  # way it opens the backdating one. The whole point of `unlisted` is a post
  # that exists at its address for the handful of people you send the link
  # to: it is out of the listings, the feeds, the sitemap and the search
  # index, and putting its URL into a public timeline undoes all four in one
  # go. There is no half-measure worth having here -- an announcement cannot
  # be taken back once a server has it, so the rule is the same whether the
  # post is published by hand or by cron, which has nobody to ask.
  #
  # To announce such a post, take the flag off first. That is one edit, and
  # it makes the decision explicit rather than a side effect of publishing.
  if Publishing.unlisted?(post)
    warn t('cli.unlisted_no_toot')
    return nil
  end

  if SITE_BASE_URL.to_s.empty?
    warn t('cli.base_url_missing_toot')
    return nil
  end

  # The one path that used to say nothing. Publishing.announce is a `case`
  # over the configured network, so with neither section it matched no
  # branch and returned nil -- and the callers, which cannot tell "did not
  # try" from "tried and failed", printed "Failed to send the toot (see
  # above)" over an empty screen. A reader who has just filled in an
  # instance and a token believes the config and starts reading the
  # engine's source instead, which is exactly what the first person to hit
  # this did. The reason is knowable here, so it gets said here.
  if SiteConfig.comment_network.nil?
    warn t('cli.no_network_toot')
    return nil
  end

  if !force && !Publishing.within_recency_window?(date)
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
  template = restored || build_frontmatter(title: '', tags: '', type: '') + "#{t('cli.template_body_placeholder')}\n"
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

  date = meta['date'].to_s.empty? ? Time.now : parse_frontmatter_date!(meta['date'])
  title = meta['title'].to_s.empty? ? nil : meta['title']
  tags = tags_from_frontmatter(meta['tags'])
  type, page = frontmatter_type_and_page(meta)

  blocks, media_files, missing = MarkdownParser.parse_body(body, nil, incoming_dir: INCOMING_DIR)
  wait_for_missing_images(missing)
  heic_consumed = convert_heic_attachments(blocks, media_files)
  check_attachment_sizes(media_files)
  check_video_playback(media_files)
  resolve_embed_lookups(blocks)
  fill_image_dimensions(blocks, media_files)

  slug_source = title || (blocks.find { |b| b['type'] == 'text' } || {})['text']
  slug = Slug.slugify(slug_source.to_s.split(/\s+/).first(8).join(' '))
  # Eight words is a readability cap, not a length one: a post whose first
  # words are a long URL slugifies into a single enormous token, and the
  # write then died with a raw ENAMETOOLONG backtrace -- after the media
  # directory had been created, leaving it orphaned. rename_post has
  # capped by bytes all along; this is the same limit, cut on a word
  # boundary where there is one.
  if slug.bytesize > 200
    slug = slug[0, 200]
    slug = slug.sub(/-[^-]*\z/, '') if slug.rindex('-')&.>(120)
    slug = slug.sub(/-+\z/, '')
  end
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
  # The address as well as the file: a new post is a draft, served under
  # its token, but the day it publishes it takes /posts/<year>/<slug>/ --
  # and a post whose FILE sits in another year can already be served
  # there. Walking on to the next serial is the whole fix; nobody has to
  # be told, because the name was never promised to anyone yet.
  while File.exist?(File.join(CONTENT_DIR, date.year.to_s, "#{slug}.json")) ||
        Dir.exist?(File.join(MEDIA_DIR, date.year.to_s, slug)) ||
        AddressGuard.occupant({ 'slug' => slug, 'date' => date.iso8601 },
                              content_dir: CONTENT_DIR, slug: slug)
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
  # Was not read here at all before: a page could only be made by editing
  # one into existence, never by writing one.
  post['page'] = true if page
  post['pinned'] = true if truthy_frontmatter?(meta['pinned'])
  post['unlisted'] = true if PostAddress.flag?(meta['unlisted'])
  # The same four keys edit_post persists, under the same rules -- the
  # editor template offers them here too, and a key the editor offers must
  # not vanish on the first save only to start working on the second. The
  # series name is written as typed (its address slug is derived at build
  # time), the part is an integer override for out-of-order publishing,
  # and hero/toc are presence-based: only stored where they carry an
  # opinion of their own.
  post['series'] = meta['series'].to_s.strip unless meta['series'].to_s.strip.empty?
  part = Integer(meta['series_part'].to_s.strip, exception: false)
  post['series_part'] = part if part
  if meta.key?('hero')
    hero_wanted = truthy_frontmatter?(meta['hero'])
    post['hero'] = hero_wanted unless hero_wanted == SITE_HERO
  end
  post['toc'] = truthy_frontmatter?(meta['toc']) if meta.key?('toc') && !meta['toc'].to_s.strip.empty?

  # The slug was settled before the editor opened, when nobody yet knew
  # whether this would be a page -- and a page is served at the root, where
  # the year in the file name buys it nothing. Walk on to the next serial
  # now that the answer is in, so that the write below never has to refuse.
  if PostAddress.page?(post)
    base = post['slug']
    serial = 2
    while AddressGuard.occupant(post, content_dir: CONTENT_DIR, slug: post['slug'])
      post['slug'] = "#{base}-#{serial}"
      serial += 1
    end
  end

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

  draft_decision_loop(final_slug, path: path)
end

# After every draft change, it builds and deploys without asking -- the
# preview has to be on the live site, or it couldn't be opened from an iPad,
# which is the whole point.
def draft_decision_loop(slug, path: nil)
  known_path = path
  if SITE_BASE_URL.to_s.empty?
    warn t('cli.base_url_missing_preview')
    warn ''
    return
  end

  loop do
    # The caller's own path when it still exists: `add` and `unpublish`
    # have the file in hand, and a second post sharing the slug in another
    # year would otherwise drop the author into the ambiguous-slug picker
    # -- over a post they did not choose and have not seen yet, which for
    # `add` ended the command with exit 1 instead of the draft dialog.
    path = known_path && File.exist?(known_path) ? known_path : find_post_path(slug)
    return unless path

    # The bytes are kept, not just the parsed post: this dialog then waits
    # on a keypress, and the scheduled-publish cron runs every 15 minutes.
    # [s] below hands them to prompt_and_schedule so write_scheduled_date
    # can refuse to write a capture the cron has already overtaken --
    # without them it would revert a published post to a draft and drop
    # the announcement URL. Every other scheduling path passes this; this
    # was the one that did not.
    raw = File.read(path, encoding: 'utf-8')
    post = JSON.parse(raw)
    return unless draft?(post)

    # No extra `puts` before "Preview:" -- rebuild_and_deploy (called right
    # before this, whether from cmd_add or the 'e' branch below) already
    # ended with a blank line after "Done:", so another one would double up.
    puts Tui.paint(t('cli.preview_label', url: draft_url(post)), :cyan)
    puts_local_preview_hint(draft_path(post))
    # No QR under a placeholder address: the code is there to carry the
    # draft to a phone, and a phone that scans example.com lands on a
    # domain this author does not own. A localhost code is no better --
    # it resolves to the phone itself.
    if Tui.interactive? && !placeholder_base_url? && (qr = QrCode.render(draft_url(post)))
      puts
      puts qr
      puts Tui.paint(t('cli.qr_hint'), :dim)
    end
    puts
    slot = next_publish_slot(slug)
    prompt = slot ? t('cli.what_next_prompt_slot', slot: slot.strftime(t('date_time_format'))) : t('cli.what_next_prompt')
    case Tui.key_choice(prompt)
    # Every action gets the path the dialog is SHOWING. Re-resolving by
    # slug here meant the screen could describe one post while the
    # keystroke acted on another -- two drafts sharing a slug in different
    # years is ordinary, and the dialog is where the author decides.
    when 'p' then return publish_draft(slug, path: path)
    when 'e' then edit_post(slug, path: path)
    when 's'
      puts
      # == true: :busy already said why nothing happened, and the dialog
      # coming back around is the retry.
      return if prompt_and_schedule(path, post, raw: raw) == true
    when 'd', ''
      puts
      puts t('cli.left_as_draft', slug: slug)
      puts
      return
    when 'x'
      next unless delete_post(slug, path: path)

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
# scheduled, false on cancel (an unreadable date re-asks in place rather
# than answering false -- both callers used to treat a typo differently,
# and only one of them by design), and :busy when a running publish holds
# the queue. No preview rebuild on the way out: the entered date shows on
# pages the publication regenerates anyway, and the middle of three builds
# on the road to "post tonight" was the one a beginner paid for nothing.
#
# No leading blank line here: the two callers arrive with different things
# above them. pick_from_list already ends with one, while the dialog's
# key_choice leaves the cursor right under the echoed keypress -- so that
# branch prints its own.
# Times already claimed by scheduled drafts, so the next offer skips
# them -- that is what turns a set of slots into a queue.
def scheduled_entries(except_slug: nil)
  PathGlob.under(CONTENT_DIR, '*', '*.json').filter_map do |file|
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

def prompt_and_schedule(path, post, raw: nil)
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
      # The road to an EARLIER slot, said exactly where the author is
      # looking at a full queue and an offer a month out. The two-step is
      # by design (the queue owns the ordering), but a design nobody
      # mentions at this prompt reads as "the queue is full, tough luck".
      puts Tui.paint("   #{t('cli.schedule_queue_hint')}", :dim)
      puts
    end
  end
  # NOT `raw = ...`: this method's raw: keyword is the file's bytes as
  # they looked before the dialog opened -- the staleness guard's whole
  # evidence. Reusing the name here once overwrote that capture with the
  # typed date line, and the guard then compared the post file against
  # the answer "2026-12-24 08:00", failed by construction, and every
  # scheduling path in the CLI aborted with "changed on disk".
  # A loop, not one attempt: a typo in the date used to END the standalone
  # command (exit 0, post untouched) while the draft dialog's [s] asked
  # again -- but only because its menu happens to loop. Two behaviours for
  # the same question; now the question itself re-asks until it gets a
  # date, a cancel, or the end of input.
  date = nil
  loop do
    if slot
      puts t('cli.schedule_slot_keys', cancel_word: t('cli.cancel_word'))
      print '> '
    else
      print t('cli.schedule_date_prompt')
    end
    answer = $stdin.gets
    # EOF is not Enter. With an offer on screen an empty line accepts, and
    # Ctrl-D (or a piped run whose input ran out) would otherwise schedule
    # and announce a post nobody confirmed -- and inside a loop it would
    # re-ask forever.
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
      next
    end
    if date <= Time.now
      puts t('cli.schedule_date_not_future')
      # An offer can expire mid-dialog: the slot is computed before the
      # loop, and a long hesitation (or a slot minutes away) leaves
      # [Enter] advertising a time this guard now refuses -- every press
      # of it, forever. Recomputed from the same entries: their times
      # only aged, and a queue changed underneath is caught at the write.
      if input.empty? && slot
        slot = next_publish_slot(post['slug'], entries)
        puts t('cli.schedule_slot_offer', slot: slot.strftime(t('date_time_format'))) if slot
      end
      date = nil
      next
    end

    break
  end

  # :busy, distinct from false: false means the author declined or the
  # input did not parse, and the standalone command answers that with
  # exit 0. A publish holding the lock is neither -- the caller whose
  # exit code somebody scripts against answers it with BUSY_EXIT, like
  # cmd_rebuild has since the lock existed.
  return :busy if write_scheduled_date(path, post, date, raw: raw).nil?

  # No preview rebuild here any more: scheduling a post written this
  # session used to build and deploy the site a SECOND time only to
  # stamp a new date on a draft preview the publication throws away --
  # the add-time build already shows the content, and the cron's build
  # ships the real page. The queue screen never rebuilt here either.
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
  # Before everything else, the record on the post itself: an announcement
  # that already exists is never repeated from here -- not by publish, not
  # by the standalone toot/bluesky commands, which all arrive through this
  # method. A second one does not replace the first, it strands the
  # replies under it; unpublish keeps the address on the post for exactly
  # this check to find (its own message promises that publishing again
  # will not add a second one -- this is where that promise is kept, and
  # it used not to be kept anywhere). Wanting a fresh announcement anyway
  # is expressed by deleting the address fields from the post's JSON: an
  # edit deliberate enough to mean it.
  if Publishing.announced?(post)
    warn t('cli.announcement_exists', url: Publishing.announcement_url(post))
    return nil
  end

  # Before the question, not after it: with no network there is nothing the
  # answer could change, and being asked to confirm an announcement that
  # cannot happen -- then being told it did not happen -- is two screens of
  # ceremony over one missing section. announce_post keeps the same guard
  # for any future caller that does not come through here.
  if SiteConfig.comment_network.nil?
    warn t('cli.no_network_toot')
    return nil
  end

  force = false
  unless Publishing.within_recency_window?(date)
    answer = Tui.key_choice(t('cli.date_outside_window_prompt', date: date.strftime(t('date_format'))))
    # Saying no here is a decision, and it used to be reported as a
    # failure: the question scrolled away, "Failed to send the toot (see
    # above)" took its place, and above it was the question the author had
    # just answered. It says what happened instead.
    unless Tui.yes?(answer)
      warn t('cli.toot_declined')
      return nil
    end

    force = true
  end

  announce_post(post, year: year, date: date, force: force)
end

# `path:` names the exact post when the caller already has it. The queue
# holds one row per scheduled post, and two of them can share a slug in
# different years -- looking the post up by slug again would publish, and
# ANNOUNCE, whichever the lookup preferred rather than the row the author
# picked.
def publish_draft(slug, path: nil)
  path ||= find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  unless draft?(post)
    puts t('cli.already_published', slug: slug, url: published_url(slug, post_time!(post).year))
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
  future = post_time!(post) > Time.now
  untouched = future || (post['created_at'] && post['date'] == post['created_at'])
  date = untouched ? Time.now : post_time!(post)
  puts(untouched ? t('cli.publish_date_now', date: date.strftime(t('date_time_format')))
                 : t('cli.publish_date_kept', date: date.strftime(t('date_time_format'))))

  new_year = date.year.to_s
  # Written BEFORE anything is published, the way scripts/publish_scheduled.rb
  # has done it since 1.3 and for the same reason. This path used to write it
  # only if the build or the deploy RETURNED a failure -- so a signal, an OOM
  # kill or a closed SSH session during the build, which is minutes on a large
  # archive, left the post published on disk, the toot live and unrecallable,
  # the page never uploaded, and nothing anywhere recording the debt. The next
  # tick found nothing due, no marker, and exited 0 in silence. The marker
  # means "the site owes a deploy", which is true from the moment there is
  # something to publish -- not from the moment something goes wrong.
  Publishing.mark_deploy_pending
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
  puts_local_preview_hint(published_path(slug, new_year))
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

  # The slug is a name, not a pattern -- see PathGlob.literal. Without it
  # every command that resolves a post by slug ("foto[1]", which a hand
  # edit or an import can mint) answered "post not found" over a post the
  # build was publishing.
  matches = PathGlob.under(CONTENT_DIR, '*', "#{PathGlob.literal(slug)}.json").sort
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

  # If only one copy could be read, there is nothing to choose between --
  # the "ambiguity" is with a file nothing can read, which post_summary has
  # already reported. Use the readable one rather than asking "which of the
  # 1?" and calling it years.
  if readable.size == 1 && paths.size > 1
    warn t('cli.ambiguous_one_readable', slug: slug)
    return readable.first.first
  end

  paths = readable.map(&:first)
  rows = readable.map { |(_, summary)| summary_row(summary) }
  question = t('cli.ambiguous_slug', slug: slug, count: paths.size)

  if Tui.interactive?
    # The question goes INTO the frame. Printed above it, as it used to be,
    # the frame would paint straight over it.
    choice = Tui.menu(rows, header: [question, ''],
                            hint: t('cli.menu_hint_plain', count: [rows.size, 9].min))
    abort t('cli.cancelled_empty') if choice.nil?
    puts
    return paths[choice]
  end

  puts question

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

  # No own already-announced check: announce_on_publish below carries it,
  # for every caller alike -- and unlike the truthy test that used to sit
  # here, it is not fooled by an empty string into refusing a first toot,
  # and not blind to an announcement living on the other network.
  # The year of the ADDRESS, not of the folder. A post whose date was
  # corrected across a year keeps its file where it was -- the engine says
  # so in half a dozen comments -- and the announcement is public and
  # cannot be edited afterwards, so getting it from the folder meant a
  # permanent link into nothing.
  date = post_time!(post)
  year = PostAddress.date_year(post)
  fields = announce_on_publish(post, year, date)
  # false means the network was asked and said no -- the poster has already
  # printed what it heard, so "see above" has an above. nil means nobody
  # was asked, and whichever guard declined to ask said why: unlisted, no
  # base URL, no network configured, a date outside the window the author
  # then refused. Printing "Failed" over those is a second, wrong answer to
  # a question already answered -- and over the silent ones it was the only
  # answer, pointing at nothing.
  if fields == false
    warn t('cli.toot_failed')
    warn ''
    return
  elsif fields.nil?
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

  # announced?, not a bare bluesky_url test: a post whose announcement
  # lives on Mastodon must refuse here too (a second thread on a second
  # network strands the first all the same), and the recovery lookup
  # below is for posts with NO announcement on record -- running it over
  # one that has an address would be a network call asking a question the
  # post already answers.
  if Publishing.announced?(post)
    puts t('cli.announcement_exists', url: Publishing.announcement_url(post))
    puts
    return
  end

  # The address year again, not the folder's: what goes out in a toot is
  # public and cannot be corrected afterwards.
  date = post_time!(post)
  year = PostAddress.date_year(post)

  # Before sending: is one already out there? This command runs precisely
  # when the post carries no announcement address -- which means either
  # none was ever sent, or one was sent and the reply never came back. The
  # second case used to end with two announcements of the same post.
  # The address the announcement carries is the one it is found by later,
  # so this has to ask the same question the announcement asked.
  # BOTH shapes for a page: until 1.4 an announcement carried
  # /posts/<year>/<slug>/ even for a page, so looking only for the address
  # a page has today would miss the announcement that is actually out
  # there -- and the post would be announced a second time.
  candidates = [Publishing.post_url(post['slug'], year, page: PostAddress.page?(post))]
  candidates << Publishing.post_url(post['slug'], year, page: false) if PostAddress.page?(post)
  if (found = candidates.uniq.filter_map { |url| BlueskyPoster.find_announcement(url) }.first)
    updated = post.merge('bluesky_url' => found[:url], 'bluesky_uri' => found[:uri])
    AtomicWrite.write_json(path, updated)
    puts t('cli.bluesky_recovered', url: found[:url])
    puts
    return
  end

  fields = announce_on_publish(post, year, date)
  # Same contract as `toot` above: false was refused by the network, nil was
  # never attempted and said why.
  if fields == false
    warn t('cli.bluesky_failed')
    warn ''
    return
  elsif fields.nil?
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
    puts t('cli.already_published', slug: slug, url: published_url(slug, post_time!(post).year))
    puts
    return
  end

  # The one path into the draft dialog that never built: add, edit and
  # unpublish all rebuild before it, so the Preview line the dialog prints
  # points at a page that exists. A draft that arrived by import or by a
  # hand-written JSON had a dead preview here -- and since scheduling
  # stopped rebuilding, nothing later covered for it. Built only when the
  # page is actually missing: a build is the expensive step on a large
  # archive, and the ordinary publish-after-edit walk has already paid it.
  # A draft without a token has no preview address to be dead; the build
  # would not conjure one.
  token = post['draft_token'].to_s
  unless token.empty? ||
         File.exist?(File.join(ROOT, 'public.nosync', 'draft', token, slug, 'index.html'))
    rebuild_and_deploy(t('cli.generating_preview'))
  end

  draft_decision_loop(slug, path: path)
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
    # The same exit code cmd_rebuild answers a held lock with: somebody
    # scripting `blog.sh schedule` must not read "a publish was in the
    # way" as "unscheduled". In the wizard the SystemExit is caught like
    # every other cmd_* abort.
    exit RunLock::BUSY_EXIT unless unschedule_post(path, post, slug, raw: raw)
    return
  end

  # The bytes from before the prompt ride along, so the cron publishing
  # this exact post mid-dialog is caught -- the same guard every other
  # path into scheduling already carries.
  exit RunLock::BUSY_EXIT if prompt_and_schedule(path, post, raw: raw) == :busy
end

# Shared by the CLI toggle above and the [n] action in the properties
# dialog -- the wizard lost the standalone `schedule` menu item, so
# without this the dialog could plan a post but never change its mind.
# `raw:` for the same reason write_scheduled_date takes it: this writes a
# captured post back after a prompt, and the cron may have published it in
# the meantime.
def unschedule_post(path, post, slug, raw: nil)
  # Same lock as write_scheduled_date above, same reason: the capture this
  # writes back must not overwrite what a mid-dialog tick just published.
  held = RunLock.hold(ROOT, label: 'queue') do
    abort_if_post_changed(path, raw, slug) if raw
    updated = post.dup
    updated.delete('scheduled')
    AtomicWrite.write_json(path, updated)
  end
  # false, not a bare return: the queue screen decides whether to offer
  # compacting the slots behind this post by this answer, and a decline
  # that returned the same nil as success once shifted the queue onto a
  # slot the refused unschedule never freed -- two posts on one time,
  # published (and announced) by a single tick.
  if held == RunLock::BUSY
    warn t('cli.queue_busy')
    warn ''
    return false
  end

  puts t('cli.unscheduled_label', slug: slug)
  puts
  true
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
# The byte compare above is only half the guard: the compare and the write
# have to sit under the same lock the cron takes, or a tick landing between
# them writes the capture back over a post the tick just published -- the
# queue screen has held it since the lock existed, and this is the [s]
# dialog's and the standalone schedule's turn. Reentrant under
# apply_queue_moves (RunLock.hold yields straight through for a holder), so
# the queue screen pays nothing for it. Returns nil without writing when a
# publish is running; callers treat that like any other declined prompt.
def write_scheduled_date(path, post, date, raw: nil, slug: nil)
  held = RunLock.hold(ROOT, label: 'queue') do
    abort_if_post_changed(path, raw, slug || post['slug']) if raw
    updated = post.merge('date' => date.iso8601, 'scheduled' => true)
    new_year = date.year.to_s
    new_path = File.join(CONTENT_DIR, new_year, "#{post['slug']}.json")
    # Asked whether or not the file moves: a date that stays inside the
    # year can still land the post on an address another post is served
    # at, and the old guard only looked when the folder changed.
    taken = AddressGuard.occupant(updated, content_dir: CONTENT_DIR,
                                  slug: post['slug'], except: path, path: new_path)
    abort t('cli.post_already_exists', slug: post['slug'], path: taken) if taken

    if File.expand_path(new_path) != File.expand_path(path)

      FileUtils.mkdir_p(File.dirname(new_path))
      Publishing.relocate_media(post['slug'], File.basename(File.dirname(path)), new_year)
      AtomicWrite.write_json(new_path, updated)
      File.delete(path)
    else
      AtomicWrite.write_json(new_path, updated)
    end
    new_path
  end
  if held == RunLock::BUSY
    warn t('cli.queue_busy')
    return nil
  end

  held
end

# --- the queue screen -------------------------------------------------

# Every scheduled draft in publish order, with everything an action needs
# in hand. Re-collected before every redraw on purpose: the scheduled-
# publish cron runs every 15 minutes, and a post it published mid-session
# must drop out of the list rather than get swapped around as a stale
# copy.
def queue_entries
  PathGlob.under(CONTENT_DIR, '*', '*.json').filter_map do |file|
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
#
# `initial:` is where the cursor opens. Piped input ignores it, the same
# way it ignores every other cursor: there the row is named by number.
def queue_pick(entries, initial: 0)
  rows = entries.each_with_index.map { |entry, i| queue_row(entry, i) }
  return Tui.menu(rows, hint: t('cli.queue_menu_hint'), initial: initial) if Tui.interactive?

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
# PROTOTYPE (13 Aug 2026): the queue as a screen that stays put instead of
# a dialog that reprints itself. Every keypress used to leave another full
# copy of the queue in the scrollback -- twenty rows, a hint line and an
# action row, again and again, so five moves buried the terminal in five
# identical screens. Here the frame is repainted over itself and the
# terminal never scrolls.
#
# Deliberately NOT the alternate screen: see Tui.frame. The last frame
# stays on screen when the queue is left, and everything above it survives.
#
# What is prototype-grade and would need deciding before this spreads to
# the other screens:
#   * the size is re-read on every repaint, so a window resized WHILE the
#     screen waits for a key straightens out on the next keypress rather
#     than immediately -- no SIGWINCH handler yet
#   * messages the actions print are captured and shown on the frame's own
#     status line; anything printing more than one line ([p], [s], [n])
#     leaves the screen instead, runs as it always did, and waits for a key
#     before the frame comes back
#   * piped input keeps the old line-based path untouched, below
def cmd_queue
  return cmd_queue_screen if Tui.interactive?

  cmd_queue_lines
end

# The rows of one frame: heading, the window of the queue with the cursor,
# a status line for whatever the last action said, and the keys. Built as
# one array so Tui.frame can paint it in a single write -- a frame assembled
# with several prints flickers on a slow connection, which SSH from a phone
# certainly is.
def queue_frame_lines(entries, selected, offset, window, mode, status)
  lines = [Tui.paint(t('cli.props_queue_heading', count: entries.size), :bold), '']
  entries[offset, window].to_a.each_with_index do |entry, i|
    row = queue_row(entry, offset + i)
    lines << if (offset + i) == selected
               Tui.paint("› #{Tui.truncate_to_width(Tui.strip_ansi(row), Tui.term_width - 2)}", :invert)
             else
               "  #{Tui.truncate_ansi(row, Tui.term_width - 2)}"
             end
  end
  lines << ''
  # The status line only exists when it has something to say. Reserving a
  # row for it left three blank lines stacked under the list on every
  # ordinary frame, which reads as a gap rather than as breathing room.
  unless status.to_s.empty?
    lines << Tui.truncate_to_width(status.to_s, Tui.term_width)
    lines << ''
  end
  keys = mode == :list ? t('cli.queue_menu_hint') : with_carry_key(t('cli.queue_actions', slug: entries[selected][:slug]))
  rows = Tui.fold_prompt(Tui.paint(keys, :dim), Tui.term_width).lines.map(&:chomp)
  # The second value is how many rows at the end are the keys, so a window
  # too short for the frame drops queue rows rather than the way out.
  [lines + rows, rows.size + 1]
end

# Runs one of the actions that speak in a single line ([u], [d], [m]) and
# hands back what it said, so the frame can show it on its status line
# rather than letting it scroll the screen. $stdout is restored in an
# ensure because these actions can abort the process outright.
def queue_quiet_action(&block)
  buffer = StringIO.new
  original = $stdout
  $stdout = buffer
  result = block.call
  [result, buffer.string.lines.map(&:chomp).reject(&:empty?).last.to_s]
ensure
  $stdout = original
end

def cmd_queue_screen
  dirty = false
  selected = 0
  offset = 0
  mode = :list
  status = ''

  Tui.screen do |screen|
  loop do
    entries = queue_entries
    if entries.empty?
      # No blank line of its own: the tail below writes the one blank line
      # this command ends with, whichever way the loop was left. Reached
      # only from a cleared screen (the first pass, or after screen.leave
      # published the last post), so there is no open frame row to close.
      puts t('cli.queue_empty')
      break
    end

    selected = selected.clamp(0, entries.size - 1)
    # Six rows go to the heading, its blank line, the blank line under the
    # list and the keys block, which folds to two on a narrow terminal; the
    # rest is queue. Recomputed every frame, so a resized window is simply
    # the next frame with a different number of rows.
    window = [entries.size, [Tui.term_height - 7, 3].max].min
    offset = Tui.clamp_offset(selected, offset, window, entries.size)
    lines, keep = queue_frame_lines(entries, selected, offset, window, mode, status)
    screen.paint(lines, keep_last: keep)

    key = screen.key
    # A window resized while the screen waits repaints and changes nothing
    # else -- including the status line, which the user has not read yet
    # and did not ask to lose by dragging a corner.
    next if key == :resize

    status = ''

    if mode == :list
      case key
      when :up then selected = (selected - 1) % entries.size
      when :down then selected = (selected + 1) % entries.size
      when :page_up then selected = [selected - window, 0].max
      when :page_down then selected = [selected + window, entries.size - 1].min
      when :home then selected = 0
      when :end then selected = entries.size - 1
      when :enter then mode = :actions
      when :escape
        # Tui.frame ends its last row WITHOUT a newline so the cursor can
        # stand on it, and this is the one way out that leaves that frame
        # standing -- so everything said afterwards was printed onto the
        # keys line: "Esc zpětStiskni klávesu pro pokračování…". One
        # newline closes the row; the blank line every wizard-reachable
        # command ends with is written by the tail below.
        puts
        break
      end
      next
    end

    case key
    when 'u', 'd'
      moved, status = queue_quiet_action { queue_swap(entries, selected, selected + (key == 'u' ? -1 : 1)) }
      if moved
        dirty = true
        # The cursor travels with the post it just moved, the same rule the
        # line-based screen follows through queue_focus_index.
        selected += key == 'u' ? -1 : 1
      end
    when 'm'
      # The carry SCREEN must not run inside queue_quiet_action: that
      # redirects $stdout, and Tui.frame prints there -- so the screen was
      # painted into the buffer instead of onto the terminal and [m] looked
      # like a key that does nothing. Only the write afterwards is captured,
      # because only the write has a line to say.
      first_future = entries.index { |entry| entry[:time] > Time.now }
      if first_future.nil? || selected < first_future
        status = t('cli.queue_swap_overdue')
      else
        target = queue_carry_screen(entries, selected, first_future, screen)
        if target && target != selected
          carried, status = queue_quiet_action { queue_carry_apply(entries, selected, target) }
          if carried
            dirty = true
            selected = target
          end
        end
      end
    when 'p', 's', 'n'
      # These print more than a frame can hold -- a publish announces, a
      # reschedule asks a question of its own. They get the terminal.
      screen.leave(t('cli.wizard_continue_prompt')) do
        dirty = true if queue_act_slow(entries, selected, key)
      end
      mode = :list
    when :enter, :escape then mode = :list
    end
  end
  end

  # The one blank line this command ends with. The rebuild opens with a
  # blank line of its own and closes with another after "Done:", so it is
  # only the silent way out that has to write one.
  if dirty
    rebuild_and_deploy(t('cli.updating_preview'))
  else
    puts
  end
end

# The three actions that leave the screen. Split out of queue_act so the
# frame-based screen and the line-based one below run the same code for
# them rather than two copies that can drift.
def queue_act_slow(entries, index, key)
  entry = entries[index]
  case key
  when 'p'
    freed = entry[:time]
    publish_draft(entry[:slug], path: entry[:path])
    queue_offer_compact(freed, entries[(index + 1)..])
  when 's'
    puts
    prompt_and_schedule(entry[:path], entry[:post], raw: entry[:raw]) == true
  when 'n'
    # Only a write that happened frees the slot: a declined unschedule
    # falling through to this offer stacked two posts on one time.
    if unschedule_post(entry[:path], entry[:post], entry[:slug], raw: entry[:raw])
      queue_offer_compact(entry[:time], entries[(index + 1)..])
    end
  end
end

def cmd_queue_lines
  dirty = false
  focus = nil
  loop do
    entries = queue_entries
    if entries.empty?
      puts t('cli.queue_empty')
      puts
      break
    end

    puts Tui.paint(t('cli.props_queue_heading', count: entries.size), :bold)
    puts
    index = queue_pick(entries, initial: queue_focus_index(entries, focus))
    if index.nil?
      puts
      break
    end

    focus = { slug: entries[index][:slug], index: index }
    puts
    dirty = true if queue_act(entries, index)
  end

  rebuild_and_deploy(t('cli.updating_preview')) if dirty
end

# Where the cursor opens after an action, given the row it was on before.
# By SLUG rather than by position: [u] and [d] move the picked post, so its
# old row now holds the neighbour it traded with -- coming back by number
# would leave the cursor behind, and a second [u] would carry off the wrong
# post. Moving a post several slots is the ordinary case, and it used to
# mean walking down from the top of the queue for every single slot.
#
# The remembered position is the fallback for a post that has LEFT the
# queue ([p] publishes it, [n] returns it to drafts): there is no slug to
# find any more, and its row now belongs to whoever moved up into it, which
# is where the eye already is. Nearest-to-the-old-position among matches,
# because the same slug in two different years is ordinary here (the rest
# of this screen is careful about it too) and the first match may well be
# the other one.
def queue_focus_index(entries, focus)
  return 0 if focus.nil? || entries.empty?

  matches = entries.each_index.select { |i| entries[i][:slug] == focus[:slug] }
  return matches.min_by { |i| (i - focus[:index]).abs } unless matches.empty?

  focus[:index].clamp(0, entries.size - 1)
end

# Returns true when something changed that the closing rebuild must pick
# up. "Publish now" rebuilds inside publish_draft as always; only the
# compaction it may be followed by still needs the closing one.
# [m] joins the row only in a terminal: carrying a post is a screen, and a
# piped caller has [u] and [d], which need no screen at all. Inserted before
# [Enter] the way the versions key is, which is literal in every locale.
def with_carry_key(prompt)
  return prompt unless Tui.interactive?

  prompt.sub('[Enter]') { "#{t('cli.queue_action_carry')}[Enter]" }
end

def queue_act(entries, index)
  entry = entries[index]
  case (key = Tui.key_choice(with_carry_key(t('cli.queue_actions', slug: entry[:slug]))))
  when 'u' then queue_swap(entries, index, index - 1)
  when 'd' then queue_swap(entries, index, index + 1)
  when 'm' then queue_carry(entries, index)
  when 'p', 's', 'n' then queue_act_slow(entries, index, key)
  when '' then false
  else
    puts t('cli.queue_unknown')
    puts
    false
  end
end

# Runs a queue's writes in order -- under the lock, after checking every
# one of them -- and, when one dies partway, names what did and did not
# move before the failure travels on. The pre-flight below catches what it
# can SEE -- a stale file, a taken path -- and the lock keeps the one run
# that could invalidate an answer out of the gap between the checking and
# the writing. Neither reaches the rest: a full disk, a permission error
# or a Ctrl-C BETWEEN the writes is invisible to both, and the half-moved
# queue it leaves behind was only ever discovered by the cron publishing
# the wrong post. Nothing is rolled back: the disk that just refused one
# write is not owed a second chance with another, and a wrong guess
# here doubles the damage. rescue Exception, not StandardError, because
# the deaths this must outlive long enough to speak are exactly the
# other kinds: abort is SystemExit, Ctrl-C is Interrupt. Plain English
# rather than t() on purpose -- a report that only exists mid-crash
# must not itself be able to abort on a missing locale key -- and the
# times are the ISO form the JSON carries, since repairing that file by
# hand is what the report is for.
# A name for a file or directory stepping aside during a queue move:
# dotted (so no post glob sees it), suffixed (so nothing mistakes it for
# content), stamped with this process's pid and never an existing name --
# a leftover from a crashed run must not be renamed onto.
def park_name(dir, base, ext)
  n = 0
  loop do
    candidate = File.join(dir, ".#{base}.queue-move.#{Process.pid}#{n.zero? ? '' : "-#{n}"}#{ext}")
    return candidate unless File.exist?(candidate)

    n += 1
  end
end

# A finished mover getting out of a parked post's way: back to its own
# name, which the parking freed, and back to its own DATE with it
# whenever keeping the new one would leave the two of them on one
# address. That is precisely the swap parking exists for -- the pair
# share a slug, so a mover holding the partner's year is served exactly
# where the partner is about to be put back. The rescue used to keep the
# new date on the grounds that a file whose folder disagrees with its
# date is a state the engine reads correctly, which is true of one post
# and not of two: the queue's own recovery handed back an archive that
# will not build until somebody repairs it by hand.
#
# The original bytes go back, not a patched date: they are what was read
# before the prompt, so the post ends the run byte for byte as it was
# found. Answers whether it did -- a rename that could not be followed by
# the rewrite says no, since the post then still holds the date it moved
# to, and the report calls that "moved".
def step_back(owner, partner)
  File.rename(partner[:json_home], owner[:json_home])
  return false unless one_address?(owner, partner)

  AtomicWrite.write(owner[:json_home], owner[:raw] || JSON.pretty_generate(owner[:post]))
  true
rescue StandardError
  false
end

# Whether the mover, left at the date it has just moved to, would be
# served at the same address as the post about to be put back beside it.
# Asked of PostAddress, which is where the build asks it.
def one_address?(owner, partner)
  moved = owner[:post].merge('date' => owner[:target].iso8601)
  (PostAddress.collision_keys(moved) & PostAddress.collision_keys(partner[:post])).any?
end

# Whether a parked post can be put back where it came from. Not
# File.exist? on the name -- two posts collide on their ADDRESS, whatever
# folder they sit in -- so the question goes to the same guard the
# pre-flight uses. Anything it cannot answer counts as occupied: this
# runs while an exception is on its way out, and the one thing it must
# not do is add a second post to an address rather than leave a rescued
# one parked under a name that `check` reports.
def way_home_clear?(info)
  AddressGuard.occupant(info[:post], content_dir: CONTENT_DIR, slug: info[:slug],
                        except: info[:json_temp], path: info[:json_home]).nil?
rescue StandardError
  false
end

# Whether this mover's write is really standing at its destination.
# Existence is not the question: in the swap parking exists for, both
# posts answer to the same name, so the file at that address can just as
# well be the OTHER one -- put there by a mover, or by this recovery a
# moment ago. Asked against what the mover itself writes (the post with
# the target date on it), field for field, because being wrong here means
# removing the last copy of a post.
def landed_at_destination?(info)
  return false unless File.exist?(info[:dest_json])

  JSON.parse(File.read(info[:dest_json], encoding: 'utf-8')) ==
    info[:post].merge('date' => info[:target].iso8601, 'scheduled' => true)
rescue StandardError
  false
end

# The parked media and history of a mover that finished: they land at the
# year the post just moved to -- its own mover found nothing to carry,
# which was the point of parking them. Shared with the recovery, which
# reaches this same state whenever a write landed and only the delete
# behind it did not.
def settle_parked_side_cars(info)
  if info[:media_temp] && File.exist?(info[:media_temp])
    FileUtils.mkdir_p(File.dirname(info[:dest_media]))
    if Dir.exist?(info[:dest_media])
      # A genuine orphan sitting at the destination: merged, the way every
      # media move merges, never silently replaced.
      PostWriter.move_media_dir(info[:media_temp], info[:dest_media])
    else
      File.rename(info[:media_temp], info[:dest_media])
    end
  end
  return unless info[:versions_temp] && File.exist?(info[:versions_temp])

  # An orphaned history at the destination is somebody else's past -- the
  # same stance PostVersions.move takes, for the same reason.
  FileUtils.rm_rf(info[:dest_versions])
  FileUtils.mkdir_p(File.dirname(info[:dest_versions]))
  File.rename(info[:versions_temp], info[:dest_versions])
end

# A rename inside the recovery, which runs with an exception already on
# its way out. Answers whether it happened instead of raising: a raise
# from in here replaces the failure the author is about to read and takes
# the report with it -- and the report is the only place a parked copy is
# named out loud, so the run would end on a backtrace about a rename with
# not one word about any of the posts.
def try_rename(from, to)
  File.rename(from, to)
  true
rescue StandardError
  false
end

def apply_queue_moves(moves)
  held = RunLock.hold(ROOT, label: 'queue') do
    # Checked here rather than in the three callers that used to each keep
    # a copy of this loop: above the lock these answers could stop being
    # true between the asking and the writing, and the thing that makes
    # them stop being true is not a person -- it is the publishing cron,
    # which runs every fifteen minutes and does not wait for anyone to
    # finish reading a screen. A tick landing in that gap publishes a due
    # post and then has a draft's schedule written back over it: state
    # reverted, announcement URL dropped, the same post queued to go out
    # (and be announced) a second time.
    #
    # The byte compare stays what it always was, and still earns its keep
    # inside the lock: it catches the tick that finished a moment BEFORE
    # the lock was taken, which no lock can do anything about.
    # Every file in this move is excused for every check: they are all
    # about to leave where they stand. A swap of two posts that share a
    # slug in two years has each one standing exactly where the other is
    # going, and asked one at a time it was refused as "resolve this
    # manually" -- a thing there was no way to resolve, since the two
    # posts are each other's obstacle.
    moving = moves.map { |entry, _| entry[:path] }
    landing = []
    moves.each do |entry, target|
      abort_if_post_changed(entry[:path], entry[:raw], entry[:post]['slug']) if entry[:raw]
      moved = entry[:post].merge('date' => target.iso8601)
      target_path = File.join(CONTENT_DIR, target.year.to_s, "#{entry[:post]['slug']}.json")
      taken = AddressGuard.occupant(moved, content_dir: CONTENT_DIR,
                                    slug: entry[:post]['slug'], except: moving,
                                    path: target_path)
      # ...which is why the moves are also checked against each OTHER: two
      # posts excused from each other's way must still not be walking to
      # the same place.
      taken ||= landing.find { |seen, keys| seen == target_path || (keys & PostAddress.collision_keys(moved)).any? }&.first
      abort t('cli.post_already_exists', slug: entry[:post]['slug'], path: taken) if taken

      landing << [target_path, PostAddress.collision_keys(moved)]
    end

    # A post standing where another one is going has to step aside first,
    # or the write that goes there overwrites it -- a swap of two posts
    # that share a slug in two years is exactly that, both ways round.
    # Only such a post is parked, so an ordinary swap writes precisely
    # what it always wrote; the name it parks under is not a post name
    # (leading dot, its own suffix, this process's pid), so nothing
    # looking for posts sees it and a leftover from a crashed run is
    # never renamed onto.
    #
    # THREE things step aside, not one. Media and edit history are keyed
    # by year/slug exactly like the post file, and the mover's own
    # machinery (Publishing.relocate_media) treats whatever it finds at
    # the destination as an orphan: it merged the two posts' pictures
    # into one directory and deleted the arriving post's version history
    # outright. Parked, each mover finds an empty destination and moves
    # nothing; the parked trees are put down at their DESTINATION year
    # once every write has landed.
    wanted = landing.map { |target_path, _| File.expand_path(target_path) }
    parked = []
    done = 0
    moving = false
    begin
      # Inside the begin on purpose: a parking rename that fails halfway
      # (a read-only year folder, a full disk) must put the already-parked
      # posts back before this leaves, or a post ends the run hidden under
      # a name nothing looks for, with the archive certifying itself sound.
      moves.each_with_index do |(entry, target), i|
        next unless wanted.each_with_index.any? { |w, j| j != i && w == File.expand_path(entry[:path]) }

        slug = entry[:post]['slug']
        year = File.basename(File.dirname(entry[:path]))
        dest_year = target.year.to_s
        info = {
          slug: slug,
          # What the file said before it was touched, and where it was
          # going: between them they are what puts a post back exactly as
          # it was found -- see step_back, which needs the date as well as
          # the name.
          index: i,
          post: entry[:post],
          raw: entry[:raw],
          target: target,
          json_temp: park_name(File.dirname(entry[:path]), File.basename(entry[:path], '.json'), '.json'),
          json_home: entry[:path],
          dest_json: File.join(CONTENT_DIR, dest_year, "#{slug}.json"),
          media_home: File.join(MEDIA_DIR, year, slug),
          dest_media: File.join(MEDIA_DIR, dest_year, slug),
          versions_home: File.join(PostVersions.versions_root(CONTENT_DIR), year, slug),
          dest_versions: File.join(PostVersions.versions_root(CONTENT_DIR), dest_year, slug)
        }
        File.rename(entry[:path], info[:json_temp])
        entry[:path] = info[:json_temp]
        parked << info
        if Dir.exist?(info[:media_home])
          info[:media_temp] = park_name(File.dirname(info[:media_home]), slug, '')
          File.rename(info[:media_home], info[:media_temp])
        end
        if Dir.exist?(info[:versions_home])
          info[:versions_temp] = park_name(File.dirname(info[:versions_home]), slug, '')
          File.rename(info[:versions_home], info[:versions_temp])
        end
      end

      moving = true
      moves.each do |entry, target|
        yield entry, target
        done += 1
      end
    rescue Exception
      # Everything parked and not yet consumed goes back under its own
      # name before this leaves. The one shape that needs care is the one
      # parking exists for: a finished mover's write is standing exactly
      # where a parked post used to -- so the finished file steps back to
      # ITS own name (which the parking freed) and, when it has to, to its
      # own date with it. Only then is the way home asked about, and only
      # if it is still blocked does the parked copy stay -- named out loud
      # rather than left for nobody to find.
      stranded = []
      # What each post ended up doing, written down as it happens. The
      # report at the bottom used to work this out afterwards -- from how
      # far the loop got, and from whether entry[:path] was still there --
      # and both answers are wrong here: the recovery moves files of its
      # own, and in a swap the two posts share every path there is, so
      # nothing on disk can be asked which of them it belongs to.
      landed = moves.each_index.map { |i| i < done ? :moved : :home }
      # The mover that finished and was not tidied up after: its write
      # landed and only the delete behind it did not, so what stands under
      # its parking name is a copy of a post that is already where it was
      # asked to go. `done` cannot see that -- the exception came out of
      # that very delete, so the loop never counted the move. Settled
      # before anything else reads the disk, because left standing the
      # loop below takes the leftover for a post that never moved: it
      # calls a finished mover "see below" and sends the author to rename
      # the copy over the post that did move.
      #
      # Exactly one mover can be in that state, and it is `moves[done]` --
      # the one that was running. Asked that narrowly on purpose: two posts
      # can be identical but for the date the move rewrites, and then "the
      # destination holds this post" is true of a file the mover never
      # wrote. Both halves have to hold, or the wrong copy is the one that
      # gets removed.
      parked.each do |info|
        next unless moving && info[:index] == done
        next unless File.exist?(info[:json_temp]) && landed_at_destination?(info)

        info[:settled] = true
        landed[info[:index]] = :moved
        begin
          File.delete(info[:json_temp])
          settle_parked_side_cars(info)
        rescue StandardError
          # Even the tidying can fail -- the disk that brought us here is
          # still full. Whatever is left under a parking name gets a row
          # of its own rather than a raise on the way out.
          left = [%i[json_temp dest_json], %i[media_temp dest_media], %i[versions_temp dest_versions]]
          left.each do |temp_key, dest_key|
            temp = info[temp_key]
            next unless temp && File.exist?(temp)

            stranded << [info[:slug], temp, info[dest_key], File.exist?(info[dest_key])]
          end
        end
      end
      parked.each do |info|
        next if info[:settled]

        if File.exist?(info[:json_temp])
          # A finished mover standing exactly where this post came from,
          # with its own name free to go back to. Gets out of the way
          # first -- and if it went back whole, it is not "moved" any more.
          owner = parked.find { |q| q[:dest_json] == info[:json_home] }
          in_the_way = owner && File.exist?(info[:json_home]) && !File.exist?(owner[:json_home])
          landed[owner[:index]] = :home if in_the_way && step_back(owner, info)

          # The name being free is not the same question as the address
          # being free, and it is the address the build refuses to build
          # two of -- so it is the one asked here, by the guard that
          # answers it everywhere else. Asking about the name alone is
          # how this recovery used to put a parked post back beside a
          # mover that was serving the same address from another folder.
          home_clear = way_home_clear?(info)
          if home_clear && try_rename(info[:json_temp], info[:json_home])
            landed[info[:index]] = :home
          else
            landed[info[:index]] = :parked
            # The last field is what the row is allowed to advise. A clear
            # way home means the rename merely failed, and doing it by
            # hand is exactly right; a blocked one means something else is
            # served at that address, and the instruction has to be the
            # careful one -- this file can be the only copy of its post.
            stranded << [info[:slug], info[:json_temp], info[:json_home], !home_clear]
          end
        end
        [%i[media_temp media_home], %i[versions_temp versions_home]].each do |temp_key, home_key|
          temp = info[temp_key]
          next unless temp && File.exist?(temp)

          taken = File.exist?(info[home_key])
          stranded << [info[:slug], temp, info[home_key], taken] if taken || !try_rename(temp, info[home_key])
        end
      end
      if done.positive? || landed.include?(:moved) || stranded.any?
        warn ''
        warn t('cli.queue_move_failed')
        # The dates stay ISO on purpose: this list is read with a file
        # manager open next to it, and the folder they name is the year
        # in the timestamp, not whatever the locale's date_format writes.
        #
        # Every row comes off `landed`, which the recovery kept as it
        # went. "see below" is one of those answers rather than a guess,
        # so it can no longer be printed for a post with nothing below it
        # -- which is what a mover put back under its own name got, while
        # the one the recovery had stepped back was still being announced
        # as moved to the date it no longer holds.
        moves.each_with_index do |(entry, target), i|
          state = case landed[i]
                  when :moved then t('cli.queue_move_moved', date: target.iso8601)
                  when :parked then t('cli.queue_move_see_below')
                  else t('cli.queue_move_stayed', date: entry[:time].iso8601)
                  end
          warn "  '#{entry[:slug]}' -- #{state}"
        end
        stranded.each do |slug, temp, home, blocked|
          # Asked again here rather than only where the row was made: the
          # recovery goes on moving files after a strand is recorded, so a
          # name that was free then can be occupied by the time this is
          # read -- and "rename it back" is an instruction to overwrite
          # whatever got there in between.
          note = if blocked || File.exist?(home)
                   t('cli.queue_move_blocked', temp: temp, home: home)
                 else
                   t('cli.queue_move_stranded', temp: temp, home: home)
                 end
          warn "  '#{slug}' -- #{note}"
        end
        warn ''
      end
      raise
    end
    # The mover writes its new file and deletes the one it came from; a
    # parking name left behind would be a duplicate of a post that is now
    # somewhere else.
    parked.each do |info|
      File.delete(info[:json_temp]) if File.exist?(info[:json_temp])
      begin
        settle_parked_side_cars(info)
      rescue SystemCallError => e
        # The posts themselves are already where they belong; only a
        # side-car is still under its parking name. Said out loud with
        # both paths -- and `check` reports a leftover parking name as an
        # error, so even a message lost to a closed terminal resurfaces.
        [%i[media_temp dest_media], %i[versions_temp dest_versions]].each do |temp_key, dest_key|
          temp = info[temp_key]
          next unless temp && File.exist?(temp)

          warn "'#{info[:slug]}': #{e.message} -- its files are rescued at #{temp}; move them to #{info[dest_key]} yourself"
        end
      end
    end
    true
  end
  return true unless held == RunLock::BUSY

  # Nothing was written and nothing is broken -- the run in the way is
  # almost always the publishing cron, which is gone within a minute. The
  # queue is re-read on the next frame anyway, so trying again costs a
  # keypress. (RunLock says the same thing on stderr, naming the holder;
  # this line is the one the queue screen can put on its status row.)
  puts t('cli.queue_busy')
  puts
  false
end

# Picking the post up and carrying it, instead of trading places with one
# neighbour at a time. The arrows move the post itself through the queue --
# on screen and in memory -- and nothing is written until Enter puts it
# down. Esc walks away and the queue is exactly as it was.
#
# The times do not travel with it. A queue of twenty slots stays those
# twenty slots; carrying a post from the eighth to the second means the six
# in between each step back one slot, which is the rule [u] already
# follows, applied to a whole run at once. That is what lets this be a
# single confirmed write instead of a write per slot: the set of occupied
# times is identical before and after, only the posts sitting in them
# differ.
#
# A post whose time has passed is off limits at both ends, for the reason
# queue_swap gives -- the cron owns it now, and handing another post that
# time would schedule it into the past.
def queue_carry(entries, index)
  first_future = entries.index { |entry| entry[:time] > Time.now }
  if first_future.nil? || index < first_future
    puts t('cli.queue_swap_overdue')
    puts
    return false
  end

  target = Tui.screen { |screen| queue_carry_screen(entries, index, first_future, screen) }
  # The carry screen ends on a frame, whose last row Tui.frame leaves open
  # for the cursor to stand on -- so the line the write reports below was
  # printed onto the carry hint. cmd_queue_screen needs no such thing: it
  # repaints over the frame instead of printing under it.
  puts
  return false if target.nil? || target == index

  queue_carry_apply(entries, index, target)
end

# The write half, split from the screen half so a caller that has already
# painted its own frame (cmd_queue_screen) can run the two apart -- the
# screen has to reach the terminal, the write only has a line to report.
def queue_carry_apply(entries, index, target)
  order = entries.dup
  order.insert(target, order.delete_at(index))
  times = entries.map { |entry| entry[:time] }
  moves = order.each_with_index.filter_map do |entry, i|
    [entry, times[i]] unless entry[:time] == times[i]
  end

  # Every half is checked before any of it is written, and both halves of
  # that happen under the lock -- see apply_queue_moves, which holds it and
  # does the checking. Here the run is longer than a swap's, so a failure
  # partway through would leave more of the queue half-moved.
  applied = apply_queue_moves(moves) do |entry, target_time|
    write_scheduled_date(entry[:path], entry[:post], target_time, raw: entry[:raw])
  end
  return false unless applied
  puts Tui.paint(t('cli.queue_carried', slug: entries[index][:slug], position: target + 1,
                                        date: times[target].getlocal.strftime(t('date_time_format'))), :green)
  puts
  true
end

# Draws the queue with one post held under the cursor and returns the
# position it was put down at, or nil on Esc. Its own repaint loop rather
# than Tui.menu, because the rows themselves reorder as the post travels --
# a menu moves a cursor over a fixed list, and this moves the list.
#
# Piped callers never reach here: [m] is offered only in a terminal, and
# scripted reordering has [u]/[d], which need no screen at all.
def queue_carry_screen(entries, index, first_future, screen)
  target = index
  offset = 0

  loop do
    window = [entries.size, [Tui.term_height - 7, 3].max].min
    order = entries.dup
    order.insert(target, order.delete_at(index))
    offset = Tui.clamp_offset(target, offset, window, entries.size)

    # The same frame the queue screen paints, so picking a post up does not
    # move anything on screen except the post itself -- the heading stays on
    # its row, the list stays in its rows, only the hint at the bottom
    # changes to say what the arrows now do.
    lines = [Tui.paint(t('cli.props_queue_heading', count: entries.size), :bold), '']
    order[offset, window].to_a.each_with_index do |entry, i|
      row = queue_row(entry, offset + i)
      lines << if (offset + i) == target
                 Tui.paint("⇅ #{Tui.truncate_to_width(Tui.strip_ansi(row), Tui.term_width - 2)}", :invert)
               else
                 "  #{Tui.truncate_ansi(row, Tui.term_width - 2)}"
               end
    end
    lines << ''
    lines << Tui.paint(Tui.truncate_to_width(t('cli.queue_carry_hint'), Tui.term_width), :dim)
    screen.paint(lines)

    case screen.key
    when :resize then next
    # No wraparound: carrying a post off the top and having it appear at the
    # bottom is a move nobody meant to make, and unlike a cursor this one
    # writes to disk when it lands.
    when :up then target = [target - 1, first_future].max
    when :down then target = [target + 1, entries.size - 1].min
    when :home then target = first_future
    when :end then target = entries.size - 1
    when :enter then return target
    when :escape then return nil
    end
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

  # Both halves are checked BEFORE either is written (in apply_queue_moves,
  # under the lock). write_scheduled_date aborts the process on a stale
  # file or a target path that is taken, and a swap is two independent
  # writes -- so an abort on the second left the first applied: the moved
  # post sat on a slot the un-moved post still held, and the cron published
  # both. In the [u] direction the surviving half moved the picked post
  # EARLIER, publishing it months before the date that had just been
  # confirmed, with nothing on screen but the abort. A same-slug-in-two-
  # years collision makes that deterministic, and the engine treats those
  # as ordinary.
  moves = [[entry, other[:time]], [other, entry[:time]]]
  applied = apply_queue_moves(moves) do |e, target|
    write_scheduled_date(e[:path], e[:post], target, raw: e[:raw])
  end
  return false unless applied
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
  return false unless Tui.yes?(answer)

  times = [freed_time] + rest.map { |entry| entry[:time] }
  # The whole loop is checked before the first write, for the reason
  # queue_swap is: write_scheduled_date ABORTS the process, and an abort
  # partway through N writes left the queue half-shifted -- some posts
  # moved forward, some not -- while the message on the way out says
  # nothing was saved. (Both the checking and the writing are in
  # apply_queue_moves now, which does them holding the cron's lock.)
  applied = apply_queue_moves(rest.each_with_index.map { |entry, i| [entry, times[i]] }) do |entry, target|
    entry[:path] = write_scheduled_date(entry[:path], entry[:post], target, raw: entry[:raw])
  end
  return false unless applied
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

  toot_gone, skeet_gone = retract_announcements(post)

  updated = post.merge('state' => DRAFT, 'draft_token' => SecureRandom.hex(8), 'created_at' => post['date'],
                       # The address this post just vacated. If it publishes again under a
                       # different slug (renamed while a draft), Publishing.publish turns
                       # this into a former_slugs redirect -- otherwise the old public URL
                       # would 404 with no trace, exactly what renames promise not to do.
                       # Publishing back under the same address just consumes the marker.
                       'unpublished_from' => PostAddress.vacated_marker(post, slug: slug))
  # Kept when the delete failed, so the address survives to be retried --
  # and so a re-publish can see there is already an announcement out there.
  if toot_gone
    updated.delete('mastodon_url')
  else
    warn t('cli.announcement_kept', url: post['mastodon_url'])
  end
  if skeet_gone
    updated.delete('bluesky_url')
    updated.delete('bluesky_uri')
  else
    warn t('cli.announcement_kept', url: post['bluesky_url'])
  end
  AtomicWrite.write_json(path, updated)
  puts t('cli.reverted_to_draft', path: path)

  final_slug = File.basename(path, '.json')
  unless rebuild_and_deploy(t('cli.updating_preview'))
    warn t('cli.draft_saved_preview_pending', slug: final_slug)
    warn ''
    return
  end

  draft_decision_loop(final_slug, path: path)
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

# Returns the row rather than printing it, so the same builder serves both
# faces: the frame collects the rows, the piped path prints them.
def props_line(key, value)
  return nil if value.to_s.empty?

  format('  %-12s %s', t("cli.props_label_#{key}"), value)
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

# Everything above the keys, as rows. Built once and used by both faces:
# the frame paints them, the piped path prints them.
# No leading blank row: in the scrolling dialog one separated the title
# from whatever was printed before it, and the piped path below still adds
# it. At the top of a frame it is just a gap.
def props_frame_lines(post, path, slug, year)
  lines = ["  #{Tui.paint(props_title(post), :bold)}",
           "  #{draft?(post) ? t('cli.props_draft_banner') : PostAddress.path(post).sub(%r{\A/}, '')}", '']
  if draft?(post)
    # No created/date line for a plain draft, on purpose: a draft has no
    # time -- its date is set by publishing or scheduling, and showing
    # anything earlier would suggest it means something.
    lines << props_line('scheduled', post['scheduled'] ? post_time!(post).getlocal.strftime(t('date_time_format')) : nil)
  else
    lines << props_line('state', t('cli.props_state_published', date: post_time!(post).getlocal.strftime(t('date_time_format'))))
  end
  lines << props_line('type', ContentType.dominant(post))
  lines << props_line('tags', (post['tags'] || []).join(', '))
  lines << props_line('pinned', truthy_frontmatter?(post['pinned']) ? t('cli.props_pinned_yes') : nil)
  # The same two predicates the announcer uses, so this screen predicts
  # what publish will DO rather than re-deriving it: announcement_url is
  # not fooled by an empty string and sees all three fields, unlisted?
  # reads the flag as broadly as the builder that hides the post.
  lines << props_line('unlisted', Publishing.unlisted?(post) ? t('cli.props_unlisted_yes') : nil)
  announced = Publishing.announcement_url(post)
  # An unlisted draft used to be told "goes out when the post publishes",
  # which was both a false promise and the wrong way round: an unlisted post
  # is never announced, so the line has to say that rather than leave the
  # author expecting a toot that will not come -- or worse, believing one is
  # owed and going to look for why it failed.
  lines << props_line('announced', if announced then announced
                                   elsif Publishing.unlisted?(post)
                                     t('cli.props_announces_never_unlisted')
                                   elsif draft?(post) then t('cli.props_announces_on_publish')
                                   else t('cli.props_not_announced')
                                   end)
  # Old addresses are counted, not listed: a post renamed a few times
  # would push everything else off the screen, and the list is one
  # keypress away in [a].
  addresses = address_entries(post).size
  lines << props_line('addresses', addresses.positive? ? t('cli.props_addresses_count', count: addresses) : nil)
  lines.compact!
  # The whole queue, after the property list rather than inside it: it is
  # a block, not a field, and until now the only way to see what goes out
  # when was opening every draft in turn -- which is also how an offered
  # slot could look like the wrong one.
  if post['scheduled'] && (queue = scheduled_entries.sort_by(&:first)).size > 1
    lines << ''
    lines << Tui.paint(t('cli.props_queue_heading', count: queue.size), :dim)
    queue.each do |time, queued_slug|
      mark = queued_slug == post['slug'] ? '→' : ' '
      lines << "  #{mark} #{time.getlocal.strftime(t('date_time_format'))}  #{queued_slug}"
    end
  end
  lines << ''
  lines << Tui.paint(t('cli.props_attributes_hint'), :dim)
  lines << ''
  lines
end

# The keys row for the post as it stands: which three of the six shapes it
# is (draft, scheduled, published, announced or not) decides the wording,
# and [v] joins only when there is a version to restore.
def props_prompt(post, path, slug, network_label)
  key = if draft?(post)
          post['scheduled'] ? 'cli.props_actions_scheduled' : 'cli.props_actions_draft'
        elsif network_label
          'cli.props_actions_published'
        else
          'cli.props_actions_published_plain'
        end
  with_versions_key(t(key, network: network_label), path, slug)
end

# "Not understood, try ..." -- listing the keys the row above is OFFERING,
# read out of that row rather than out of a second, hand-kept sentence.
# The two drifted: [v] (older versions) is added to the row only when the
# post has versions, and [t] only on a site with a network, and neither
# was ever named here.
def props_unknown(prompt)
  keys = prompt.scan(/\[([a-z])\]/).flatten
  t('cli.props_unknown', keys: keys.join(' / '))
end

def cmd_props(slug)
  return Tui.screen { |screen| props_loop(slug, screen) } if Tui.interactive?

  props_loop(slug, nil)
end

# Runs an action that speaks for itself. On a frame it takes the terminal
# and gives it back; piped it simply runs, which is what it always did.
def props_run(screen, &block)
  return block.call unless screen

  screen.leave(t('cli.wizard_continue_prompt'), &block)
end

# Leaving the dialog. Tui.frame ends its last line without a newline
# (deliberately -- see the comment there), so a frame left standing has its
# keys row still open, and the wizard's "press a key" was printed onto it:
# "[Enter] zpět: Stiskni klávesu pro pokračování…". That first newline
# closes the row; the piped face has already closed its own. The second is
# the blank line every wizard-reachable command ends with.
def props_close(screen)
  puts if screen
  puts
end

# One loop for both faces. The actions are the point of this dialog and
# there is no version of "keep them in step" that survives two copies of
# this case statement, so the difference between a frame and a scroll is
# confined to how the rows get on screen and how the key comes back.
def props_loop(slug, screen)
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

    lines = props_frame_lines(post, path, slug, year)
    prompt = props_prompt(post, path, slug, network_label)

    if screen
      keys = Tui.fold_prompt(Tui.paint(prompt, :dim), Tui.term_width).lines.map(&:chomp)
      screen.paint(lines + keys, keep_last: keys.size)
      key = screen.key
      next if key == :resize

      # The frame's key comes back as a symbol for Enter and Esc, where the
      # line-based dialog has always produced an empty string; the case
      # statements below were written against that and stay untouched.
      key = '' unless key.is_a?(String)
    else
      puts
      lines.each { |line| puts line }
      key = Tui.key_choice(prompt)
      # A pipe echoes nothing back, so the prompt's own row is still open --
      # closed here, before an action prints under it. Without it every
      # answer this dialog gives landed ON the keys: "[Enter] zpět: Datum
      # publikace…". The frame's row is closed on the way out instead (see
      # props_close), because there the frame is what stays on screen.
      puts
    end

    if draft?(post)
      case key
      when 'p' then return props_run(screen) { publish_draft(slug) }
      when 's'
        props_run(screen) do
          puts
          prompt_and_schedule(path, post, raw: original_raw)
        end
      when 'n'
        unless post['scheduled']
          props_run(screen) { puts props_unknown(prompt) }
          next
        end
        props_run(screen) { unschedule_post(path, post, slug, raw: original_raw) }
      when 'r'
        slug = props_run(screen) { rename_post(path, post, raw: original_raw) }
      when 'v'
        props_run(screen) { props_versions(path, slug) }
      when 'x'
        # Same shape as the [x] branch of draft_decision_loop: a deleted
        # draft only changes the preview, so the rebuild needs no asking.
        gone = props_run(screen) do
          delete_post(slug) && rebuild_and_deploy(t('cli.updating_preview'))
        end
        next unless gone

        return
      when '' then return props_close(screen)
      else props_run(screen) { puts props_unknown(prompt) }
      end
    else
      case key
      when 'u'
        props_run(screen) { cmd_unpublish(slug) }
        # A cancelled confirmation leaves the post published -- come back
        # to the dialog rather than ending it. After a real unpublish the
        # draft decision loop has already offered everything there is.
        p2 = find_post_path(slug)
        return if p2.nil? || draft?(JSON.parse(File.read(p2, encoding: 'utf-8')))
      when 't'
        unless network_label
          props_run(screen) { puts props_unknown(prompt) }
          next
        end
        props_run(screen) do
          puts
          network == :bluesky ? cmd_bluesky(slug) : cmd_toot(slug)
        end
      when 'c'
        props_run(screen) { toggle_pin(path, post, slug, raw: original_raw) }
      when 'r'
        slug = props_run(screen) { rename_post(path, post, raw: original_raw) }
      when 'a'
        props_run(screen) { props_addresses(path, slug) }
      when 'v'
        props_run(screen) { props_versions(path, slug) }
      when 'x'
        props_run(screen) { cmd_delete(slug) }
        # Gone -> leave. Still here -> the delete was cancelled, so stay.
        # Asked about THIS file, not about the slug: with the same slug in
        # two years, "does a post by this name still exist?" is answered by
        # the OTHER one, and the dialog quietly redrew itself around a post
        # nobody had opened -- same keys, different post, one keystroke
        # from deleting that one too.
        return unless File.exist?(path)
      when '' then return props_close(screen)
      else props_run(screen) { puts props_unknown(prompt) }
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
# The [v] key joins the prompt only for a post that has something to show.
# A row of actions is read every time the dialog opens, and one that is
# there on every post from the day it is installed -- doing nothing on all
# of them until somebody has edited one -- costs more attention than it
# saves. Inserted before [Enter], which is literal in every locale.
def with_versions_key(prompt, path, slug)
  year = File.basename(File.dirname(path))
  return prompt if PostVersions.list(slug, year, content_dir: CONTENT_DIR).empty?

  prompt.sub('[Enter]') { "#{t('cli.props_action_versions')}[Enter]" }
end

def version_row(file, index)
  format('%2d.  %s', index + 1, PostVersions.human_stamp(File.basename(file, '.json')))
end

# What the version SAYS, for the line under the cursor. A stamp answers
# "when", and until now that was the whole of it -- restoring meant picking
# by time and hoping, on the one screen where the point is to recognise a
# text you wrote. Title first because that is what a post is filed under
# here; failing that the opening words, which is what an untitled post is
# recognised by.
#
# Read on demand, for the selected row only: ten versions of a long post
# are ten files nobody needs opened to walk past them.
def version_preview(file)
  post = JSON.parse(File.read(file, encoding: 'utf-8'))
  title = post['title'].to_s.strip
  return title unless title.empty?

  text = Array(post['content']).filter_map { |b| b['text'] if b['type'] == 'text' }.join(' ')
  text.strip.gsub(/\s+/, ' ')
rescue StandardError
  # A version that will not parse is exactly the one somebody may be trying
  # to restore FROM, so it stays in the list, just without a preview.
  nil
end

# Same two faces as every other picker here: arrow keys in a terminal, a
# numbered list and a read line when piped. This screen was the one place
# that asked for a number even in a terminal, which made it the only list
# in the wizard a cursor could not walk.
#
# Unlike the other pickers it still says so when the number is out of range
# instead of quietly going back: a piped caller that typed 9 for three
# versions has made a mistake worth hearing about, and the sentence for it
# already exists in every locale.
def version_pick(rows, header, versions)
  if Tui.interactive?
    return Tui.menu(rows, header: header, hint: t('cli.versions_menu_hint'),
                          context: ->(i) { version_preview(versions[i]) })
  end


  header.each { |line| puts line }
  rows.each { |row| puts "  #{row}" }
  puts
  print t('cli.versions_prompt', count: rows.size)
  line = $stdin.gets.to_s.strip
  # A pipe echoes nothing, so the prompt's own row is still open -- closed
  # here, exactly as address_pick and queue_pick close theirs. Every caller
  # then writes the blank line after the picker itself.
  puts
  return nil if line.empty?

  index = line.to_i - 1
  return index if line =~ /\A\d+\z/ && (0...rows.size).cover?(index)

  puts t('cli.versions_unknown')
  nil
end

# The undo for editing. Lists what this post said before its recent saves
# and puts one of them back -- keeping the current text as a version of its
# own first, so choosing wrong is itself undoable.
#
# Only the text comes back. Media is not versioned (see lib/post_versions.rb),
# so a version old enough to name an image the post no longer has would
# restore a broken reference -- which is what the cap on how many are kept
# is for, and what the sentence under the list says out loud.
def props_versions(path, slug)
  year = File.basename(File.dirname(path))
  versions = PostVersions.list(slug, year, content_dir: CONTENT_DIR)
  if versions.empty?
    puts t('cli.versions_none')
    puts
    return
  end

  # Both lines travel INTO the picker's frame. Printed here, as they were
  # while the menu repainted in place, the frame would paint over them --
  # and what it painted over was the heading naming the post and the
  # warning that images are not versioned, which is the one thing a reader
  # has to weigh before choosing. The warning sits above the list on
  # purpose: it is about the whole operation, and a warning is worth more
  # read before the choosing than after it.
  header = [t('cli.versions_heading', slug: slug), t('cli.versions_media_note'), '']
  index = version_pick(versions.map.with_index { |file, i| version_row(file, i) }, header, versions)
  # The blank line after the picker, written here rather than in either of
  # its two faces: Tui.menu only closes the row its frame left open. Without
  # it the confirmation below stood on the row immediately under the keys.
  puts
  return if index.nil?

  chosen = versions[index]
  restored = begin
    JSON.parse(File.read(chosen, encoding: 'utf-8'))
  rescue JSON::ParserError, SystemCallError => e
    # A version is a file like any other -- a half-written save, a copy the
    # cloud is still bringing down. Ending the whole CLI in a parser error
    # was the one thing this screen must not do: it is where somebody goes
    # precisely BECAUSE something is wrong.
    puts Tui.paint("⚠️  #{File.basename(chosen)}: #{e.class} -- #{e.message.lines.first.to_s.strip[0, 80]}", :yellow)
    puts
    next_round = true
    nil
  end
  return props_versions(path, slug) if restored.nil? && next_round
  # One key, not a typed word. This engine keeps typing for what DISAPPEARS
  # -- deleting a post and unpublishing one both ask for the slug -- and
  # restoring a version loses nothing: the current text is kept as a version
  # of its own first, which is what the sentence above the prompt says. A
  # confirmation that explains the move is reversible and then asks you to
  # write something out argues with itself. It stays a confirmation rather
  # than becoming none, because Enter in the list is a single keystroke and
  # this overwrites the text being worked on.
  unless Tui.yes?(Tui.key_choice(t('cli.versions_confirm')))
    # No blank line of its own: cli.cancelled_nothing_saved ends in one
    # already, which is how its other two callers (both aborts) get theirs.
    # With this puts as well, cancelling a restore was the one place in the
    # wizard that left two.
    puts t('cli.cancelled_nothing_saved')
    return
  end

  # The current text becomes a version too, so this is not the one move in
  # the engine that cannot be walked back.
  PostVersions.keep(path, content_dir: CONTENT_DIR)
  current = JSON.parse(File.read(path, encoding: 'utf-8'))
  # Held before the loop below replaces it: these blocks carry the only
  # record of where each media file was downloaded from.
  live_content = current['content']
  # Only what the author writes comes back. Everything the engine owns --
  # the announcement URLs, the draft token, the state, the redirects --
  # belongs to the post as it is NOW, and restoring an old copy of it would
  # sever a live thread or resurrect an address that has since been spent.
  %w[title tags content type hero].each do |key|
    restored.key?(key) ? current[key] = restored[key] : current.delete(key)
  end
  # `src` is engine-side too, and older than this dialog knows: every
  # version written before media entries started carrying the address the
  # file came from -- which is every version in every archive that predates
  # it, i.e. the whole of any installation being upgraded -- restores a
  # content array with the key simply missing. The post then cannot say
  # which of the archive's files it already holds, and the next import
  # fetches every one of them again. Taken from the copy being replaced,
  # exactly as edit_post takes it from the stored post.
  restore_media_src(current['content'], live_content)
  AtomicWrite.write_json(path, current)
  puts t('cli.versions_restored', path: path)
  puts
  rebuild_and_deploy(t('cli.updating_preview'))
end

def props_addresses(path, slug)
  loop do
    # Re-read at the top of every pass rather than trusting the copy the
    # dialog is holding: this screen writes the post back, and the window
    # between reading it and writing it is however long someone spends at
    # the picker -- with the scheduled-publish cron running every 15
    # minutes. The write below refuses if anything moved in between.
    raw = File.read(path, encoding: 'utf-8')
    post = JSON.parse(raw)
    entries = address_entries(post)
    if entries.empty?
      puts t('cli.addresses_none')
      puts
      return
    end

    # The post's own address today, in the shape its kind of address is
    # written in -- a page's has no year in it. Compared against, so the
    # row for "the address I am at right now" is not marked as taken by
    # somebody else.
    current = PostAddress.vacated_marker(post, slug: slug)
    rows = entries.each_with_index.map { |(_, value), i| address_row(value, current, i) }
    # Into the frame, not above it -- see version_pick.
    index = address_pick(rows, [Tui.paint(t('cli.addresses_heading', count: entries.size), :dim), ''])
    # The blank line after a picker is the caller's to write -- Tui.menu
    # only closes the row its frame left open. Cancelling out of the list
    # said nothing at all, so the wizard's "press a key" sat directly under
    # the keys; the confirmation below had the same row to itself.
    puts
    return if index.nil?

    key, former = entries[index]
    print t('cli.addresses_drop_confirm', address: former)
    next unless Tui.yes?(Tui.key_choice(''))

    abort_if_post_changed(path, raw, slug)
    updated = post.dup
    remaining = Array(updated[key]).map(&:to_s) - [former]
    remaining.empty? ? updated.delete(key) : updated[key] = remaining
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
# Both lists, in one list. A post records the addresses it has left in
# former_slugs ("year/slug"); a PAGE records them in redirect_from
# ("/slug/"), because a page's address has no year to write down. The
# dialog read only the first, so a renamed page was told it had no old
# addresses at all -- while the build warned about the one it could not
# place, on every single run, with nothing anywhere able to clear it.
def address_entries(post)
  Array(post['former_slugs']).map { |value| ['former_slugs', value.to_s] } +
    Array(post['redirect_from']).map { |value| ['redirect_from', value.to_s] }
end

# Who is standing at a root address today: a page of that slug, whatever
# year its file sits in. Same question address_occupant answers for a
# post's address, asked the way a page is served.
def root_occupant(name)
  PathGlob.under(CONTENT_DIR, '*', "#{PathGlob.literal(name)}.json").sort.each do |file|
    candidate = begin
      JSON.parse(File.read(file, encoding: 'utf-8'))
    rescue StandardError
      next
    end
    next unless candidate.is_a?(Hash) && PostAddress.page?(candidate)

    return draft?(candidate) ? :draft : :published
  end
  nil
end

def address_row(former, current, index)
  parts = former.split('/').reject(&:empty?)
  page_address = former.start_with?('/')
  occupant = if former == current
               nil
             elsif page_address && parts.size == 1
               root_occupant(parts.first)
             elsif parts.size == 2
               address_occupant(parts)
             end
  note = if !page_address && parts.size != 2
           "  #{t('cli.addresses_unusable')}"
         elsif occupant == :draft
           "  #{t('cli.addresses_taken_draft')}"
         elsif occupant
           "  #{t('cli.addresses_taken')}"
         else
           ''
         end
  format('%2d.  %s%s', index + 1, former, note)
end

# Which kind of post owns year/slug today; nil when nobody does. The kind
# matters: a draft emits no page, so the build still writes the redirect
# stub there and the old link keeps working -- the takeover only happens
# when that draft publishes. Told "this redirect never happens", the
# owner's next move is dropping an address that is doing its job.
def address_occupant(parts)
  year, slug = parts
  # The file may sit in any year's folder: what decides the address is the
  # DATE. Reading only <year>/<slug>.json answered about a file rather than
  # about an address, which is the same narrow question the six writing
  # paths were asking until this release.
  PathGlob.under(CONTENT_DIR, '*', "#{PathGlob.literal(slug)}.json").sort.each do |file|
    candidate = begin
      JSON.parse(File.read(file, encoding: 'utf-8'))
    rescue StandardError
      next
    end
    next unless candidate.is_a?(Hash) && !PostAddress.page?(candidate)
    next unless PostAddress.date_year(candidate) == year

    return draft?(candidate) ? :draft : :published
  end
  nil
rescue Errno::ENOENT
  nil
rescue StandardError
  # An occupant that will not read or parse still owns the path --
  # promising a live redirect on its account would be a guess.
  :published
end

# Same two faces as every other picker here: arrow keys in a terminal, a
# numbered list and a read line when piped.
def address_pick(rows, header)
  return Tui.menu(rows, header: header, hint: t('cli.addresses_menu_hint')) if Tui.interactive?

  puts
  header.each { |line| puts line }
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
  # A terminal echoes the Enter and closes the prompt's row; a pipe echoes
  # nothing, so without this every answer below was printed onto the prompt
  # itself -- "Přejmenovat na: Zrušeno." The same line Wizard.ask writes for
  # the same reason.
  puts unless Tui.interactive?
  # Each of the five ways out below ends with one blank line, like every
  # other command reachable from the wizard: this one is run from the
  # properties dialog through screen.leave, and without it the "press a key"
  # that follows sat flush against whatever was just refused.
  if input.empty?
    puts t('cli.cancelled')
    puts
    return old_slug
  end

  new_slug = Slug.slugify(input)
  if new_slug.empty?
    puts t('cli.rename_unusable', input: input)
    puts
    return old_slug
  end
  # A slug is a filename (<slug>.json) and a URL segment; slugify keeps it
  # to safe characters but not to a safe length, so a pasted paragraph
  # reaches the write as a filename the filesystem rejects with a raw
  # ENAMETOOLONG. cmd_add caps its slug at eight words for readability;
  # this caps by bytes for correctness, well under any filesystem's limit.
  if new_slug.bytesize > 200
    puts t('cli.rename_too_long')
    puts
    return old_slug
  end
  if new_slug == old_slug
    puts t('cli.rename_same')
    puts
    return old_slug
  end

  # Same guard as edit and publish, and it has to refuse EXACTLY what the
  # build refuses -- so it asks PostAddress the same question the build
  # asks, instead of working out its own answer. Comparing served
  # addresses was its own answer, and it let through both pairs the build
  # stops on: a draft (served under its token, but its file and media sit
  # under year/slug like everyone else's) and a page (served at the root,
  # so its year never seemed to matter). Either one turned a rename into a
  # site that would not build.
  new_path = File.join(CONTENT_DIR, year, "#{new_slug}.json")
  new_media_dir = File.join(MEDIA_DIR, year, new_slug)
  taken_address = AddressGuard.occupant(post, content_dir: CONTENT_DIR, slug: new_slug,
                                        path: new_path)
  if File.exist?(new_path) || Dir.exist?(new_media_dir) || taken_address
    # Not the shared post_already_exists text: that one says "continuing
    # would overwrite it -- resolve manually", and a refused rename
    # neither continues nor needs resolving. Picking another slug does.
    #
    # An occupant nobody can read is refused just the same -- a place whose
    # owner will not open is not free space -- but it gets its own sentence,
    # because "another post already uses that slug" is a claim about a file
    # this process never managed to look at, and the reader would go
    # looking for a post that may not be there.
    if taken_address && AddressGuard.unreadable?(taken_address)
      puts t('cli.rename_unreadable', slug: new_slug, path: taken_address)
    else
      puts t('cli.rename_taken', slug: new_slug)
    end
    puts
    return old_slug
  end

  if draft?(post)
    puts t('cli.rename_confirm_draft', old: old_slug, new: new_slug)
  else
    # The addresses the site actually answers at: a page has no year in
    # its address, and a post whose date was corrected across a year lives
    # under the DATE's year, not the folder's. The banner two rows above
    # this dialog had it right while the promise below did not.
    page = PostAddress.page?(post)
    address_year = PostAddress.date_year(post)
    puts t('cli.rename_confirm',
           old_url: published_url(old_slug, address_year, page: page),
           new_url: published_url(new_slug, address_year, page: page))
  end
  unless Tui.yes?(Tui.key_choice(t('cli.rename_go')))
    puts t('cli.cancelled')
    puts
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
    # The year the post was SERVED under -- its date's, not its folder's.
    # Those two part company after a date is corrected across a year, and
    # recording the folder's year left the live address dying without a
    # redirect while a stub appeared at an address nobody ever linked to.
    # One rule for the address being vacated, and one for where the debt is
    # written down -- see lib/post_address.rb. A rename back to an earlier
    # slug must not leave that address redirecting to itself, which is what
    # spend_vacated takes care of.
    PostAddress.spend_vacated(updated, PostAddress.vacated_marker(post, slug: old_slug), slug: new_slug)
  end

  # Media first, replacement JSON second, old JSON last -- the same order
  # edit_post uses, for the same reason: no step may remove the only copy
  # of anything before its replacement exists.
  PostWriter.move_media_dir(File.join(MEDIA_DIR, year, old_slug), new_media_dir)
  # The edit history is keyed by year/slug like the media, so it renames
  # with the post -- the trash has always taken it along (delete and
  # restore both do). Left under the old slug, the [v] dialog went dark
  # and the orphaned directory waited to be inherited by a future post
  # born under that name.
  PostVersions.move(old_slug, year, from_content_dir: CONTENT_DIR,
                    to_dir: File.join(PostVersions.versions_root(CONTENT_DIR), year, new_slug))
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
  # Re-resolved AFTER the edit on purpose: a rename inside the editor moves
  # the file, so the path captured before it would be stale. Everything
  # downstream then works from this one.
  path = find_post_path(slug)
  return unless path

  draft_decision_loop(slug, path: path) if draft?(JSON.parse(File.read(path, encoding: 'utf-8')))
end

# The date of the post a command is about, or a sentence and an exit.
#
# `check` names an unparseable date cleanly, and `check --repair` says
# outright that putting it right is the author's decision -- and then the
# two commands that would let them do it, `props` and `edit`, died on a raw
# Ruby backtrace out of Time.parse. A day/month swap (2026-31-06) is an
# ordinary typo for anyone used to DD-MM, and hand-editing a post's JSON is
# a documented workflow.
#
# The listings that walk every post keep their own `rescue next`: one
# unreadable file must not hide the rest of the archive from its owner.
def post_time!(post)
  Time.parse(post['date'].to_s)
rescue ArgumentError, TypeError
  abort t('cli.post_date_unreadable', slug: post['slug'].to_s, value: post['date'].inspect)
end

def edit_post(slug, path: nil)
  path ||= find_post_path(slug)
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

  date = post_time!(post)
  frontmatter = build_frontmatter(
    title: post['title'].to_s,
    tags: tags_to_frontmatter(post['tags']),
    type: post['type'],
    # Shown with its current value so the author can see the state, not
    # just set it -- and only for a published post: pinning a draft that
    # nothing links to yet would have nowhere to show.
    # A draft is offered the key only if it already carries a pin --
    # otherwise pinning something nobody can see yet has nowhere to show.
    # Offering it when set matters: without the line in the header, saving
    # would drop a pin the post had (unpublish keeps it).
    pinned: (draft?(post) && !truthy_frontmatter?(post['pinned'])) ? nil : truthy_frontmatter?(post['pinned'] || 'false'),
    unlisted: (draft?(post) && !PostAddress.flag?(post['unlisted'])) ? nil : PostAddress.flag?(post['unlisted']),
    # Shown on a site that uses heroes, or on a post that has already said
    # something of its own -- and it has to be shown in the second case
    # even when the site doesn't, because a header without the line saves
    # the post without it, which is exactly how this field went missing
    # before it was here at all.
    hero: hero_frontmatter_value(post),
    # Offered only where it already is: turning a post into a page moves
    # its address, so it is not something to hand somebody as a checkbox
    # on every edit. Shown when set, so that saving cannot silently
    # un-page a page.
    page: PostAddress.flag?(post['page']) ? true : nil,
    # Both shown only when set, for the reason the pin is: a key on every
    # new post suggests every post needs an answer, and almost none do.
    series: post['series'].to_s.strip.empty? ? nil : post['series'].to_s.strip,
    series_part: post['series_part'],
    toc: post['toc'].nil? ? nil : truthy_frontmatter?(post['toc'])
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

  new_date = meta['date'].to_s.empty? ? date : parse_frontmatter_date!(meta['date'])
  new_title = meta['title'].to_s.empty? ? nil : meta['title']
  new_tags = tags_from_frontmatter(meta['tags'])
  new_type, new_page = frontmatter_type_and_page(meta)

  blocks, media_files, missing = MarkdownParser.parse_body(new_body, media_dir, incoming_dir: INCOMING_DIR)
  wait_for_missing_images(missing)
  heic_consumed = convert_heic_attachments(blocks, media_files)
  check_attachment_sizes(media_files)
  check_video_playback(media_files)
  fill_image_dimensions(blocks, media_files, media_dir)
  restore_posters(blocks, post['content'])
  restore_media_src(blocks, post['content'])
  # Before the lookup, not after it: a player the post already has is not
  # worth a network call, and asking anyway is what made an edit depend on
  # a service answering.
  restore_embed_lookups(blocks, post['content'])
  resolve_embed_lookups(blocks)

  # Checks for a drop in every block type, not just images: markdown can't
  # express a link card or a foreign embed (Instagram), so saving would
  # otherwise silently delete them.
  # ...and every formatting SPAN inside them. docs/architecture.md lists
  # `small`, `mention` (carrying an account URL) and `color` (carrying a hex)
  # as span types accepted from imports, and the build renders all three --
  # a mention becomes a real link. MarkdownWriter has no markdown form for
  # any of them, so wrap_markdown falls through to the bare text: the words
  # survive and the span, with whatever it carried, is gone. The block
  # stayed a text block, so counting block types alone said nothing had
  # happened and no confirmation was asked for.
  counts = lambda do |list|
    list.each_with_object(Hash.new(0)) do |b, h|
      h[b['type']] += 1
      spans = Array(b['formatting']) + Array(b['items']).flat_map { |i| Array(i['formatting']) }
      spans.each { |f| h["#{f['type']} span"] += 1 }
    end
  end
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
  updated['unlisted'] = true if PostAddress.flag?(meta['unlisted'])
  # Stored only when it disagrees with the site, so an ordinary post stays
  # silent and follows layout.hero if that is ever flipped. Deleting the
  # line is therefore a way to say "no opinion", not a way to lose one.
  if meta.key?('hero')
    hero_wanted = truthy_frontmatter?(meta['hero'])
    updated['hero'] = hero_wanted unless hero_wanted == SITE_HERO
  end
  updated['page'] = true if new_page
  # Written as typed: the series name is a display name (the slug for its
  # address is derived at build time), and the part number is an override
  # for the rare post published out of order.
  updated['series'] = meta['series'].to_s.strip unless meta['series'].to_s.strip.empty?
  part = Integer(meta['series_part'].to_s.strip, exception: false)
  updated['series_part'] = part if part
  # Only stored when it disagrees with the engine's own judgement, so the
  # ordinary post carries no line about a table of contents it was never
  # going to have.
  updated['toc'] = truthy_frontmatter?(meta['toc']) if meta.key?('toc') && !meta['toc'].to_s.strip.empty?
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
  # Both lists come across first, because what the save owes is decided
  # against what the post already carries -- and then the debt is asked of
  # PostAddress in both directions: the address the post HAD, and the one
  # the save gives it.
  #
  # Asking only about the year was the hole. `type: page` typed into the
  # frontmatter -- or deleted from it, which the editor shows precisely so
  # that saving cannot silently un-page a page -- moves a post between
  # /posts/2026/slug/ and /slug/ without touching the date. Every link to
  # the address it left then died with no stub behind it, and this is the
  # one path of the five that was still working it out on its own.
  # Same guard as Publishing.publish: a date edit that moves the post
  # into a year where another post already owns this slug must not
  # overwrite that post's JSON (and displace its media directory).
  # Asked on every save, not only when the folder changes: typing
  # `type: page` into the frontmatter moves the post to /slug/ without
  # moving its file anywhere, and the address it lands on can already be
  # a page's. The build refuses to run on that, so the save that made it
  # would be the last one before the site stopped building.
  # Only when the save actually moves the post. An archive that already
  # holds two posts at one address is exactly the archive somebody is
  # trying to repair, and refusing the edit that would repair it -- while
  # claiming it would overwrite a file it does not write to -- left them
  # with the CLI unable to fix what the CLI had let happen.
  moving = PostAddress.collision_keys(updated, slug: slug) !=
           PostAddress.collision_keys(post, slug: slug) ||
           File.expand_path(new_path) != File.expand_path(path)
  if moving
    taken = AddressGuard.occupant(updated, content_dir: CONTENT_DIR, slug: slug,
                                  except: path, path: new_path)
    abort t('cli.post_already_exists', slug: slug, path: taken) if taken
  end

  carried = Array(post['former_slugs']).map(&:to_s)
  updated['former_slugs'] = carried unless carried.empty?
  inherited = Array(post['redirect_from']).map(&:to_s)
  updated['redirect_from'] = inherited unless inherited.empty?
  was = draft?(post) ? nil : PostAddress.vacated_marker(post, slug: slug)
  now = draft?(updated) ? nil : PostAddress.vacated_marker(updated, slug: slug)
  PostAddress.spend_vacated(updated, was == now ? nil : was, slug: slug)
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

  # The one place a post's TEXT is replaced by a person, so the one place
  # the previous text is worth keeping. Field-only writes elsewhere
  # (pinning, announcing, scheduling) deliberately make no version: a
  # history of pin toggles would bury the one entry anybody ever wants.
  #
  # Kept BEFORE the relocation below, and keyed on the old path on
  # purpose: relocate_media moves the whole versions directory across a
  # year change, so a copy kept there first travels with the rest --
  # kept after the move, it would strand in the year the post just left.
  PostVersions.keep(path, content_dir: CONTENT_DIR)

  # Media move first, replacement JSON second, old JSON last. The old
  # order deleted the post's only file and *then* moved its media -- so a
  # date edit into a year with no media.nosync/<year>/ yet (the mv raises
  # ENOENT there) destroyed the post: nothing in trash, nothing in the
  # editor's temp file, nothing to restore.
  Publishing.relocate_media(slug, year, new_year) if new_dir != File.dirname(path)

  FileUtils.mkdir_p(new_media_dir) if media_files.any?
  media_files.each do |src, filename|
    # Through PostWriter, not a bare cp: this is where a photograph
    # attached during an edit loses the coordinates it was taken at.
    # `replace: true` keeps what this path has always done -- a file
    # attached under a name already in the folder replaces it.
    PostWriter.copy_media_file(src, File.join(new_media_dir, filename), replace: true)
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
# Takes the announcement down on whichever network carries it, and says
# for each whether it is really gone. Shared by unpublish and delete
# because they owe the same thing: a page that stops existing must not
# leave a public post pointing at it. The caller decides what to do with
# a failure -- both keep the address so it can be retried, rather than
# forgetting an announcement that is still out there.
def retract_announcements(post)
  toot_gone = true
  if post['mastodon_url']
    puts t('cli.deleting_toot', url: post['mastodon_url'])
    toot_gone = MastodonPoster.delete(post['mastodon_url'])
    warn t('cli.delete_toot_failed') unless toot_gone
  end

  skeet_gone = true
  if post['bluesky_uri']
    puts t('cli.deleting_bluesky', url: post['bluesky_url'])
    skeet_gone = BlueskyPoster.delete(post['bluesky_uri'])
    warn t('cli.delete_bluesky_failed') unless skeet_gone
  end

  [toot_gone, skeet_gone]
end

def delete_post(slug, path: nil)
  path ||= find_post_path(slug)
  abort t('cli.post_not_found', slug: slug) unless path

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  text = post['content'].find { |b| b['type'] == 'text' }
  puts "#{post['date']}  #{post['title'] || text&.fetch('text', '')&.slice(0, 60)}"
  # Said BEFORE the confirmation, not after it: deleting the post takes
  # the announcement down with it, and that part cannot be undone by
  # `restore` -- the thread and whatever was said under it are gone for
  # good. One confirmation is enough, as long as it is an informed one.
  announced = [post['mastodon_url'], post['bluesky_url']].compact
  puts t('cli.delete_takes_announcement', url: announced.first) unless announced.empty?
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
  # The page is about to stop existing, so the announcement pointing at it
  # has to go too -- the same tidying up unpublish has always done. Left
  # behind, it stayed public and linked to a 404 the moment the next build
  # pruned the page, with nothing anywhere to say so.
  toot_gone, skeet_gone = retract_announcements(post)

  trash_dir = File.join(TRASH_DIR, year, slug)
  # The media `check --repair` set aside for this post live in
  # trash/<year>/<slug>/media/ -- the same directory this delete is about to
  # clear for itself. Wiping it took files the repair pass had promised were
  # restorable, without a word. They are kept aside and merged back below.
  # Kept inside the trash, not in TMPDIR: a move across devices copies, and
  # a temporary directory that fills up or is cleared mid-run takes files
  # the repair pass promised were restorable.
  kept_media = nil
  if Dir.exist?(File.join(trash_dir, 'media'))
    kept_media = File.join(TRASH_DIR, ".keep-#{slug}-#{Process.pid}")
    FileUtils.mkdir_p(kept_media)
  end
  FileUtils.mv(PathGlob.under(trash_dir, 'media', '*'), kept_media) if kept_media
  FileUtils.rm_rf(trash_dir)
  FileUtils.mkdir_p(trash_dir)
  # The post's earlier drafts go with it. Left behind they would be an
  # orphan directory nothing points at, and a restore would bring the post
  # back with amnesia -- the one thing `restore` exists to prevent.
  PostVersions.move(slug, year, from_content_dir: CONTENT_DIR,
                    to_dir: File.join(trash_dir, 'versions'))
  # Written rather than moved, because the copy that goes to trash must
  # not keep an address that no longer resolves: a restored post would
  # carry a dead announcement and `toot` would refuse to send a new one,
  # seeing a post that already has one. An address whose deletion FAILED
  # is kept, so it can still be retried by hand.
  trashed = post.dup
  trashed.delete('mastodon_url') if toot_gone
  if skeet_gone
    trashed.delete('bluesky_url')
    trashed.delete('bluesky_uri')
  end
  File.write(File.join(trash_dir, 'post.json'), JSON.pretty_generate(trashed))
  File.delete(path)
  FileUtils.mv(media_dir, File.join(trash_dir, 'media')) if Dir.exist?(media_dir)
  # ...and back in with them, beside the post's own media rather than
  # instead of it: a name already taken keeps both copies.
  if kept_media
    FileUtils.mkdir_p(File.join(trash_dir, 'media'))
    Dir.children(kept_media).each do |name|
      target = File.join(trash_dir, 'media', name)
      target = "#{target}.#{Time.now.strftime('%Y%m%d%H%M%S')}" if File.exist?(target)
      FileUtils.mv(File.join(kept_media, name), target)
    end
    FileUtils.remove_entry(kept_media)
  end

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
  (PathGlob.under(TRASH_DIR, '*', PathGlob.literal(slug), 'post.json') +
   [File.join(TRASH_DIR, slug, 'post.json')]).select { |f| File.file?(f) }.uniq.sort
end

# Mirrors pick_among_years, over what is in the trash rather than what is
# published: a number picks, anything else cancels.
def pick_among_trashed(slug, paths)
  readable = paths.filter_map { |f| (summary = post_summary(f)) && [f, summary] }
  abort t('cli.nothing_in_trash', slug: slug) if readable.empty?

  if readable.size == 1 && paths.size > 1
    warn t('cli.ambiguous_one_readable', slug: slug)
    return readable.first.first
  end

  paths = readable.map(&:first)
  rows = readable.map { |(_, summary)| summary_row(summary) }
  question = t('cli.ambiguous_slug', slug: slug, count: paths.size)

  if Tui.interactive?
    # The question goes INTO the frame. Printed above it, as it used to be,
    # the frame would paint straight over it.
    choice = Tui.menu(rows, header: [question, ''],
                            hint: t('cli.menu_hint_plain', count: [rows.size, 9].min))
    abort t('cli.cancelled_empty') if choice.nil?
    puts
    return paths[choice]
  end

  puts question

  rows.each_with_index { |row, i| puts "#{i + 1}) #{row}" }
  puts
  print t('cli.enter_number')
  input = $stdin.gets&.strip.to_s
  puts
  abort t('cli.cancelled_empty') unless input =~ /\A\d+\z/ && (1..paths.size).cover?(input.to_i)
  paths[input.to_i - 1]
end

# Media the repair pass set aside for a post that still exists: there is no
# post.json to bring back, only files. `check --repair` promises the trash
# is somewhere restore can reach, and this is the half that makes it true.
def trashed_media_dirs(slug)
  PathGlob.under(TRASH_DIR, '*', PathGlob.literal(slug), 'media').select { |d| File.directory?(d) }.sort
end

# Files a filesystem leaves behind rather than files anybody wrote. Kept out
# of a restore because returning them is noise, and kept out of the "still
# in the trash" warning for the same reason.
SYSTEM_CRUFT = /\A(?:\.DS_Store\z|\._|Thumbs\.db\z|desktop\.ini\z)/i

def restore_media(slug, dirs)
  dir = dirs.first
  if dirs.size > 1
    # The same rule as everywhere else in this file: never guess between
    # two years, show both and ask.
    dirs.each_with_index do |candidate, i|
      # SYSTEM_CRUFT, the same filter the restore itself uses. This is the
      # number a person reads while choosing which trashed year to bring
      # back, so counting by a rule the restore no longer follows offered
      # "(0 file(s))" for a directory holding two pictures -- and then
      # restored both of them.
      count = Dir.children(candidate).reject { |f| SYSTEM_CRUFT.match?(f) }.size
      puts format('%2d.  %s  (%s)', i + 1, candidate.sub("#{ROOT}/", ''),
                  t('cli.restore_media_count', count: count))
    end
    answer = Tui.plain_line(t('cli.restore_media_pick'))
    index = Integer(answer, exception: false)
    return unless index&.between?(1, dirs.size)

    dir = dirs[index - 1]
  end

  year = File.basename(File.dirname(File.dirname(dir)))
  target = File.join(MEDIA_DIR, year, slug)
  FileUtils.mkdir_p(target)
  returned = []
  kept = []
  # Everything the trash holds, not everything whose name looks ordinary.
  # This used to skip every dotfile, which was aimed at .DS_Store and hit
  # real media with it: a picture called ".hidden.jpg" stayed in the trash,
  # was not counted, was not named among the kept, and the line below then
  # reported a number that did not describe what had happened. Restoring
  # something and saying nothing about the rest is the one thing a restore
  # must not do.
  Dir.children(dir).reject { |f| SYSTEM_CRUFT.match?(f) }.sort.each do |name|
    destination = File.join(target, name)
    # Never over the top of a file that is there now: the archive it would
    # replace is the one thing this command exists to protect.
    if File.exist?(destination)
      kept << name
      next
    end

    FileUtils.mv(File.join(dir, name), destination)
    returned << name
  end
  FileUtils.rmdir(dir) if Dir.children(dir).empty?
  FileUtils.rmdir(File.dirname(dir)) if Dir.exist?(File.dirname(dir)) && Dir.children(File.dirname(dir)).empty?

  # What is still in the trash after all that -- system cruft aside, since
  # nobody put it there on purpose and nobody wants it back.
  left = Dir.children(dir).reject { |f| SYSTEM_CRUFT.match?(f) }.sort if Dir.exist?(dir)

  puts t('cli.restored_media', count: returned.size, path: target.sub("#{ROOT}/", ''))
  warn t('cli.restore_media_left', files: (left - kept).join(', ')) if left && !(left - kept).empty?
  warn t('cli.restore_media_kept', files: kept.join(', ')) unless kept.empty?
end

def cmd_restore(slug)
  found = trashed_paths(slug)
  if found.empty?
    # A post that was never deleted can still have files waiting here --
    # what `check --repair` set aside. Restoring those is not restoring a
    # post, so it is asked and reported separately.
    media = trashed_media_dirs(slug)
    return restore_media(slug, media) unless media.empty?
  end
  abort t('cli.nothing_in_trash', slug: slug) if found.empty?

  # Two years of the same slug can sit in the trash at once now, so the
  # same rule as everywhere else applies: never guess, show both and ask.
  trash_json = found.size == 1 ? found.first : pick_among_trashed(slug, found)
  trash_dir = File.dirname(trash_json)

  post = JSON.parse(File.read(trash_json, encoding: 'utf-8'))
  year = post_time!(post).year.to_s
  new_dir = File.join(CONTENT_DIR, year)
  new_path = File.join(new_dir, "#{slug}.json")
  taken = AddressGuard.occupant(post, content_dir: CONTENT_DIR, slug: slug, path: new_path)
  abort t('cli.post_already_exists', slug: slug, path: taken) if taken

  FileUtils.mkdir_p(new_dir)
  FileUtils.mv(trash_json, new_path)

  trash_media = File.join(trash_dir, 'media')
  if Dir.exist?(trash_media)
    # move_media_dir, not a bare mv: with an orphan media directory already
    # at the target (a post deleted and re-created under the same slug),
    # mv puts the restored one INSIDE it -- media.nosync/2026/slug/slug/ --
    # and every image in the restored post is a broken link. That is the
    # exact nesting move_media_dir exists to prevent.
    PostWriter.move_media_dir(trash_media, File.join(MEDIA_DIR, year, slug))
  end
  # ...and the history comes back with it, so a restored post can still be
  # walked back to what it said before its last edit. The destination is
  # cleared even when the trash carries no versions -- an orphaned history
  # left there by an older deletion belongs to nobody, and a restored post
  # must not inherit it as its own past.
  trash_versions = File.join(trash_dir, 'versions')
  FileUtils.rm_rf(File.join(PostVersions.versions_root(CONTENT_DIR), year, slug))
  if Dir.exist?(trash_versions)
    FileUtils.mkdir_p(File.join(PostVersions.versions_root(CONTENT_DIR), year))
    FileUtils.mv(trash_versions, File.join(PostVersions.versions_root(CONTENT_DIR), year, slug))
  end
  FileUtils.rm_rf(trash_dir)

  puts t('cli.restored_label', path: new_path)

  if draft?(post)
    unless rebuild_and_deploy(t('cli.updating_preview'))
      warn t('cli.draft_saved_preview_pending', slug: slug)
      warn ''
      return
    end
    draft_decision_loop(slug, path: new_path)
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
rescue ArgumentError, TypeError
  # A date nothing can parse must not cost the list its whole screen.
  '----------'
end

def summary_row(post)
  "#{row_date(post)}  [#{post[:type]}]#{state_marker(post)}  #{post[:slug]}  #{post[:title]}"
end

def load_posts_summary
  PathGlob.under(CONTENT_DIR, '*', '*.json').filter_map { |f| post_summary(f) }
end

def cmd_list(filters)
  posts = load_posts_summary.select do |p|
    next false if filters[:tag] && !p[:tags].map(&:downcase).include?(filters[:tag].downcase)
    next false if filters[:type] && p[:type] != filters[:type]
    next false if filters[:drafts] && p[:state] != DRAFT

    true
  end
  # A post whose date is missing or unreadable sorts last instead of
  # ending the command: `list` is one of the ways somebody goes LOOKING for
  # the post that is broken, and a raw comparison error out of sort_by
  # named neither the file nor the problem.
  posts.sort_by! { |p| p[:date].to_s }
  posts.reverse!
  posts.each { |p| puts summary_row(p) }
  drafts = posts.count { |p| p[:state] == DRAFT }
  count = t('cli.post_count', count: posts.size, drafts_suffix: drafts.positive? ? t('cli.drafts_suffix', count: drafts) : '')
  # The tally is for a person, so it goes where a person is looking. Down
  # a pipe it would be three more lines that are not posts -- and this
  # command exists to be piped, so `| wc -l` has to answer the question
  # it looks like it is answering.
  if $stdout.tty?
    puts count
    puts
  else
    warn count
  end
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
  PathGlob.under(CONTENT_DIR, '*', '*.json').filter_map do |file|
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

  # Keyed by the query too: the one line whose whole job is explaining
  # the CURRENT match must not answer with the fragment that matched the
  # previous one after the user backspaces and types something else.
  cache_key = [slug, tokens.map(&:text).join(' ')]
  cache[cache_key] ||= begin
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
  cache[cache_key].empty? ? nil : cache[cache_key]
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
  # numeric_pick: false -- the rows carry no visible numbers, and real
  # archives have tags NAMED "365" or "5800"; resolving a typed number as
  # a row index silently filtered on whatever sat on that row and made
  # the numeric tag unreachable by typing.
  choice = Tui.menu(rows, hint: t('cli.browse_tag_menu_hint'), allow_text: true,
                          numeric_pick: false,
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

# Time.parse with the file's own sentence instead of a backtrace -- a
# hand-typed frontmatter date ("za tyden nekdy") used to end the run as
# an uncaught ArgumentError while the editor buffer sat recoverable.
def parse_frontmatter_date!(raw_value)
  Time.parse(raw_value)
rescue ArgumentError
  abort t('cli.frontmatter_date_invalid', value: raw_value)
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
      #
      # Two newlines, not one. Tui.browse leaves its last row open on
      # purpose (a newline per keypress would scroll the screen, which is
      # the very thing the frame exists to stop), so the first one only
      # closes the keys row -- the post's summary line was landing right
      # against it. The second is the blank line the dialog stands on.
      state.delete(:lines)
      puts
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
  # Esc leaves the browser standing on its last frame, whose keys row
  # Tui.browse deliberately left open. The first newline closes it, the
  # second is the one blank line this command ends with -- without them
  # the wizard's "press a key" was printed straight under the keys, with
  # nothing between.
  puts
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
  # A post whose date is missing or unreadable sorts last instead of
  # ending the command: `list` is one of the ways somebody goes LOOKING for
  # the post that is broken, and a raw comparison error out of sort_by
  # named neither the file nor the problem.
  posts.sort_by! { |p| p[:date].to_s }
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
  # Closing the prompt's row FIRST -- a pipe echoes nothing, so an abort
  # taken before this printed its refusal onto the prompt itself. The other
  # numbered pickers here (pick_among_years, address_pick) already close
  # theirs on the line after the read, for the same reason.
  puts
  abort t('cli.cancelled_empty') if input.empty?

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
  # Both layouts, the way restore_post's own lookup already does: posts have
  # been keyed by year inside the trash since the content tree was, and this
  # glob still described the flat one -- so `./blog.sh restore` with no slug,
  # and the wizard's whole Trash entry, answered "Trash is empty" over a full
  # trash. The engine's only undo, unreachable except by typing a slug the
  # author would have to remember.
  posts = (PathGlob.under(TRASH_DIR, '*', '*', 'post.json') +
           PathGlob.under(TRASH_DIR, '*', 'post.json'))
         .uniq.sort.filter_map { |f| post_summary(f) }
  # ...and the media `check --repair` set aside for posts that were never
  # deleted. Without these the list said "the trash is empty" over files
  # the engine itself had just put there and promised were restorable.
  media_only = PathGlob.under(TRASH_DIR, '*', '*', 'media').filter_map do |dir|
    slug = File.basename(File.dirname(dir))
    next if File.exist?(File.join(File.dirname(dir), 'post.json'))
    next if posts.any? { |p| p[:slug] == slug }

    # Same filter, and here it decides more than a number: a directory
    # whose files all begin with a dot counted as zero and was dropped
    # from the picker entirely -- hidden from the only undo the engine
    # has, rather than merely mislabelled.
    count = Dir.children(dir).reject { |f| SYSTEM_CRUFT.match?(f) }.size
    next if count.zero?

    # A date Time.parse can read: the row that draws this list parses it,
    # and a bare year ("2026") is an ArgumentError -- which took down the
    # whole trash picker, and with it the only undo the engine has.
    { slug: slug, title: t('cli.restore_media_count', count: count),
      date: "#{File.basename(File.dirname(File.dirname(dir)))}-01-01T00:00:00+00:00" }
  end
  posts + media_only.uniq { |entry| entry[:slug] }
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

# The address a media file was downloaded from, carried over from the
# stored post exactly as a poster and an embed's player are -- and for the
# same reason: markdown has no way to say it, so MarkdownParser hands the
# blocks back without it.
#
# What it costs to lose is the next import. `src` is the only record of
# where a file came from -- nothing in a JPEG remembers -- and it is what
# lets a re-import recognise the files this archive already holds instead
# of fetching every one of them again. Editing one imported post used to
# quietly hand that post's images back to the network.
#
# Keyed per media entry rather than per block, because a gallery is one
# block with many files and each of them came from its own address.
def restore_media_src(blocks, original_blocks)
  stored = {}
  each_media_entry(original_blocks) do |entry|
    name = entry['url'].to_s
    stored[name] ||= entry['src'] if !name.empty? && entry['src']
  end
  return if stored.empty?

  each_media_entry(blocks) do |entry|
    next if entry['src']

    src = stored[entry['url'].to_s]
    entry['src'] = src if src
  end
end

# Every media entry in a list of blocks -- the files themselves and a
# video's poster, which is a file with an address of its own.
def each_media_entry(blocks)
  Array(blocks).each do |block|
    next unless block.is_a?(Hash)

    %w[media poster].each do |key|
      entries = block[key]
      next unless entries.is_a?(Array)

      entries.each { |entry| yield entry if entry.is_a?(Hash) }
    end
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
def rebuild_and_deploy(reason = nil, full: false)
  Publishing.rebuild_and_deploy(reason || t('cli.default_rebuild_reason'), full: full)
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
def cmd_rebuild(full: false)
  return if rebuild_and_deploy(nil, full: full)

  # The lock's own exit code, same as the build and deploy scripts leave
  # with: somebody ran this by hand, and exit 0 reads as "a deploy
  # happened" to whatever invoked it. A genuine failure keeps exit 0 --
  # the .deploy-pending marker means the next scheduled run finishes the
  # job, which is what the lines above have just promised. In the wizard
  # the SystemExit is caught like every other cmd_* abort and only ends
  # this menu entry, not the session.
  exit RunLock::BUSY_EXIT if Publishing.stopped_on_busy_lock?
end

# --- empty ------------------------------------------------------------
#
# The way OUT of the two places the engine keeps things after you are done
# with them. Both had a way back -- `restore` for the trash, the version
# picker in `props` -- and no way out at all: emptying either meant `rm` on
# the server, which on a container install means `docker exec` without an
# alias. So both grew and nobody could say by how much.
#
# Confirmed by typing the COUNT rather than a yes: `delete` has you type the
# slug, and a trash has no slug to repeat back. The number is the one thing
# the person has just been shown, and typing it means having read it.
def confirm_count(prompt_key, count:, size:)
  print t(prompt_key, count: count, size: FileSize.human(size))
  answer = $stdin.gets&.strip
  return true if answer == count.to_s

  puts t('cli.empty_cancelled')
  false
end

def dir_size(path)
  PathGlob.under(path, '**', '*').sum { |f| File.file?(f) ? File.size(f) : 0 }
end

# Every trashed post, in both shapes: today's trash/<year>/<slug>/ and the
# flat trash/<slug>/ an installation from before the trash grew years left
# behind. `restore` reads both, so `empty` has to delete both -- otherwise
# half of it stays and the count somebody was shown was a lie.
def trashed_dirs
  return [] unless Dir.exist?(TRASH_DIR)

  (PathGlob.under(TRASH_DIR, '*', '*', 'post.json') +
   PathGlob.under(TRASH_DIR, '*', 'post.json')).map { |f| File.dirname(f) }.uniq.sort
end

def cmd_empty_trash
  dirs = trashed_dirs
  if dirs.empty?
    puts t('cli.empty_trash_none')
    return
  end

  size = dirs.sum { |d| dir_size(d) }
  return unless confirm_count('cli.empty_trash_confirm', count: dirs.length, size: size)

  dirs.each { |d| FileUtils.rm_rf(d) }
  # The year directories the posts sat in, when nothing else is left in
  # them: an empty trash should look empty.
  PathGlob.under(TRASH_DIR, '*').each do |d|
    Dir.rmdir(d) if File.directory?(d) && Dir.children(d).empty?
  rescue SystemCallError
    nil
  end
  puts t('cli.empty_trash_done', count: dirs.length, size: FileSize.human(size))
end

# The last version of each post stays. They exist to answer "give me back
# what I just overwrote", and that answer is the newest one -- emptying
# them completely would take away the thing they are for.
def cmd_empty_versions
  root = PostVersions.versions_root(CONTENT_DIR)
  dirs = Dir.exist?(root) ? PathGlob.under(root, '*', '*').select { |d| File.directory?(d) } : []
  doomed = dirs.flat_map { |d| PathGlob.under(d, '*.json').sort[0...-1] }
  if doomed.empty?
    puts t('cli.empty_versions_none')
    return
  end

  size = doomed.sum { |f| File.size(f) }
  return unless confirm_count('cli.empty_versions_confirm', count: doomed.length, size: size)

  doomed.each { |f| File.unlink(f) }
  puts t('cli.empty_versions_done', count: doomed.length, size: FileSize.human(size))
end

def cmd_empty(what)
  case what
  when 'trash' then cmd_empty_trash
  when 'versions' then cmd_empty_versions
  else abort t('cli.empty_what')
  end
end

def print_usage
  # The identity block above the usage: "what am I even running, and
  # where" is the first question of someone reading help on a server
  # with more than one install on it.
  puts SiteHeader.render
  puts
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

# The identity block, the question, the choices and the keys, as one frame.
# The identity is part of the frame rather than something printed once at
# startup: it answers "which blog am I even connected to?", which is the
# question of anyone who runs this against more than one site, and a frame
# that is repainted cannot lose it the way a scrolling screen did.
# Returns the rows and how many of them at the end are the keys, which the
# frame must not drop on a short window. The menu scrolls like the queue
# does rather than running off the bottom: six entries fit almost anywhere,
# but "almost" is what a split terminal on a laptop breaks.
def wizard_frame_lines(selected, offset, window)
  lines = wizard_header.to_s.chomp.lines.map(&:chomp)
  lines << ''
  lines << t('cli.wizard_prompt_action')
  lines << ''
  WIZARD_MENU[offset, window].to_a.each_with_index do |(_, desc), i|
    lines << if (offset + i) == selected
               Tui.paint("› #{Tui.truncate_to_width(Tui.strip_ansi(desc), Tui.term_width - 2)}", :invert)
             else
               "  #{Tui.truncate_ansi(desc, Tui.term_width - 2)}"
             end
  end
  lines << ''
  hint = Tui.paint(t('cli.wizard_menu_hint', count: WIZARD_MENU.size), :dim)
  keys = Tui.fold_prompt(hint, Tui.term_width).lines.map(&:chomp)
  [lines + keys, keys.size + 1]
end

def run_wizard_screen
  selected = 0
  offset = 0
  Tui.screen do |screen|
    loop do
      # Three rows of identity, two blanks, the question, the blank above
      # the keys and the keys themselves: what is left is the menu.
      window = [WIZARD_MENU.size, [Tui.term_height - 9, 2].max].min
      offset = Tui.clamp_offset(selected, offset, window, WIZARD_MENU.size)
      lines, keep = wizard_frame_lines(selected, offset, window)
      screen.paint(lines, keep_last: keep)
      key = screen.key
      chosen = nil

      case key
      when :resize then next
      when :up then selected = (selected - 1) % WIZARD_MENU.size
      when :down then selected = (selected + 1) % WIZARD_MENU.size
      when :home then selected = 0
      when :end then selected = WIZARD_MENU.size - 1
      when :enter then chosen = selected
      when :escape then break
      when String
        break if %w[q 0].include?(key)

        # Quick select keeps working, and moves the cursor as it goes, so
        # the frame under the action names the same row the digit chose.
        if key =~ /\A[1-9]\z/ && key.to_i <= WIZARD_MENU.size
          selected = key.to_i - 1
          chosen = selected
        end
      end
      next if chosen.nil?

      # The chosen action gets the terminal: some of them are screens of
      # their own (the queue), some print more than a frame can hold (a
      # build). Either way the wizard's frame comes back afterwards.
      screen.leave(t('cli.wizard_continue_prompt')) { run_wizard_choice(WIZARD_MENU[chosen].first) }
    end
  end
  # A blank line to sit on the way out, so the shell prompt does not land
  # flush against the last frame. It takes two: Tui.frame ends its last row
  # without a newline, so the first only closes that row -- one alone left
  # the shell prompt on the line immediately under the keys.
  puts
  puts
end

def run_wizard
  # In a terminal the wizard is a screen that stays put (digits still work
  # as quick select, Esc exits). Piped input keeps the numbered prompt.
  if Tui.interactive?
    run_wizard_screen
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

# Every screen-bound command opens with the identity block -- which
# engine, which site, which mode. The wizard prints (and after every
# clear reprints) its own copy, `version`'s output IS the identity,
# help puts it above the usage, and a piped stdout gets data only:
# `./blog.sh list | wc -l` must keep counting posts, not banner lines.
HEADER_MODES = %w[add edit props publish unpublish schedule queue delete
                  restore toot bluesky rebuild preview list browse].freeze
if HEADER_MODES.include?(command) && $stdout.tty?
  puts SiteHeader.render(extra: t('cli.header_mode', mode: command))
  puts
end

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
  when 'empty'
    cmd_empty(ARGV.shift)
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
    # Read here rather than inside cmd_rebuild, the way `list` and `browse`
    # read their filters: the dispatcher is where this file turns a command
    # line into arguments, and the wizard calls cmd_rebuild with none.
    cmd_rebuild(full: ARGV.include?('--full'))
  when 'preview'
    # A local static server over the build output -- the quickest way to
    # look at the site before deploying anywhere.
    unless Dir.exist?(File.join(ROOT, 'public.nosync'))
      abort t('cli.preview_missing_public')
    end
    # "preview draft" is a thing somebody types, and to_i turned it into
    # port 0 -- the system then handed out a random port and the line on
    # screen said http://localhost:0/, which is not where it is listening.
    asked = ARGV.shift || '8000'
    abort t('cli.preview_bad_port', value: asked) unless asked.match?(/\A\d{1,5}\z/) && asked.to_i.between?(1, 65_535)

    port = asked.to_i
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
