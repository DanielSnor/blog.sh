# frozen_string_literal: true

require 'json'
require 'time'
require 'uri'
require_relative '../entity_text'
require_relative '../slug'
require_relative 'html_blocks'

module Import
  # Imports a Twitter/X "download your archive" export. Standalone tweets
  # only: no replies, no old-style "RT @..." retweets, no quote-tweets --
  # what belongs in an archive is what you wrote on your own.
  #
  # Unlike the API-backed adapters this needs no network: the media is
  # already sitting in the export's data/tweets_media/, so it's a copy.
  class Twitter
    def initialize(export_dir)
      @export_dir = export_dir
      @data_dir = File.join(export_dir, 'data')
      @media_dir = File.join(@data_dir, 'tweets_media')
    end

    def label
      "Twitter/X (@#{account})"
    end

    # tweets.js runs to tens of megabytes on a full archive, and reading plus
    # parsing it is a silent minute or more -- worth saying out loud before
    # it starts.
    def preamble
      size = File.size(tweets_path) / 1_048_576.0
      "Reading #{tweets_path} (#{size.round(1)} MB)…"
    end

    def total
      @total
    end

    def each_item(&block)
      tweets = load_tweets
      @total = tweets.size
      tweets.each(&block)
    end

    # Every tweet is yielded and judged here rather than pre-filtered, so the
    # run's summary can report how many were replies, retweets or quotes the
    # same way it does for every other source.
    def map(item, media)
      return :reply if item['in_reply_to_status_id']
      return :retweet if item['full_text'].to_s.start_with?('RT @')
      return :quote if quote_tweet?(item)

      blocks = content_blocks(item, media)
      return :empty if blocks.empty?

      text = blocks.find { |b| b['type'] == 'text' }&.fetch('text', '') || ''
      {
        'slug' => build_slug(item, text),
        'title' => nil,
        'date' => Time.parse(item['created_at']).iso8601,
        'state' => 'published',
        'tags' => (item.dig('entities', 'hashtags') || []).map { |h| h['text'] },
        'content' => blocks,
        'source' => {
          'platform' => 'twitter',
          'account' => account,
          'post_url' => "https://twitter.com/#{account}/status/#{item['id_str']}",
          'original_id' => item['id_str']
        }
      }
    end

    private

    def tweets_path
      File.join(@data_dir, 'tweets.js')
    end

    # Both files are JavaScript assignments wrapping a JSON array, so the
    # prefix up to the opening bracket is dropped before parsing.
    def load_tweets
      raw = File.read(tweets_path, encoding: 'utf-8')
      JSON.parse(raw.sub(/\A[^\[]*/, '')).map { |t| t['tweet'] }
    end

    def account
      @account ||= begin
        raw = File.read(File.join(@data_dir, 'account.js'), encoding: 'utf-8')
        JSON.parse(raw.sub(/\A[^\[]*/, '')).first['account']['username']
      end
    end

    # This export has no is_quote_status or retweeted_status field, so a quote
    # is recognised by an embedded status link. That also catches a tweet
    # merely linking to another tweet -- deliberately, since the distinction
    # isn't in the data.
    def quote_tweet?(tweet)
      (tweet.dig('entities', 'urls') || []).any? do |u|
        u['expanded_url'].to_s =~ %r{\Ahttps?://(?:twitter|x)\.com/\w+/status/\d+}
      end
    end

    # Rewrites full_text into (plain_text, formatting[]): the media t.co link
    # is dropped entirely (a media content block already carries that), other
    # links get their t.co text swapped for the human-readable display_url
    # with a 'link' formatting span, and @mentions get a 'link' span added in
    # place (their visible text is already "@handle", nothing to replace).
    def text_and_formatting(tweet)
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

      new_text, formatting = decode_entities_in(new_text, formatting)

      leading = new_text[/\A\s*/].length
      new_text = new_text.strip
      formatting.each { |f| f['start'] -= leading; f['end'] -= leading }
      formatting.reject! { |f| f['start'].negative? || f['start'] >= f['end'] }

      [new_text, formatting]
    end

    # Twitter escapes <, > and & in full_text and never says so, so a tweet
    # about being "(jsem <38)" arrived as "(jsem &lt;38)" -- rendered as
    # &lt;38 on the page, and baked into twelve permanent addresses as
    # "-gt-" and "-amp-".
    #
    # Decoded HERE and not sooner, which is the whole difficulty: the entity
    # indices count the ESCAPED string. Checked against the real archive --
    # slicing the escaped text at a URL's indices returns the URL exactly,
    # slicing the decoded text returns it shifted by the entities in front
    # of it. Decoding first, which is the obvious fix, would walk every link
    # in the archive off its own words. So the ops run on the text as
    # delivered and the spans are moved afterwards, by however much the text
    # shrank ahead of them.
    def decode_entities_in(text, formatting)
      EntityText.decode(text, formatting)
    end

    def content_blocks(tweet, media)
      blocks = []

      text, formatting = text_and_formatting(tweet)
      unless text.empty?
        block = { 'type' => 'text', 'text' => text }
        block['formatting'] = formatting unless formatting.empty?
        blocks << block
      end

      media_list = tweet.dig('extended_entities', 'media') || tweet.dig('entities', 'media') || []
      media_list.each do |m|
        localized = localize(tweet['id_str'], m, media)
        next unless localized

        filename, width, height = localized
        type = m['type'] == 'photo' ? 'image' : 'video'
        blocks << { 'type' => type, 'media' => [{ 'url' => filename, 'width' => width, 'height' => height }] }
      end

      blocks
    end

    # Returns [filename, width, height], or nil when the file the export
    # should contain isn't there -- that media is then simply absent, rather
    # than the whole post failing.
    def localize(tweet_id, item, media)
      url = item['type'] == 'photo' ? (item['media_url_https'] || item['media_url']) : best_video_variant(item)&.fetch('url', nil)
      return nil unless url

      basename = File.basename(URI.parse(url).path)
      filename = media.from_file(File.join(@media_dir, "#{tweet_id}-#{basename}"))
      return nil unless filename

      size = item.dig('sizes', 'large') || {}
      [filename, size['w'], size['h']]
    end

    def best_video_variant(item)
      variants = (item.dig('video_info', 'variants') || []).select { |v| v['content_type'] == 'video/mp4' }
      variants.max_by { |v| v['bitrate'].to_i }
    end

    def build_slug(tweet, text)
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "tweet-#{tweet['id_str']}" : slug
    end
  end
end
