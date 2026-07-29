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
require_relative '../lib/mastodon_poster'
require_relative '../lib/site_config'
require_relative '../lib/markdown_parser'
require_relative '../lib/markdown_writer'
require_relative '../lib/media_dimensions'
require_relative '../lib/slug'
require_relative '../lib/content_type'
require_relative '../lib/i18n'

def t(key, **vars)
  I18n.t(key, **vars)
end

ROOT = File.expand_path('..', __dir__)
CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
MEDIA_DIR = File.join(ROOT, 'media.nosync')
INCOMING_DIR = File.join(ROOT, 'incoming')
TRASH_DIR = File.join(ROOT, 'trash')
SITE_BASE_URL = ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')

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

FRONTMATTER_KEYS = %w[title tags type date].freeze

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
    input = $stdin.gets&.strip
    abort t('cli.cancelled_nothing_saved') if input&.downcase == t('cli.cancel_word')
  end
end

# Deletes each source image that was actually copied this run, but only if it
# came from incoming/ -- that's a disposable SFTP staging area, so once a
# photo has been copied into media/ its incoming/ copy is just clutter
# (keeping incoming/ empty makes it obvious which uploads are still pending).
# Sources outside incoming/ (e.g. a normal Mac path) are the author's own
# files and are never touched.
def cleanup_incoming(media_files)
  media_files.each_key do |src|
    next unless src

    expanded = File.expand_path(src)
    next unless expanded.start_with?("#{File.expand_path(INCOMING_DIR)}/")

    File.delete(expanded) if File.exist?(expanded)
  end
end

# --- editor round-trip -------------------------------------------------

def edit_in_editor(initial_content, hint_comment)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'post.md')
    File.write(path, "#{hint_comment}#{initial_content}")
    editor = ENV['EDITOR'] || ENV['VISUAL'] || 'nano --breaklonglines --softwrap'
    system(*Shellwords.split(editor), path) || abort("$EDITOR (#{editor}) failed")
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

def build_frontmatter(title:, tags:, type:, date:)
  lines = ['---']
  lines << "title: #{title}"
  lines << "tags: #{tags}"
  lines << "type: #{type}" if type
  lines << "date: #{date}"
  lines << '---'
  "#{lines.join("\n")}\n\n"
end

# --- Mastodon comments -----------------------------------------------------

# Posts a "reply here to comment" toot for a freshly-written post and returns
# its URL (or nil, e.g. if SITE_BASE_URL / MASTODON_ACCESS_TOKEN aren't set --
# see lib/mastodon_poster.rb). Never raises: a failed toot must not block
# writing the post itself.
PEREX_LENGTH = 250
TOOT_LENGTH = 500
TOOT_RECENCY_WINDOW = 24 * 60 * 60 # seconds; posts dated further from "now" than this (e.g. backfilled from an old Mastodon thread) don't get an auto toot

# Up to `max_length` chars of the post's plain text (capped at PEREX_LENGTH),
# trimmed to a whole word and marked with an ellipsis if it got cut off.
def perex_for(blocks, max_length = PEREX_LENGTH)
  limit = [max_length, PEREX_LENGTH].min
  # Soft line breaks the author typed inside a paragraph (just to make the
  # source readable) are invisible once rendered as HTML, but Mastodon shows
  # a toot as plain text -- so collapse all internal whitespace, including
  # newlines, down to single spaces before excerpting.
  plain = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip
  return plain if plain.length <= limit
  return '' if limit <= 0

  "#{plain[0, limit].sub(/\s+\S*\z/, '')}…"
end

def hashtags_for(tags)
  tags.map { |t| "##{t.to_s.gsub(/\s+/, '')}" }.join(' ')
end

# title/url/hashtags must never be truncated (a cut-off URL is a dead link,
# a cut-off hashtag is a broken one) -- only the perex shrinks to make the
# whole toot fit under Mastodon's TOOT_LENGTH limit.
def post_toot(title:, slug:, year:, blocks:, tags:, date:, force: false)
  if SITE_BASE_URL.to_s.empty?
    warn t('cli.base_url_missing_toot')
    return nil
  end

  if !force && (date - Time.now).abs > TOOT_RECENCY_WINDOW
    warn t('cli.backdated_no_toot')
    return nil
  end

  post_url = "#{SITE_BASE_URL.chomp('/')}/posts/#{year}/#{slug}/"
  hashtags = hashtags_for(tags)
  fixed_length = [title, post_url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n").length
  budget = TOOT_LENGTH - fixed_length - 2 # 2 = the "\n\n" the perex adds once inserted

  parts = [title, perex_for(blocks, budget), post_url, hashtags].reject { |p| p.to_s.strip.empty? }
  MastodonPoster.publish(parts.join("\n\n"))
end

# --- commands ------------------------------------------------------------

def cmd_add
  # The date the template suggests is kept aside: at publish time it's used
  # to tell whether the author touched the date field at all (see publish_draft).
  suggested = Time.parse(Time.now.strftime('%Y-%m-%d %H:%M'))
  template = build_frontmatter(title: '', tags: '', type: '', date: suggested.strftime('%Y-%m-%d %H:%M')) +
             "First paragraph's text.\n"
  raw = edit_in_editor(template, FRONTMATTER_HINT)

  # Editor closed without saving (or saved untouched) leaves the template
  # byte-identical -- treat that as "nothing happened": no post, no toot,
  # no rebuild question. (This is how an accidental empty-template post once
  # made it all the way to a published Mastodon toot.)
  if raw == template
    warn t('cli.template_unchanged')
    warn ''
    return
  end

  meta, body = MarkdownParser.parse_frontmatter(raw)
  abort_on_double_frontmatter(body)

  if body.strip.empty?
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
  fill_image_dimensions(blocks, media_files)

  slug_source = title || (blocks.find { |b| b['type'] == 'text' } || {})['text']
  slug = Slug.slugify(slug_source.to_s.split(/\s+/).first(8).join(' '))
  slug = "post-#{date.to_i}" if slug.empty?

  # `add` never publishes directly any more: it always creates a draft only
  # visible through a hidden preview address, and publishing is a separate,
  # deliberate decision (draft_decision_loop). The Mastodon toot is therefore
  # only sent alongside that decision -- it used to go out immediately at
  # creation, which doesn't make sense for drafts.
  post = {
    'slug' => slug,
    'title' => title,
    'date' => date.iso8601,
    'created_at' => suggested.iso8601,
    'state' => DRAFT,
    'draft_token' => SecureRandom.hex(8),
    'tags' => tags,
    'content' => blocks,
    'source' => { 'platform' => 'manual' }
  }
  post['type'] = type if type

  path = PostWriter.write(post, media_files: media_files)
  cleanup_incoming(media_files)
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
    puts t('cli.preview_label', url: draft_url(post))
    puts
    print t('cli.what_next_prompt')
    case $stdin.gets&.strip.to_s.downcase
    when 'p' then return publish_draft(slug)
    when 'e' then edit_post(slug)
    when 'd', ''
      puts
      puts t('cli.left_as_draft', slug: slug)
      puts
      return
    else puts t('cli.unknown_choice_pde')
    end
  end
end

def toot_on_publish(post, slug, year, date)
  force = false
  if (date - Time.now).abs > TOOT_RECENCY_WINDOW
    print t('cli.date_outside_window_prompt', date: date.strftime(t('date_format')))
    return nil unless $stdin.gets&.strip.to_s.downcase.start_with?(t('cli.confirm_yes_char'))

    force = true
  end

  post_toot(title: post['title'], slug: slug, year: year, blocks: post['content'],
            tags: post['tags'] || [], date: date, force: force)
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
  untouched = post['created_at'] && post['date'] == post['created_at']
  date = untouched ? Time.now : Time.parse(post['date'])
  puts(untouched ? t('cli.publish_date_now', date: date.strftime(t('date_time_format')))
                 : t('cli.publish_date_kept', date: date.strftime(t('date_time_format'))))

  old_year = File.basename(File.dirname(path))
  new_year = date.year.to_s

  updated = post.merge('state' => PUBLISHED, 'date' => date.iso8601)
  updated.delete('draft_token')

  new_path = File.join(CONTENT_DIR, new_year, "#{slug}.json")
  if new_year != old_year
    FileUtils.mkdir_p(File.dirname(new_path))
    old_media = File.join(MEDIA_DIR, old_year, slug)
    FileUtils.mv(old_media, File.join(MEDIA_DIR, new_year, slug)) if Dir.exist?(old_media)
    File.delete(path)
  end
  File.write(new_path, JSON.pretty_generate(updated))

  mastodon_url = toot_on_publish(updated, slug, new_year, date)
  if mastodon_url
    updated['mastodon_url'] = mastodon_url
    File.write(new_path, JSON.pretty_generate(updated))
  end

  puts t('cli.published_label', path: new_path)
  rebuild_and_deploy(t('cli.publishing')) || return
  # No extra `puts` before "Done:" -- rebuild_and_deploy ended with a blank
  # line after its own "Done: uploaded...", same doubling as
  # draft_decision_loop above.
  puts t('cli.done_label', url: published_url(slug, new_year))
  puts t('cli.backdated_note') unless untouched
  puts
end

def find_post_path(slug)
  Dir.glob(File.join(CONTENT_DIR, '*', "#{slug}.json")).first
end

# A standalone (re-)send of the comment toot -- works for any published
# slug, not just at the moment of publish. Typically for imported posts
# without a toot, or when the original one was lost/deleted. Rejects a
# draft, since the toot carries published_url and would point at a
# nonexistent page before publishing. An existing mastodon_url is never
# overwritten -- there's no reason for a second toot on the same post (see
# unpublish, where the old one can be deleted).
def cmd_toot(slug)
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
  mastodon_url = toot_on_publish(post, slug, year, date)
  unless mastodon_url
    warn t('cli.toot_failed')
    warn ''
    return
  end

  File.write(path, JSON.pretty_generate(post.merge('mastodon_url' => mastodon_url)))
  puts t('cli.tooted', url: mastodon_url)
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

  updated = post.merge('state' => DRAFT, 'draft_token' => SecureRandom.hex(8), 'created_at' => post['date'])
  updated.delete('mastodon_url')
  File.write(path, JSON.pretty_generate(updated))
  puts t('cli.reverted_to_draft', path: path)

  final_slug = File.basename(path, '.json')
  unless rebuild_and_deploy(t('cli.updating_preview'))
    warn t('cli.draft_saved_preview_pending', slug: final_slug)
    warn ''
    return
  end

  draft_decision_loop(final_slug)
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

  post = JSON.parse(File.read(path, encoding: 'utf-8'))
  year = File.basename(File.dirname(path))
  media_dir = File.join(MEDIA_DIR, year, slug)

  date = Time.parse(post['date'])
  frontmatter = build_frontmatter(
    title: post['title'].to_s,
    tags: (post['tags'] || []).join(', '),
    type: post['type'],
    date: date.strftime('%Y-%m-%d %H:%M')
  )
  body = MarkdownWriter.blocks_to_markdown(post['content'], media_dir)

  raw = edit_in_editor(frontmatter + body, FRONTMATTER_HINT)

  # Same no-op guard as cmd_add: editor closed without saving (or saved
  # untouched) means nothing to do -- skip the save and the rebuild question.
  if raw == frontmatter + body
    puts t('cli.no_changes')
    puts
    return
  end

  meta, new_body = MarkdownParser.parse_frontmatter(raw)
  abort_on_double_frontmatter(new_body)

  new_date = meta['date'].to_s.empty? ? date : Time.parse(meta['date'])
  new_title = meta['title'].to_s.empty? ? nil : meta['title']
  new_tags = meta['tags'].to_s.split(',').map(&:strip).reject(&:empty?)
  new_type = meta['type'].to_s.empty? ? nil : meta['type']

  blocks, media_files, missing = MarkdownParser.parse_body(new_body, media_dir, incoming_dir: INCOMING_DIR)
  wait_for_missing_images(missing)
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
    print t('cli.confirm_continue_yes')
    abort t('cli.cancelled_nothing_saved') unless $stdin.gets&.strip == 'yes'
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
  updated['mastodon_url'] = post['mastodon_url'] if post['mastodon_url']
  updated['created_at'] = post['created_at'] if post['created_at']
  updated['draft_token'] = post['draft_token'] if post['draft_token']

  if new_dir != File.dirname(path)
    File.delete(path)
    FileUtils.mv(media_dir, new_media_dir) if Dir.exist?(media_dir)
  end

  FileUtils.mkdir_p(new_media_dir) if media_files.any?
  media_files.each do |src, filename|
    FileUtils.cp(src, File.join(new_media_dir, filename))
  end
  cleanup_incoming(media_files)

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

  File.write(new_path, JSON.pretty_generate(updated))
  puts
  puts t('cli.edited_label', path: new_path)
  draft?(updated) ? rebuild_and_deploy(t('cli.updating_preview')) : maybe_rebuild
end

def cmd_delete(slug)
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
    return
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
def post_summary(file)
  post = JSON.parse(File.read(file, encoding: 'utf-8'))
  { slug: post['slug'], date: post['date'], title: post['title'],
    type: ContentType.dominant(post), tags: post['tags'] || [],
    state: post['state'] || PUBLISHED }
end

def load_posts_summary
  Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).map { |f| post_summary(f) }
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
  posts.each do |p|
    date = Time.parse(p[:date]).strftime('%Y-%m-%d')
    puts "#{date}  [#{p[:type]}]#{p[:state] == DRAFT ? '  [DRAFT]' : ''}  #{p[:slug]}  #{p[:title]}"
  end
  drafts = posts.count { |p| p[:state] == DRAFT }
  puts t('cli.post_count', count: posts.size, drafts_suffix: drafts.positive? ? t('cli.drafts_suffix', count: drafts) : '')
end

RECENT_LIST_COUNT = 10

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

  posts.each_with_index do |p, i|
    date = Time.parse(p[:date]).strftime('%Y-%m-%d')
    puts "#{i + 1}) #{date}  [#{p[:type]}]#{p[:state] == DRAFT ? '  [DRAFT]' : ''}  #{p[:slug]}  #{p[:title]}"
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
  Dir.glob(File.join(TRASH_DIR, '*', 'post.json')).map { |f| post_summary(f) }
end

# Lets `restore` be called with no slug: offers the trash's contents, same
# pattern as the other pick_*_interactively helpers.
def pick_trash_interactively
  trashed = trash_summary
  trashed.sort_by! { |p| p[:date] }
  trashed.reverse!
  pick_from_list(trashed.first(RECENT_LIST_COUNT), t('cli.trash_empty'))
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
    end
  end
end

# Build and deploy as one question. It used to only ask about the build,
# with deploy called separately -- understandable back when deploying meant
# uploading thousands of files. Today one new post costs seven to nine
# files, so there's no reason to split it into two steps and risk the
# second one being forgotten.
#
# --prune is deliberately included: after `delete` (and after an edit that
# changes the slug or the date's year), live pages remain on the deploy
# target that the build no longer generates. Without prune, nothing would
# ever clean them up.
def rebuild_and_deploy(reason = nil)
  reason ||= t('cli.default_rebuild_reason')
  puts
  puts "#{reason}…"
  unless system('ruby', File.join(ROOT, 'build', 'build_blog.rb'))
    warn t('cli.build_failed')
    return false
  end

  return true if system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--prune')

  warn t('cli.deploy_failed')
  false
end

def maybe_rebuild
  puts
  print t('cli.rebuild_prompt')
  return if $stdin.gets&.strip.to_s.downcase == 'n'

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

# [internal name for dispatch, menu label] -- always without a slug; post
# selection (if the activity needs it) happens in the matching
# pick_*_interactively.
WIZARD_MENU = [
  ['add', t('cli.wizard_menu_add')],
  ['edit', t('cli.wizard_menu_edit')],
  ['publish', t('cli.wizard_menu_publish')],
  ['unpublish', t('cli.wizard_menu_unpublish')],
  ['delete', t('cli.wizard_menu_delete')],
  ['restore', t('cli.wizard_menu_restore')],
  ['toot', t('cli.wizard_menu_toot')],
  ['list', t('cli.wizard_menu_list')],
  ['rebuild', t('cli.wizard_menu_rebuild')]
].freeze

def run_wizard_choice(command)
  case command
  when 'add' then cmd_add
  when 'edit' then cmd_edit(pick_slug_interactively)
  when 'publish' then cmd_publish(pick_draft_interactively)
  when 'unpublish' then cmd_unpublish(pick_published_interactively)
  when 'delete' then cmd_delete(pick_slug_interactively)
  when 'restore' then cmd_restore(pick_trash_interactively)
  when 'toot' then cmd_toot(pick_slug_interactively)
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

def run_wizard
  puts t('cli.wizard_greeting')

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

if command.nil?
  run_wizard
else
  case command
  when 'add'
    cmd_add
  when 'edit'
    slug = ARGV.shift || pick_slug_interactively
    cmd_edit(slug)
  when 'delete'
    slug = ARGV.shift || pick_slug_interactively
    cmd_delete(slug)
  when 'restore'
    slug = ARGV.shift || pick_trash_interactively
    cmd_restore(slug)
  when 'publish'
    slug = ARGV.shift || pick_draft_interactively
    cmd_publish(slug)
  when 'unpublish'
    slug = ARGV.shift || pick_published_interactively
    cmd_unpublish(slug)
  when 'toot'
    slug = ARGV.shift || pick_slug_interactively
    cmd_toot(slug)
  when 'rebuild'
    cmd_rebuild
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
  else
    print_usage
    exit 1
  end
end
