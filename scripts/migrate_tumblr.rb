#!/usr/bin/env ruby
# Migration: pulls posts from the Tumblr API in NPF format and writes them
# into content/posts/<year>/<slug>.json using the shared PostWriter.
#
# All media (photos, video posters, link posters) is downloaded and stored
# locally under media/<year>/<slug>/ -- nothing stays hotlinked to Tumblr's CDN.

require 'net/http'
require 'json'
require 'time'
require 'tmpdir'
require_relative '../lib/post_writer'
require_relative '../lib/slug'

API_KEY = ENV.fetch('TUMBLR_API_KEY') { abort 'set TUMBLR_API_KEY (source env.sh first)' }
BLOG = ARGV[0] || abort('usage: migrate_tumblr.rb <blog-name>.tumblr.com')
ACCOUNT = BLOG.split('.').first

def fetch_posts(blog, offset, retries = 3)
  uri = URI("https://api.tumblr.com/v2/blog/#{blog}/posts")
  uri.query = URI.encode_www_form(api_key: API_KEY, npf: true, limit: 20, offset: offset)
  JSON.parse(Net::HTTP.get(uri))
rescue StandardError => e
  raise if retries.zero?

  sleep 1
  fetch_posts(blog, offset, retries - 1)
end

# Downloads url to a tmp file, registers it in media_files with a unique
# filename, and returns that filename (to store as the local reference).
def localize(url, media_files, tmpdir, counter)
  return nil unless url

  ext = File.extname(URI.parse(url).path)
  ext = '.jpg' if ext.nil? || ext.empty?
  filename = format('%02d%s', counter.value += 1, ext)
  tmp_path = File.join(tmpdir, "#{counter.value}#{ext}")

  res = fetch_binary(url)
  return nil unless res

  File.binwrite(tmp_path, res)
  media_files[tmp_path] = filename
  filename
end

def fetch_binary(url, redirects = 5, retries = 3)
  return nil if redirects.zero?

  uri = URI(url)
  res =
    begin
      Net::HTTP.get_response(uri)
    rescue StandardError => e
      # Migrating 800+ posts hits transient connection resets often enough
      # that a single one shouldn't kill an hours-long run.
      if retries.positive?
        sleep 1
        return fetch_binary(url, redirects, retries - 1)
      end
      warn "fetch_binary gave up on #{url}: #{e.message}"
      return nil
    end

  case res
  when Net::HTTPRedirection
    fetch_binary(res['location'], redirects - 1, retries)
  when Net::HTTPSuccess
    res.body
  end
end

Counter = Struct.new(:value)

def map_block(block, media_files, tmpdir, counter)
  case block['type']
  when 'text'
    b = { 'type' => 'text', 'text' => block['text'] }
    b['subtype'] = block['subtype'] if block['subtype']
    b['formatting'] = block['formatting'] if block['formatting'] && !block['formatting'].empty?
    b
  when 'image'
    media = block['media'] || []
    largest = media.max_by { |m| m['width'].to_i }
    filename = largest && localize(largest['url'], media_files, tmpdir, counter)
    {
      'type' => 'image',
      'media' => [{ 'url' => filename, 'width' => largest && largest['width'], 'height' => largest && largest['height'] }],
      'alt_text' => block['alt_text'],
      'caption' => block['caption']
    }.compact
  when 'video'
    poster = (block['poster'] || []).first
    poster_filename = poster && localize(poster['url'], media_files, tmpdir, counter)

    # Self-hosted videos (e.g. provider "tumblr") carry a direct downloadable
    # file in `media`; YouTube/Instagram-style embeds don't -- they only ever
    # give us an oEmbed iframe/blockquote, which stays external.
    media = block['media']
    media_filename = media && localize(media['url'], media_files, tmpdir, counter)

    embed_html = block['embed_html']
    embed_html = nil if embed_html.to_s.strip.empty?
    # Tumblr bakes its own sandbox origin (safe.txmblr.com) into the iframe
    # src. YouTube checks `origin` against the actual embedding page and
    # rejects playback (error 153) if it doesn't match, so strip it -- an
    # embed with no origin param is accepted from any domain.
    embed_html = embed_html.gsub(/(?:&amp;|&)origin=[^&"]*/, '') if embed_html

    {
      'type' => 'video',
      'provider' => block['provider'],
      'url' => block['url'],
      'embed_html' => embed_html,
      'media' => media_filename ? [{ 'url' => media_filename, 'width' => media['width'], 'height' => media['height'] }] : nil,
      'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
    }.compact
  when 'link'
    poster = (block['poster'] || []).first
    poster_filename = poster && localize(poster['url'], media_files, tmpdir, counter)
    {
      'type' => 'link',
      'url' => block['url'],
      'title' => block['title'],
      'description' => block['description'],
      'site_name' => block['site_name'],
      'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
    }.compact
  end
end

def extract_title(content_blocks)
  first = content_blocks.first
  return [nil, content_blocks] unless first && first['type'] == 'text' && first['subtype'] == 'heading1'

  [first['text'], content_blocks[1..]]
end

offset = 0
total = nil
count = 0

loop do
  data = fetch_posts(BLOG, offset)
  posts = data.dig('response', 'posts') || []
  total ||= data.dig('response', 'blog', 'total_posts')
  break if posts.empty?

  posts.each do |p|
    media_files = {}
    counter = Counter.new(0)

    Dir.mktmpdir do |tmpdir|
      blocks = (p['content'] || []).map { |b| map_block(b, media_files, tmpdir, counter) }.compact

      # Reblogged posts carry their own content in `trail`; since every post here
      # is ours, that content is simply appended -- no separate attribution kept.
      (p['trail'] || []).each do |t|
        (t['content'] || []).each do |b|
          mapped = map_block(b, media_files, tmpdir, counter)
          blocks << mapped if mapped
        end
      end

      title, blocks = extract_title(blocks)

      slug = Slug.slugify(p['slug'])
      slug = Slug.slugify(p['summary']) if slug.empty?
      slug = "post-#{p['id']}" if slug.empty?

      post = {
        'slug' => slug,
        'title' => title,
        'date' => Time.parse(p['date']).iso8601,
        'state' => p['state'] == 'published' ? 'published' : 'draft',
        'tags' => p['tags'] || [],
        'content' => blocks,
        'source' => {
          'platform' => 'tumblr',
          'account' => ACCOUNT,
          'post_url' => p['post_url'],
          'original_id' => p['id']
        }
      }

      path = PostWriter.write(post, media_files: media_files)
      count += 1
      puts "wrote #{path} (#{media_files.size} media file(s))"
    end
  end

  offset += posts.size
  break if total && offset >= total
end

puts "Done. #{count} posts written."
