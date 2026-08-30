# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative '../i18n'
require_relative '../slug'
require_relative '../path_glob'
require_relative 'html_blocks'
require_relative 'meta_html'
require_relative 'meta_text'
require_relative 'permalinks'

module Import
  # Imports a Facebook export -- Meta's "Download your information",
  # pointed at the unpacked directory. Either format it offers: JSON and
  # HTML both carry the same posts, and which one this is comes from the
  # export itself. Everything is local: text in your_posts*, photos and
  # videos as files in the archive, nothing downloaded. JSON is still
  # the better ask where there's a choice -- its timestamps are epochs,
  # where the HTML prints a wall clock in the account's own timezone and
  # leaves the zone to be inferred (see HtmlReader).
  #
  # What counts as a post: something with your own text, media, or a
  # shared link. Bare check-ins, app stories and other timeline
  # furniture are skipped and counted by name. Facebook's export has no
  # per-post id at all, so the re-import identity is minted from the
  # timestamp plus a digest of the content -- the pair that survives a
  # re-export, and (HTML timestamps carrying seconds, unlike Meta's
  # other HTML exports) survives the jump between the two formats too.
  class Facebook
    # The dominant content of an older personal account is not posts but
    # CROSSPOSTS -- on the export this was built against, 95 % of all
    # entries were Twitter and Posterous echoes. Imported silently they
    # would duplicate the user's own Twitter archive thousands of times,
    # so they are skipped and counted by default; include_crossposts
    # brings them in for the account that really lived on Facebook.
    #
    # Detection leans on the two signals the export offers: the
    # FB-generated title mentions the platform by (language-independent)
    # proper name, and crosspost bodies carry the shorteners of their
    # era. The title is never the user's own text, so a post ABOUT
    # Twitter is safe.
    CROSSPOST_TITLE = /\b(Twitter|Posterous|Instagram|Foursquare|Swarm|Klout|tvtag|GetGlue)\b/
    CROSSPOST_LINK = %r{https?://(t\.co|klou\.tt|4sq\.com|post\.ly)/}

    def initialize(dir, include_crossposts: false, format: nil)
      @dir = File.expand_path(dir)
      @format = format || self.class.format_of(@dir)
      @posts_dir = self.class.posts_dir(@dir, @format)
      @reader = @format == :html ? HtmlReader.new(@posts_dir) : JsonReader.new(@posts_dir)
      @include_crossposts = include_crossposts
      @crossposts = 0
    end

    # The directory this export lives in. Media#from_file refuses any path
    # that resolves outside it -- an export naming a file on the importer's
    # own disk got it copied into the archive and published.
    def import_root
      @dir
    end


    # The unpacked export nests differently per era -- posts/ at the
    # top, or under your_facebook_activity/. Accept the archive root,
    # either parent, or the posts directory itself.
    def self.posts_dir(dir, format = nil)
      extensions = format ? format.to_s : '{json,html}'
      [File.join(dir, 'posts'),
       File.join(dir, 'your_facebook_activity', 'posts'),
       dir].find { |candidate| !PathGlob.under(candidate, "your_posts*.#{extensions}").empty? }
    end

    # What the wizard and the script check before building anything: is
    # there an export here, and in which format. nil for a wrong path,
    # since that is the ordinary mistake and deserves the ordinary
    # message rather than an exception.
    def self.format_of(dir)
      %i[json html].find { |format| posts_dir(dir, format) }
    end

    # The format is named because the two differ where it matters --
    # HTML timestamps are read in the site's timezone (see HtmlReader),
    # so a summary that says which reader ran is a checkable claim.
    def label
      "Facebook export (#{File.basename(@dir)}, #{@format} export)"
    end

    def total
      @total
    end

    def platform_tag
      'facebook'
    end

    def each_item(&block)
      items = @reader.items
      items.sort_by! { |i| i['timestamp'].to_i }
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      text = item['data'].to_a.filter_map { |entry| presence(MetaText.repair(entry['post'])) }.join("\n\n")
      attachments = item['attachments'].to_a.flat_map { |a| a['data'].to_a }
      media_entries = attachments.filter_map { |a| a['media'] }
      links = attachments.filter_map { |a| a['external_context'] }
      places = attachments.filter_map { |a| a['place'] }

      # A check-in with nothing said is a dot on a map, not a post; an
      # entry with none of the three is app-story furniture ("shared an
      # app"). Both are counted under their own names.
      return :checkin if text.empty? && media_entries.empty? && links.empty? && !places.empty?
      return :no_content if text.empty? && media_entries.empty? && links.empty?

      if !@include_crossposts && crosspost?(item, text)
        @crossposts += 1
        return :crosspost
      end

      blocks = text_blocks(text) + media_blocks(media_entries, text, media) + link_blocks(links)
      return :empty if blocks.empty?

      date = Time.at(item['timestamp'].to_i)
      slug = Slug.slugify(text.split(/\s+/).first(8).join(' '))
      slug = "facebook-#{date.strftime('%Y%m%d%H%M%S')}" if slug.empty?

      {
        'slug' => slug,
        'title' => nil,
        'date' => date.iso8601,
        'state' => 'published',
        'tags' => [],
        'content' => blocks,
        'source' => {
          'platform' => 'facebook',
          'account' => File.basename(@dir),
          'original_id' => "#{item['timestamp']}-#{content_digest(text, media_entries)}"
        }
      }
    end

    def postscript
      notes = []
      notes << I18n.t('import.note.facebook_crossposts', count: @crossposts) if @crossposts.positive?
      notes << untouched_note
      notes.compact!
      notes.empty? ? nil : notes.join("\n  ")
    end

    # An export carries more than the timeline: albums, the photos that
    # never made it into one, and videos. This adapter reads your_posts*
    # and nothing else -- which is a decision, not an oversight (an album
    # is not a post, and inventing one per photo would bury a timeline).
    # Saying so is not optional though: the export lists these files at the
    # top level, the archive plainly does not contain them afterwards, and
    # a summary that never mentions them leaves the person to discover the
    # gap themselves, months later, by missing a picture.
    def untouched_note
      photos = countable(@posts_dir, 'your_uncategorized_photos.*')
      # One file per album, in the format this export was downloaded in --
      # the same choice that decided the reader, so it is known here. A
      # bare *.json glob found none of an HTML export's albums and the
      # sentence said "albums (0)" over an archive that had a shelf of
      # them, which is worse than not mentioning albums at all: it is an
      # answer, and it is wrong.
      albums = PathGlob.under(@posts_dir, 'album', "*.#{@format}").size
      videos = countable(@posts_dir, 'your_videos.*')
      return nil if photos.zero? && albums.zero? && videos.zero?

      I18n.t('import.note.facebook_untouched', photos: photos, albums: albums, videos: videos)
    end

    # How many entries a side file holds, without pretending to parse the
    # HTML variant: there the count is the number of media entries, and one
    # unreadable file must not take the sentence down with it.
    #
    # The directory arrives separately from the name so it stays a
    # directory: pasted together, an export unpacked into "meta [1]" makes
    # its own path part of the pattern and the count silently becomes 0.
    def countable(dir, name)
      PathGlob.under(dir, name).sum do |path|
        body = File.read(path, encoding: 'utf-8')
        if path.end_with?('.json')
          data = JSON.parse(body)
          list = data.is_a?(Hash) ? (data['photos'] || data['videos_v2'] || data.values.find { |v| v.is_a?(Array) }) : data
          Array(list).size
        else
          body.scan(/<img|<video/i).size
        end
      rescue StandardError
        0
      end
    end

    private

    def crosspost?(item, text)
      MetaText.repair(item['title']).match?(CROSSPOST_TITLE) || text.match?(CROSSPOST_LINK)
    end

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def content_digest(text, media_entries)
      Digest::MD5.hexdigest(text + media_entries.map { |m| m['uri'].to_s }.join(','))[0, 10]
    end

    def text_blocks(text)
      text.split(/\n{2,}/).filter_map do |para|
        clean = para.strip
        { 'type' => 'text', 'text' => clean } unless clean.empty?
      end
    end

    # The media uri is a path INSIDE the archive, prefixed (or not) with
    # your_facebook_activity/ depending on where the unpacking started.
    # A media description that just repeats the post text is Facebook's
    # habit, not a caption.
    def media_blocks(entries, text, media)
      entries.filter_map do |entry|
        path = resolve(entry['uri'].to_s)
        next nil unless path

        filename = media.from_file(path)
        next nil unless filename

        kind = path.match?(/\.(mp4|mov)\z/i) ? 'video' : 'image'
        media_entry = { 'url' => filename }
        if kind == 'image'
          width, height = media.dimensions(filename)
          media_entry['width'] = width if width
          media_entry['height'] = height if height
        end
        block = { 'type' => kind, 'media' => [media_entry] }
        caption = presence(MetaText.repair(entry['description']))
        block['caption'] = caption if caption && caption != text
        block
      end
    end

    # Falls back to the first candidate rather than nil when none of them
    # exists: Media#from_file has to see every referenced file, present or
    # not, or the numbering shifts between runs of a staged export and the
    # summary never names what is missing. It decides; this only says where
    # to look.
    def resolve(uri)
      return nil if uri.empty?

      candidates = [File.join(@dir, uri),
                    File.join(@dir, uri.sub(%r{\Ayour_facebook_activity/}, '')),
                    File.join(@posts_dir, '..', uri.sub(%r{\Ayour_facebook_activity/}, ''))]
      candidates.find { |candidate| File.exist?(candidate) } || candidates.first
    end

    def link_blocks(links)
      links.filter_map do |link|
        url = link['url'].to_s
        next nil if url.empty?

        title = presence(MetaText.repair(link['name'])) || url
        { 'type' => 'link', 'url' => url, 'title' => title }
      end
    end

    # posts_1, posts_2, ... sorted numerically, since posts_10 sorts
    # before posts_2 as a string and a large account would import out of
    # order. Both formats split the same way.
    module PostsFiles
      def posts_files(extension)
        PathGlob.under(@posts_dir, "your_posts*.#{extension}")
           .sort_by { |path| File.basename(path)[/\d+/].to_i }
      end
    end

    # The JSON export as it always was: an array per file, epochs for
    # timestamps, Meta's byte-at-a-time mojibake in the strings (which
    # map() hands to MetaText for repair).
    class JsonReader
      include PostsFiles

      def initialize(posts_dir)
        @posts_dir = posts_dir
      end

      def items
        posts_files('json').flat_map { |f| JSON.parse(File.read(f, encoding: 'utf-8')) }
      end
    end

    # The HTML export is the same archive rendered as a page, one post
    # per `_a6-g` section: an FB-generated title in the h2, the content
    # in `_2pin` cells, the timestamp in the footer. Class names have
    # been minified for a decade but these particular ones are what has
    # survived every export redesign, same story as the Instagram
    # reader's uiBoxWhite.
    #
    # Everything read here is synthesized into the JSON export's item
    # shape and handed to the same map(), so the two formats agree post
    # for post -- including the minted original_id, since the HTML
    # timestamps carry seconds and convert back to the exact epoch. On
    # the export this was built against the two formats produce the
    # same posts to the byte in the default run. The honest gaps: a
    # check-in's place is not recognizably marked in the page, so a
    # bare check-in counts under no_content rather than checkin; the
    # old inline emoticon images (remote GIFs on Facebook's CDN) vanish
    # with the markup where the JSON kept a character; and the page
    # prints URLs normalized ("about.me/" for the "about.me" the person
    # typed), so a crosspost import brought over from the other format
    # can re-mint ids for the affected posts (205 of 1598 measured) --
    # one more reason the crosspost default is to skip them.
    #
    # The page prints its text already decoded -- no mojibake, the one
    # thing the HTML export does better -- and its timestamps in words,
    # in the language the export was requested in and in the account's
    # own timezone, daylight saving observed (both verified against the
    # same account's JSON epochs). The zone itself goes unnamed, so the
    # wall clock is read in the site's zone: importing your own archive
    # into your own blog, the two are the same place and the epochs come
    # out exact. An export in a language MetaHtml doesn't know skips
    # every post it can't date and says which token defeated it -- the
    # honest exit, since a guessed month would date it wrong instead.
    class HtmlReader
      include PostsFiles

      SECTION = /<section class="_a6-g"/.freeze
      TITLE = %r{<h2[^>]*>(.*?)</h2>}m.freeze
      CONTENT = %r{<div class="_2ph_ _a6-p">(.*?)<footer}m.freeze
      FOOTER_DATE = %r{<div class="_a72d">([^<]+)</div>}.freeze
      CELL = /<div class="_2pin">/.freeze
      # A media description sits in a div classed exactly _3-95 next to
      # the file; the album-name div beside it has no class and is an
      # album's title, not the post's words.
      DESCRIPTION = %r{<div class="_3-95">(.*?)</div>}m.freeze
      REF = /(?:href|src)="([^"]+)"/.freeze
      REMOTE = %r{\Ahttps?://}.freeze

      def initialize(posts_dir)
        @posts_dir = posts_dir
        @unknown_stamps = {}
      end

      def items
        posts_files('html').flat_map { |f| parse_file(File.read(f, encoding: 'utf-8')) }
      end

      private

      def parse_file(html)
        html.split(SECTION).drop(1).filter_map { |chunk| parse_section(chunk) }
      end

      def parse_section(chunk)
        timestamp = timestamp_of(chunk)
        return nil unless timestamp

        texts = []
        attachments = []
        chunk[CONTENT, 1].to_s.split(CELL).drop(1).each do |cell|
          read_cell(cell, texts, attachments)
        end

        item = { 'title' => HtmlBlocks.decode_entities(chunk[TITLE, 1].to_s),
                 'timestamp' => timestamp,
                 'data' => texts.map { |text| { 'post' => text } } }
        item['attachments'] = [{ 'data' => attachments }] unless attachments.empty?
        item
      end

      # The footer's printed date, converted back to an epoch. One warn
      # per unrecognized month-and-meridiem pair rather than per post,
      # so an export in an unknown language reports itself in a line or
      # two instead of sixteen hundred.
      def timestamp_of(chunk)
        printed = chunk[FOOTER_DATE, 1].to_s.strip
        time = MetaHtml.parse_local(printed)
        unless time || printed.empty?
          token = printed.gsub(/[\d:,]+/, ' ').split.join(' ')
          unless @unknown_stamps[token]
            @unknown_stamps[token] = true
            warn "  cannot read the timestamp #{printed.inspect} -- posts dated like this are skipped; the JSON export needs no translation"
          end
        end
        time&.to_i
      end

      # A post's own words sit in cells as divs with nothing nested
      # inside them; anything with structure below it is an attachment
      # -- a shared link, a photo with its album furniture, an app
      # story's app name. The export's "Updated <date>" line lives among
      # the text divs and is dropped by shape.
      def read_cell(cell, texts, attachments)
        children(cell).each do |child|
          if child.include?('<div')
            read_attachment(child, attachments)
          else
            text = MetaHtml.plain_text(child)
            texts << text unless text.empty? || MetaHtml.furniture?(text)
          end
        end
      end

      # Direct children of a cell, by div depth -- the cell's own close
      # also ends the walk, since split(CELL) leaves the rest of the
      # section trailing after it.
      def children(cell)
        found = []
        depth = 1
        start = nil
        cell.scan(%r{</?div[^>]*>}) do
          match = Regexp.last_match
          if match[0].start_with?('</')
            depth -= 1
            break if depth.zero?

            if depth == 1 && start
              found << cell[start...match.begin(0)]
              start = nil
            end
          else
            start = match.end(0) if depth == 1
            depth += 1
          end
        end
        found
      end

      # Local paths are the post's own files; a remote href is a shared
      # link. Remote img tags -- stickers, the old emoticon GIFs -- are
      # neither, and are left where they are.
      def read_attachment(child, attachments)
        refs = child.scan(REF).flatten.map { |ref| HtmlBlocks.decode_entities(ref) }
        local = refs.reject { |ref| ref.match?(REMOTE) }.uniq
        if local.any?
          descriptions = child.scan(DESCRIPTION).flatten
          local.each_with_index do |uri, index|
            media = { 'uri' => uri }
            description = descriptions[index] && MetaHtml.plain_text(descriptions[index])
            media['description'] = description if description && !description.empty?
            attachments << { 'media' => media }
          end
        else
          url = child[/<a[^>]*href="(https?:[^"]*)"/, 1]
          attachments << { 'external_context' => { 'url' => HtmlBlocks.decode_entities(url) } } if url
        end
      end
    end
  end
end
