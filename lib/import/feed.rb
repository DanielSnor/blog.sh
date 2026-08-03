# frozen_string_literal: true

require 'time'
require 'uri'
require_relative '../feed_http'
require_relative '../slug'
require_relative 'html_blocks'

module Import
  # One adapter for three inputs, because they are one format wearing two
  # hats: a WordPress WXR export *is* RSS 2.0 -- same <channel>, same
  # <item>, the post body in the same content:encoded a full-content feed
  # uses -- with a `wp:` namespace layered on for what a feed has no room
  # for. Atom is the only genuinely different dialect.
  #
  # So this reads whichever it's given and switches on the extras when it
  # sees them, rather than two importers duplicating the HTML handling that
  # is the actual work (see HtmlBlocks).
  #
  # The difference that matters when choosing an input: a public feed
  # carries only its last few dozen items, where a WXR file is the whole
  # archive.
  class Feed
    POST_STATES = { 'publish' => 'published', 'draft' => 'draft', 'pending' => 'draft',
                    'private' => 'draft', 'future' => 'draft' }.freeze

    def initialize(source)
      @source = source
    end

    def label
      kind = wordpress? ? 'WordPress export' : 'Feed'
      title = channel_title
      title.empty? ? kind : "#{kind} (#{title})"
    end

    def preamble
      if File.exist?(@source.to_s)
        "Reading #{@source} (#{(File.size(@source) / 1_048_576.0).round(1)} MB)…"
      else
        "Fetching #{@source}…"
      end
    end

    def total
      @total
    end

    # What the imported posts get tagged with. "wordpress" for an export,
    # but for a plain feed the platform name is "feed", which tells a reader
    # nothing -- the site it came from is the useful label, so /tag/medium.com/
    # collects everything imported from there. www. is dropped because
    # nobody tags anything "www.example.com".
    def platform_tag
      return 'wordpress' if wordpress?

      host = channel_host.to_s.sub(/\Awww\./, '')
      host.empty? ? 'feed' : host
    end

    def each_item(&block)
      items = entries
      @total = items.size
      items.each(&block)
    end

    def map(item, media)
      # skip_reason returns false for something importable, and the reason
      # itself otherwise -- so the summary can distinguish an attachment
      # from a page from a menu item.
      reason = skip_reason(item)
      return reason if reason

      html = body_html(item)
      parsed = HtmlBlocks.parse(html)
      blocks = localize_images(parsed.blocks, media, item)
      return :empty if blocks.empty?

      date = item_date(item)
      {
        'slug' => item_slug(item),
        'title' => text_of(item, 'title'),
        'date' => date.iso8601,
        'state' => item_state(item),
        'tags' => item_tags(item),
        'content' => blocks,
        'source' => {
          'platform' => wordpress? ? 'wordpress' : 'feed',
          'account' => channel_host,
          'post_url' => item_link(item),
          'original_id' => item_id(item)
        }.compact
      }
    end

    private

    # --- reading and dialect detection ---------------------------------

    def document
      @document ||= begin
        # rexml is a default gem, not core stdlib -- present with a normal
        # Ruby install, but some distributions ship a minimal package
        # without it. Required here so an import that never runs doesn't
        # make it a hard dependency of the engine.
        begin
          require 'rexml/document'
        rescue LoadError
          abort('❌ This import needs rexml, which your Ruby install is missing -- `gem install rexml` ' \
                'or install your distribution\'s fuller Ruby package.')
        end
        begin
          REXML::Document.new(read_source)
        rescue REXML::ParseException => e
          # label() parses the document before the run even starts, so a
          # malformed file used to take the wizard down with a raw REXML
          # backtrace pages long. One line naming the source and the
          # actual problem is what the author can act on.
          abort("❌ #{@source} is not readable as XML: #{e.message.lines.find { |l| !l.strip.empty? }.to_s.strip[0, 120]}")
        end
      end
    end

    def read_source
      return File.read(@source, encoding: 'utf-8') if File.exist?(@source.to_s)

      FeedHttp.get(@source)
    end

    def atom?
      document.root&.name == 'feed'
    end

    # The export's own version element is the reliable marker: a feed can
    # never carry it, and it's present from WXR 1.0 onwards.
    def wordpress?
      return @wordpress unless @wordpress.nil?

      @wordpress = !atom? && !document.elements['rss/channel/wp:wxr_version'].nil?
    end

    def entries
      @entries ||= if atom?
                     document.elements.to_a('feed/entry')
                   else
                     document.elements.to_a('rss/channel/item')
                   end
    end

    def channel_title
      text_of(atom? ? document.elements['feed'] : document.elements['rss/channel'], 'title')
    end

    def channel_host
      link = if atom?
               # A rel-less <link> IS an alternate link per the Atom spec --
               # requiring an explicit rel="alternate" left account (and
               # item post_url) empty on perfectly valid feeds, and an
               # empty account is what let two different feeds' items
               # cross-match on bare ids.
               atom_alternate(document.elements['feed'])
             else
               document.elements['rss/channel/link']&.text
             end
      URI.parse(link.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    def atom_alternate(parent)
      return nil unless parent

      links = parent.get_elements('link')
      picked = links.find { |l| l.attribute('rel')&.value == 'alternate' } ||
               links.find { |l| l.attribute('rel').nil? }
      picked&.attribute('href')&.value
    end

    # --- per-item -------------------------------------------------------

    # A WXR holds far more than posts: in a stock export, menu items,
    # attachments and pages outnumber them. Attachments are named
    # separately from the rest because their files are what the posts'
    # images point at -- worth seeing in a summary rather than lumped in.
    def skip_reason(item)
      return false unless wordpress?

      case text_of(item, 'wp:post_type')
      when 'post' then trashed?(item) ? :trashed : false
      when 'attachment' then :attachment
      when 'page' then :page
      else :not_a_post
      end
    end

    def trashed?(item)
      %w[trash auto-draft].include?(text_of(item, 'wp:status'))
    end

    def item_state(item)
      return 'published' unless wordpress?

      POST_STATES.fetch(text_of(item, 'wp:status'), 'published')
    end

    def body_html(item)
      candidates = if atom?
                     %w[content summary]
                   else
                     %w[content:encoded description]
                   end
      candidates.each do |name|
        text = text_of(item, name)
        return text unless text.empty?
      end
      ''
    end

    # WordPress already stores the slug it published under, so an import
    # keeps the URLs the old site had rather than inventing new ones.
    # Capped, because a feed's <title> is not always a title: some sources
    # put the whole post in it, and slugifying that produced 400-character
    # URLs. A WordPress export's own post_name is trusted as-is -- that's
    # the slug the site already published under.
    def item_slug(item)
      # Guarded like the two fallbacks below it: a post_name that folds to
      # nothing (raw non-ASCII or punctuation only -- WordPress itself
      # percent-encodes, but a hand-edited or third-party WXR does not)
      # produced an empty slug, and PostWriter then wrote <year>/.json --
      # an invisible dotfile that every glob in the engine skips, with its
      # media dumped loose in the year directory.
      name = Slug.slugify(text_of(item, 'wp:post_name'))
      return name unless name.empty?

      slug = Slug.slugify(text_of(item, 'title').split(/\s+/).first(10).join(' '))
      return slug unless slug.empty?

      # A title-less feed entry still needs a stable slug, and the id is
      # the only thing guaranteed to be there.
      Slug.slugify(item_id(item).to_s.sub(%r{\Ahttps?://}, '')).slice(0, 60)
    end

    # pubDate over wp:post_date on purpose: the wp: one has no offset, so
    # it would be read in site.timezone and shift the post by hours.
    def item_date(item)
      raw = if atom?
              [text_of(item, 'published'), text_of(item, 'updated')]
            else
              [text_of(item, 'pubDate'), gmt_date(item)]
            end
      raw.each do |value|
        next if value.empty?

        begin
          return Time.parse(value)
        rescue ArgumentError
          next
        end
      end
      Time.now
    end

    def gmt_date(item)
      value = text_of(item, 'wp:post_date_gmt')
      value.empty? || value.start_with?('0000') ? '' : "#{value} UTC"
    end

    def item_link(item)
      return atom_alternate(item).to_s if atom?

      text_of(item, 'link')
    end

    def item_id(item)
      return text_of(item, 'wp:post_id') if wordpress?
      return text_of(item, 'id') if atom?

      guid = text_of(item, 'guid')
      guid.empty? ? item_link(item) : guid
    end

    # Categories and tags both land in the one taxonomy this engine has.
    def item_tags(item)
      nodes = atom? ? item.elements.to_a('category') : item.elements.to_a('category')
      nodes.filter_map do |node|
        value = atom? ? node.attribute('term')&.value : node.text
        value&.strip
      end.reject(&:empty?).uniq { |t| t.downcase }
    end

    def text_of(element, path)
      return '' unless element

      node = path == 'title' && element.name == 'feed' ? element.elements['title'] : element.elements[path]
      node&.text.to_s.strip
    end

    # --- media ----------------------------------------------------------

    # HtmlBlocks leaves image blocks holding the URL it found in the markup;
    # this downloads each one and swaps in the local filename plus the
    # dimensions read from the file. Both matter: nothing may stay
    # hotlinked, and a block without dimensions is dropped at build time.
    def localize_images(blocks, media, item)
      base = item_link(item)
      blocks.filter_map do |block|
        next block unless block['type'] == 'image'

        url = absolute(block.dig('media', 0, 'url'), base)
        filename = url && media.from_url(url)
        next nil unless filename

        width, height = media.dimensions(filename)
        entry = { 'url' => filename }
        entry['width'] = width if width
        entry['height'] = height if height
        block.merge('media' => [entry])
      end
    end

    def absolute(url, base)
      return nil if url.to_s.empty?
      return url if url.start_with?('http://', 'https://')
      return "https:#{url}" if url.start_with?('//')

      base.to_s.empty? ? nil : URI.join(base, url).to_s
    rescue StandardError
      nil
    end
  end
end
