require 'json'
require 'fileutils'
require 'time'
require_relative 'atomic_write'

module PostWriter
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  MEDIA_DIR = File.join(ROOT, 'media.nosync')

  # post: hash matching the post schema (slug, title, date, state, tags, content, source)
  # media_files: { source_path => desired_filename } to copy into media/<year>/<slug>/
  def self.write(post, media_files: {})
    date = Time.parse(post.fetch('date'))
    year = date.year.to_s

    # A post already imported from this exact source item is UPDATED, not
    # duplicated -- "matched on their source id" is a promise README and the
    # docs both make, and until now it only held while the slug-producing
    # text at the source never changed. A fixed typo in an RSS title, an
    # edited toot, and the re-import minted a second post under the new
    # slug while the old one sat next to it.
    #
    # The existing slug is kept on purpose: the URL is published, links and
    # announcement toots point at it, and a re-import must never move it
    # just because a title was edited at the source.
    existing_path = find_by_source(post['source'])
    if existing_path
      post = post.merge('slug' => File.basename(existing_path, '.json'))
      return update_matched(existing_path, post, year, media_files)
    end

    dir = File.join(CONTENT_DIR, year)
    FileUtils.mkdir_p(dir)
    slug = unique_slug(post.fetch('slug'), dir, post['source'])
    post = post.merge('slug' => slug)

    copy_media(media_files, year, slug)
    path = File.join(dir, "#{slug}.json")
    AtomicWrite.write_json(path, post)
    index[source_key(post['source'])] = path if source_key(post['source'])
    path
  end

  def self.copy_media(media_files, year, slug)
    return if media_files.empty?

    media_dir = File.join(MEDIA_DIR, year, slug)
    FileUtils.mkdir_p(media_dir)
    media_files.each do |src_path, filename|
      dest = File.join(media_dir, filename)
      FileUtils.cp(src_path, dest) unless File.exist?(dest)
    end
  end

  # Overwrites the matched post in place -- or moves it when the source
  # changed the item's date across a year boundary, since the build derives
  # both the URL and the media lookup from the date, and a file left in the
  # old year's directory with a new year's date loses its images (the same
  # inconsistency prompt_and_schedule used to create).
  def self.update_matched(existing_path, post, year, media_files)
    slug = post['slug']
    old_year = File.basename(File.dirname(existing_path))

    # Engine-side state the source can never know about. A re-import that
    # dropped mastodon_url severed the announcement thread -- the post's
    # stats and comments both hang off it -- which is the exact bug cmd_edit
    # had and fixed. state and draft_token are deliberately NOT carried
    # over: what the source says about published/draft wins on re-import,
    # same as it always has.
    old = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    %w[mastodon_url bluesky_url bluesky_uri].each do |key|
      post[key] = old[key] if old && old[key] && !post[key]
    end

    new_dir = File.join(CONTENT_DIR, year)
    new_path = File.join(new_dir, "#{slug}.json")

    if File.expand_path(new_path) != File.expand_path(existing_path)
      FileUtils.mkdir_p(new_dir)
      move_media_dir(File.join(MEDIA_DIR, old_year, slug), File.join(MEDIA_DIR, year, slug))
    end

    copy_media(media_files, year, slug)
    # Write first, delete second -- same ordering as Publishing.publish, so
    # a failure in between leaves the post twice (recoverable) rather than
    # not at all.
    AtomicWrite.write_json(new_path, post)
    File.delete(existing_path) if File.expand_path(new_path) != File.expand_path(existing_path)
    index[source_key(post['source'])] = new_path if source_key(post['source'])
    new_path
  end

  # mv with two cautions FileUtils.mv alone doesn't have: the target year
  # directory may not exist yet (mkdir_p, or the mv raises ENOENT), and the
  # target slug directory may already exist as an orphan -- mv would then
  # NEST the source inside it (media/<year>/<slug>/<slug>/) and the page
  # would lose its files. Merging file by file keeps both sides' contents.
  def self.move_media_dir(from, to)
    return unless Dir.exist?(from)

    if Dir.exist?(to)
      Dir.children(from).each do |f|
        dest = File.join(to, f)
        FileUtils.mv(File.join(from, f), dest) unless File.exist?(dest)
      end
      FileUtils.rmdir(from) if Dir.empty?(from)
    else
      FileUtils.mkdir_p(File.dirname(to))
      FileUtils.mv(from, to)
    end
  end

  # source id -> path of the post that owns it, across every year. Built
  # once per process (an import re-reading the archive for each of its
  # thousands of items would be quadratic), kept current by write. Only
  # sources with an original_id participate: manual posts all share
  # {platform: manual} and nothing else, and matching them to each other
  # would overwrite one author-written post with another.
  def self.index
    @index ||= Dir.glob(File.join(CONTENT_DIR, '*', '*.json')).each_with_object({}) do |file, acc|
      existing = JSON.parse(File.read(file, encoding: 'utf-8')) rescue nil
      key = existing && source_key(existing['source'])
      acc[key] = file if key
    end
  end

  def self.source_key(source)
    return nil unless source.is_a?(Hash)

    id = source['original_id']
    return nil if id.nil? || id.to_s.empty?

    [source['platform'], source['account'], id.to_s]
  end

  def self.find_by_source(source)
    key = source_key(source)
    return nil unless key

    path = index[key]
    path if path && File.exist?(path)
  end

  def self.unique_slug(base_slug, dir, source)
    n = 1
    loop do
      candidate = n == 1 ? base_slug : "#{base_slug}-#{n}"
      existing_path = File.join(dir, "#{candidate}.json")
      return candidate unless File.exist?(existing_path)
      return candidate if same_source?(existing_path, source)

      n += 1
    end
  end

  # The by-slug fallback behind the index. Requires an original_id for the
  # same reason the index does: two manual posts agree on platform, account
  # and (absent) id, so without the requirement a manual post whose slug
  # collided would silently overwrite the other one.
  def self.same_source?(existing_path, source)
    return false unless source_key(source)

    existing = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    source_key(existing && existing['source']) == source_key(source)
  end
end
