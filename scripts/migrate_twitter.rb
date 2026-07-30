#!/usr/bin/env ruby
# Migration: reads a Twitter/X "download your archive" export and writes
# original tweets into content/posts/<year>/<slug>.json via the shared
# PostWriter. Scope (per Daniel): standalone tweets only -- no replies, no
# old-style "RT @..." retweets, no quote-tweets (detected by an embedded
# twitter.com/x.com status link, since this export has no is_quote_status or
# retweeted_status field to check directly).
#
# Unlike the Tumblr migration, media is already sitting locally in the
# export's data/tweets_media/ dir -- no network fetch needed, just a copy.

require 'json'
require 'time'
require 'uri'
require_relative '../lib/post_writer'
require_relative '../lib/slug'
require_relative '../lib/site_config'

SiteConfig.use_site_timezone!

EXPORT_DIR = ARGV[0] || abort('usage: migrate_twitter.rb <path-to-extracted-export>')
DATA_DIR = File.join(EXPORT_DIR, 'data')
MEDIA_SRC_DIR = File.join(DATA_DIR, 'tweets_media')
ACCOUNT = JSON.parse(File.read(File.join(DATA_DIR, 'account.js'), encoding: 'utf-8').sub(/\A[^\[]*/, ''))
                .first['account']['username']

def quote_tweet?(tweet)
  (tweet.dig('entities', 'urls') || []).any? do |u|
    u['expanded_url'].to_s =~ %r{\Ahttps?://(?:twitter|x)\.com/\w+/status/\d+}
  end
end

def clean_tweet?(tweet)
  return false if tweet['in_reply_to_status_id']
  return false if tweet['full_text'].to_s.start_with?('RT @')
  return false if quote_tweet?(tweet)

  true
end

# Rewrites full_text into (plain_text, formatting[]): the media t.co link is
# dropped entirely (a media content block already carries that), other links
# get their t.co text swapped for the human-readable display_url with a
# 'link' formatting span, and @mentions get a 'link' span added in place
# (their visible text is already "@handle", nothing to replace).
def build_text_and_formatting(tweet)
  text = tweet['full_text'].to_s
  entities = tweet['entities'] || {}

  ops = []
  if (media_entry = entities['media']&.first)
    s, e = media_entry['indices'].map(&:to_i)
    ops << { start: s, end: e, action: :remove }
  end
  (entities['urls'] || []).each do |u|
    s, e = u['indices'].map(&:to_i)
    ops << { start: s, end: e, action: :replace, display: u['display_url'], url: u['expanded_url'] }
  end
  (entities['user_mentions'] || []).each do |m|
    s, e = m['indices'].map(&:to_i)
    ops << { start: s, end: e, action: :link_inplace, url: "https://twitter.com/#{m['screen_name']}" }
  end
  ops.sort_by! { |o| o[:start] }

  new_text = +''
  formatting = []
  cursor = 0
  ops.each do |op|
    next if op[:start] < cursor # overlapping entity (rare data quirk) -- skip rather than corrupt offsets

    new_text << text[cursor...op[:start]].to_s
    case op[:action]
    when :remove
      # drop the span
    when :replace
      start_pos = new_text.length
      new_text << op[:display].to_s
      formatting << { 'type' => 'link', 'url' => op[:url], 'start' => start_pos, 'end' => new_text.length }
    when :link_inplace
      start_pos = new_text.length
      new_text << text[op[:start]...op[:end]].to_s
      formatting << { 'type' => 'link', 'url' => op[:url], 'start' => start_pos, 'end' => new_text.length }
    end
    cursor = op[:end]
  end
  new_text << text[cursor..].to_s

  leading = new_text[/\A\s*/].length
  new_text = new_text.strip
  formatting.each { |f| f['start'] -= leading; f['end'] -= leading }
  formatting.reject! { |f| f['start'].negative? || f['start'] >= f['end'] }

  [new_text, formatting]
end

def best_video_variant(media)
  variants = (media.dig('video_info', 'variants') || []).select { |v| v['content_type'] == 'video/mp4' }
  variants.max_by { |v| v['bitrate'].to_i }
end

# Copies the export's already-local media file into media_files (source_path
# => desired_filename) and returns [filename, width, height], or nil if the
# expected local file isn't present.
def localize_media(tweet_id, media, media_files, counter)
  url = media['type'] == 'photo' ? (media['media_url_https'] || media['media_url']) : best_video_variant(media)&.fetch('url', nil)
  return nil unless url

  basename = File.basename(URI.parse(url).path)
  src = File.join(MEDIA_SRC_DIR, "#{tweet_id}-#{basename}")
  return nil unless File.exist?(src)

  ext = File.extname(basename)
  filename = format('%02d%s', counter[:value] += 1, ext)
  media_files[src] = filename

  size = media.dig('sizes', 'large') || {}
  [filename, size['w'], size['h']]
end

def build_content_blocks(tweet, media_files, counter)
  blocks = []

  text, formatting = build_text_and_formatting(tweet)
  unless text.empty?
    block = { 'type' => 'text', 'text' => text }
    block['formatting'] = formatting unless formatting.empty?
    blocks << block
  end

  media_list = tweet.dig('extended_entities', 'media') || tweet.dig('entities', 'media') || []
  media_list.each do |m|
    localized = localize_media(tweet['id_str'], m, media_files, counter)
    next unless localized

    filename, width, height = localized
    if m['type'] == 'photo'
      blocks << { 'type' => 'image', 'media' => [{ 'url' => filename, 'width' => width, 'height' => height }] }
    else
      blocks << { 'type' => 'video', 'media' => [{ 'url' => filename, 'width' => width, 'height' => height }] }
    end
  end

  blocks
end

def build_slug(tweet, text)
  slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
  slug = "tweet-#{tweet['id_str']}" if slug.empty?
  slug
end

raw = File.read(File.join(DATA_DIR, 'tweets.js'), encoding: 'utf-8')
tweets = JSON.parse(raw.sub(/\A[^\[]*/, '')).map { |t| t['tweet'] }
clean = tweets.select { |t| clean_tweet?(t) }
clean = clean.first(ENV['LIMIT'].to_i) if ENV['LIMIT']

count = 0
clean.each do |tweet|
  media_files = {}
  counter = { value: 0 }

  blocks = build_content_blocks(tweet, media_files, counter)
  next if blocks.empty?

  text_for_slug = blocks.find { |b| b['type'] == 'text' }&.fetch('text', '') || ''

  post = {
    'slug' => build_slug(tweet, text_for_slug),
    'title' => nil,
    'date' => Time.parse(tweet['created_at']).iso8601,
    'state' => 'published',
    'tags' => (tweet.dig('entities', 'hashtags') || []).map { |h| h['text'] },
    'content' => blocks,
    'source' => {
      'platform' => 'twitter',
      'account' => ACCOUNT,
      'post_url' => "https://twitter.com/#{ACCOUNT}/status/#{tweet['id_str']}",
      'original_id' => tweet['id_str']
    }
  }

  path = PostWriter.write(post, media_files: media_files)
  count += 1
  puts "wrote #{path} (#{media_files.size} media file(s))"
end

puts "Done. #{count} posts written (#{tweets.size - clean.size} skipped as reply/RT/quote, #{clean.size - count} skipped as empty)."
