# frozen_string_literal: true

require_relative '../i18n'
require_relative 'feed'

module Import
  # Imports a podcast from its RSS feed -- Libsyn, Buzzsprout, Anchor,
  # anything that publishes episodes as items with an audio enclosure.
  # Feed already knows how to read the XML, dates, ids and shownote HTML;
  # what a podcast adds is the audio itself: each episode's file downloads
  # and leads the post as a native audio block, with the episode artwork
  # above it. Local files on purpose -- the archive has to outlive the
  # hosting account, which is usually why anyone migrates a podcast.
  #
  # The enclosure is the episode's defining part: an item without one is
  # not an episode (a blog post syndicated into the same feed) and is
  # skipped with its own count.
  class Podcast < Feed
    # No permalink question for a podcast: the feed's <link> is the mp3,
    # not an episode page, so there is no original address to keep and
    # the wizard should not ask about one. Removing the writer is what
    # switches the question off -- it is capability-detected.
    undef_method :keep_permalinks=

    # Libsyn only includes its per-episode metadata (libsyn:itemId, the
    # stable identity) when asked; asking costs nothing on other hosts.
    def initialize(source)
      source = "#{source.sub(%r{/+\z}, '')}/rss/?include-libsyn-metadata=true" if source =~ %r{\Ahttps?://[^/]*libsyn\.com/?\z}
      super(source)
      @bytes = 0
    end

    def label
      title = channel_title
      title.empty? ? 'Podcast feed' : "Podcast (#{title})"
    end

    def map(item, media)
      audio_url = enclosure_url(item)
      return :no_audio if audio_url.empty?

      post = super
      return post unless post.is_a?(Hash)

      @bytes += enclosure_bytes(item)
      leading = []
      artwork = item.elements['itunes:image']&.attribute('href')&.value.to_s
      unless artwork.empty?
        filename = media.from_url(artwork)
        if filename
          entry = { 'url' => filename }
          width, height = media.dimensions(filename)
          entry['width'] = width if width
          entry['height'] = height if height
          leading << { 'type' => 'image', 'media' => [entry] }
        end
      end
      audio = media.from_url(audio_url)
      return :audio_unfetchable unless audio

      leading << { 'type' => 'audio', 'media' => [{ 'url' => audio }] }

      post['content'] = leading + post['content']
      post['tags'] = (post['tags'] + keywords(item)).uniq { |t| t.downcase }
      post['source']['platform'] = 'podcast'
      # The feed's <link> is the episode's mp3 on Libsyn, not a page --
      # there is no address to keep, and a guessed one would 404 with a
      # straight face. Same honesty rule as Instagram.
      post.delete('redirect_from')
      post
    end

    def postscript
      return nil if @bytes.zero?

      size = if @bytes >= 1_073_741_824
               "#{(@bytes / 1_073_741_824.0).round(1)} GB"
             else
               "#{(@bytes / 1_048_576.0).round} MB"
             end
      I18n.t('import.note.podcast_audio_size', size: size)
    end

    private

    def enclosure_url(item)
      item.elements['enclosure']&.attribute('url')&.value.to_s
    end

    def enclosure_bytes(item)
      item.elements['enclosure']&.attribute('length')&.value.to_i
    end

    # libsyn:itemId first -- it survives feed URL changes, where guids on
    # some hosts are the episode URL and rot with the domain.
    def item_id(item)
      libsyn = text_of(item, 'libsyn:itemId')
      libsyn.empty? ? super : libsyn
    end

    def keywords(item)
      text_of(item, 'itunes:keywords').split(',').map(&:strip).reject(&:empty?)
    end
  end
end
