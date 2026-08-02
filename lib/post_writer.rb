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
    dir = File.join(CONTENT_DIR, year)
    FileUtils.mkdir_p(dir)

    slug = unique_slug(post.fetch('slug'), dir, post['source'])
    post = post.merge('slug' => slug)

    if media_files.any?
      media_dir = File.join(MEDIA_DIR, year, slug)
      FileUtils.mkdir_p(media_dir)
      media_files.each do |src_path, filename|
        dest = File.join(media_dir, filename)
        FileUtils.cp(src_path, dest) unless File.exist?(dest)
      end
    end

    path = File.join(dir, "#{slug}.json")
    AtomicWrite.write_json(path, post)
    path
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

  def self.same_source?(existing_path, source)
    return false unless source

    existing = JSON.parse(File.read(existing_path, encoding: 'utf-8')) rescue nil
    existing_source = existing && existing['source']
    existing_source &&
      existing_source['platform'] == source['platform'] &&
      existing_source['account'] == source['account'] &&
      existing_source['original_id'] == source['original_id']
  end
end
