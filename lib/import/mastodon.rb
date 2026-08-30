# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../slug'
require_relative '../i18n'
require_relative 'html_blocks'

module Import
  # Imports a Mastodon account export -- the zip you get from Settings →
  # Import and export → Request your archive, unpacked. That's an
  # ActivityPub outbox plus the media files themselves, so this needs no
  # network and no token, and it holds the whole account rather than the
  # last page an API would hand out.
  #
  # Scope matches the other social sources: standalone posts only. Boosts
  # are someone else's writing, and replies are conversation -- on a
  # typical account they are the majority of everything (2984 of 5532 in
  # the archive this was built against).
  class Mastodon
    def initialize(export_dir)
      @export_dir = export_dir
      @polls = 0
      @withheld = Hash.new(0)
    end

    # The directory this export lives in. Media#from_file refuses any path
    # that resolves outside it -- an export naming a file on the importer's
    # own disk got it copied into the archive and published.
    def import_root
      @export_dir
    end


    def label
      "Mastodon (#{handle})"
    end

    def preamble
      "Reading #{outbox_path} (#{(File.size(outbox_path) / 1_048_576.0).round(1)} MB)…"
    end

    def total
      @total
    end

    def each_item(&block)
      items = JSON.parse(File.read(outbox_path, encoding: 'utf-8'))['orderedItems'] || []
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      return :boost unless item['type'] == 'Create'

      object = item['object'] || {}
      return :reply if object['inReplyTo']

      scope = visibility(object)
      @withheld[scope] += 1 unless scope == 'public'
      blocks = HtmlBlocks.parse(object['content'].to_s).blocks
      blocks.concat(poll_blocks(object))
      blocks.concat(attachment_blocks(object, media))
      return :empty if blocks.empty?

      {
        'slug' => build_slug(object, blocks),
        # A content warning summarises what follows, which is what a title
        # is -- so the post keeps its warning instead of losing it, and the
        # listing shows why it was hidden.
        'title' => presence(object['summary']),
        'date' => Time.parse(object['published']).iso8601,
        'state' => scope == 'direct' || scope == 'followers' ? 'draft' : 'published',
        'tags' => hashtags(object),
        # Mastodon's "unlisted" and blog.sh's mean the same thing: a real
        # address, kept out of the listings.
        'unlisted' => scope == 'unlisted' ? true : nil,
        'content' => blocks,
        'source' => {
          'platform' => 'mastodon',
          'account' => handle,
          'post_url' => object['url'] || object['id'],
          'original_id' => object['id'].to_s.split('/').last
        }
      }
    end

    # How many polls this run turned into a list. Said out loud because the
    # shape of the post changes: the options are the author's own words and
    # are kept, but they arrive as a list rather than as whatever the reader
    # remembers voting in.
    def postscript
      notes = []
      notes << I18n.t('import.note.mastodon_polls', count: @polls) if @polls.positive?
      held = @withheld['direct'] + @withheld['followers']
      notes << I18n.t('import.note.mastodon_withheld', count: held,
                                                       direct: @withheld['direct'],
                                                       followers: @withheld['followers']) if held.positive?
      notes << I18n.t('import.note.mastodon_unlisted', count: @withheld['unlisted']) if @withheld['unlisted'].positive?
      notes.empty? ? nil : notes.join(' ')
    end

    private

    # An archive is the WHOLE account, not the public timeline: the outbox
    # holds followers-only posts and direct messages beside the public ones.
    # Every standalone toot used to be written as `published`, so importing
    # your own archive put your own DMs on the public web -- 141 of 2548 in
    # the archive this was measured against, 132 of them direct messages --
    # with post pages, sitemap entries and feed items, and not a word in the
    # run's summary.
    #
    # Scope is in `to` and `cc`, exactly as ActivityPub puts it there:
    #   Public in `to`  -> public
    #   Public in `cc`  -> unlisted (an address, out of the listings)
    #   followers only  -> not public
    #   neither         -> a direct message
    # The last two become drafts: they keep the author's words in the archive
    # and off the site, which is the only reading of "not public" that cannot
    # publish something by accident.
    PUBLIC_URI = ['https://www.w3.org/ns/activitystreams#Public', 'as:Public', 'Public'].freeze

    # Strings rather than symbols, and deliberately: inside lib/import/ a
    # RETURNED SYMBOL means one thing, a skip reason the wizard has to have a
    # translation for, and tests/test_gaps.rb walks these files looking for
    # exactly that shape rather than trusting a list -- it has caught eleven
    # real omissions that way. A classification returned as :public would be
    # read as a skip reason nobody translated. Do not tidy these back.
    def visibility(object)
      to = Array(object['to'])
      cc = Array(object['cc'])
      return 'public' if to.any? { |a| PUBLIC_URI.include?(a) }
      return 'unlisted' if cc.any? { |a| PUBLIC_URI.include?(a) }
      return 'followers' if (to + cc).any? { |a| a.to_s.end_with?('/followers') }

      'direct'
    end

    # An ActivityPub Question carries its choices in oneOf (single answer)
    # or anyOf (multiple), each with a vote count in replies.totalItems,
    # plus votersCount and endTime. None of it was read: the post published
    # as a question with no answers -- "I'd like your opinion on this" and
    # then nothing -- and the run said nothing either, which is the opposite
    # of how everything else here treats content it cannot carry.
    #
    # The options ARE content: the author wrote them. So they are kept
    # rather than counted and dropped, and the votes go with them, because
    # an archived poll without its result is half the story. These are
    # settled results from an export, not a poll still running, so there is
    # nothing here that can mislead by being early.
    def poll_blocks(object)
      options = Array(object['oneOf'] || object['anyOf'])
      return [] if options.empty?

      @polls += 1
      items = options.map do |option|
        { 'text' => I18n.t('import.poll.option', name: option['name'].to_s,
                                                 votes: option.dig('replies', 'totalItems').to_i) }
      end
      [{ 'type' => 'text',
         'text' => I18n.t('import.poll.heading', voters: object['votersCount'].to_i) },
       { 'type' => 'list', 'style' => 'ul', 'items' => items }]
    end

    def outbox_path
      File.join(@export_dir, 'outbox.json')
    end

    def handle
      @handle ||= begin
        actor = JSON.parse(File.read(File.join(@export_dir, 'actor.json'), encoding: 'utf-8'))
        name = actor['preferredUsername']
        host = URI.parse(actor['id'].to_s).host rescue nil
        [name, host].compact.join('@')
      rescue StandardError
        File.basename(@export_dir)
      end
    end

    # Attachment urls are paths inside the export ("/media_attachments/…"),
    # so this is a copy rather than a download -- and the width/height the
    # archive records mean nothing has to be measured afterwards.
    def attachment_blocks(object, media)
      (object['attachment'] || []).filter_map do |att|
        path = File.join(@export_dir, att['url'].to_s.sub(%r{\A/}, ''))
        filename = media.from_file(path)
        next unless filename

        entry = { 'url' => filename }
        entry['width'] = att['width'] if att['width']
        entry['height'] = att['height'] if att['height']
        kind = case att['mediaType'].to_s.split('/').first
               when 'video' then 'video'
               when 'audio' then 'audio'
               else 'image'
               end
        block = { 'type' => kind, 'media' => [entry] }
        # alt_text belongs to an image and to nothing else: the build reads
        # it only in the image branch and PostText.plain indexes it only
        # there, so a description the author wrote on a VIDEO was written
        # into the JSON and then existed nowhere a reader or the search box
        # could reach it. A video's human text is `caption` -- which is
        # what Facebook, Threads and Ghost have always written.
        text = presence(att['name'])
        block[kind == 'image' ? 'alt_text' : 'caption'] = text if text
        block
      end
    end

    def hashtags(object)
      (object['tag'] || []).filter_map do |tag|
        next unless tag['type'] == 'Hashtag'

        tag['name'].to_s.sub(/\A#/, '')
      end.reject(&:empty?).uniq { |t| t.downcase }
    end

    def build_slug(object, blocks)
      text = blocks.find { |b| b['type'] == 'text' }&.fetch('text', '').to_s
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug.empty? ? "toot-#{object['id'].to_s.split('/').last}" : slug
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
