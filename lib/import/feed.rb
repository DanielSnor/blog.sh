# frozen_string_literal: true

require 'time'
require 'uri'
require_relative '../feed_http'
require_relative '../i18n'
require_relative '../slug'
require_relative '../path_glob'
# Only the postscript needs this, and only to ask where a page actually
# landed -- see #written_pages. The mapping itself stays writer-agnostic,
# and post_writer pulls in nothing from the run layer, so an adapter is
# still loadable (and testable) on its own.
require_relative '../post_writer'
require_relative 'html_blocks'
require_relative 'pages_note'
require_relative 'xml_repair'
require_relative 'permalinks'

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

    # Post types WordPress registers for its own housekeeping: menus, the
    # site editor's templates and styles, the customizer's drafts. They are
    # the bulk of the items in a stock export -- 70 nav_menu_item in the
    # theme unit test data, 1190 in WordPress's 10MB test export, 2 plus one
    # wp_global_styles in the 681 KB seandotcz export -- and none of them
    # was ever an article. Everything NOT on this list is a type somebody
    # registered on purpose (a portfolio, recipes, book reviews), which is
    # why it gets named separately in the summary; see #skip_reason.
    # The wp_ prefix is reserved by core for exactly this kind of thing, so
    # it is matched as a prefix rather than listed member by member.
    WP_INTERNAL_TYPES = %w[nav_menu_item revision custom_css customize_changeset
                           oembed_cache user_request].freeze

    # A type name in a WXR is a slug: WordPress allows [a-z0-9_-] and at
    # most 20 characters. Anything else came from a hand-edited or damaged
    # file and has no business being printed as a summary line.
    POST_TYPE_SLUG = /\A[a-z0-9_-]{1,20}\z/.freeze

    # The addresses the build keeps for itself: a page whose slug is one of
    # them is refused there, out loud, and never put up. Repeated from
    # build/build_blog.rb's RESERVED_ROOT_SEGMENTS -- which stays the
    # authority -- because the pages note is the only thing pointing at
    # imported pages, and a note that sends somebody to write /tag/ into
    # `nav:` has earned a menu of 404s. A name added there and forgotten
    # here only makes this note optimistic; the build still refuses and
    # still says so.
    RESERVED_PAGE_SLUGS = Import::RESERVED_PAGE_SLUGS

    # keep_permalinks is a writer, not just an option, because the wizard
    # only learns the answer after the adapter exists: the question is
    # asked once the source is chosen, right before the dry-run.
    attr_accessor :keep_permalinks

    def initialize(source, keep_permalinks: false)
      @source = source
      @keep_permalinks = keep_permalinks
      @unmapped_permalinks = 0
      @unmapped_page_permalinks = 0
      @linked_images = 0
      @pages = []
    end

    def label
      kind = wordpress? ? 'WordPress export' : 'Feed'
      title = channel_title
      title.empty? ? kind : "#{kind} (#{title})"
    end

    # Above this, the memory the parse needs is worth saying out loud
    # before it is taken -- see read_source. Below it, nobody notices.
    #
    # No multiplier is quoted with it on purpose. What the parse costs
    # follows the number of ELEMENTS, not the number of bytes, and the two
    # do not keep step: WordPress's own 9.5 MB test export takes 188 MB of
    # memory, and the same file with its items tripled -- 28 MB -- takes
    # 281. A figure that looked precise would be wrong by half in either
    # direction, and this line exists to be trusted.
    LARGE_EXPORT_MB = 20

    def preamble
      return "Fetching #{@source}…" unless File.exist?(@source.to_s)

      megabytes = File.size(@source) / 1_048_576.0
      line = "Reading #{@source} (#{megabytes.round(1)} MB)…"
      return line if megabytes < LARGE_EXPORT_MB

      "#{line} An export this size is read into memory whole and will take " \
        'several times its own size in RAM, with no output until that is done.'
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

      # Asked before the blocks are built, because the answer decides where
      # the post lives rather than what is in it.
      is_page = wordpress? && text_of(item, 'wp:post_type') == 'page'

      html = body_html(item)
      html = expand_shortcodes(html) if wordpress?
      parsed = HtmlBlocks.parse(html)
      # HtmlBlocks names everything the block schema has no shape for
      # instead of dropping it quietly, and nothing read the tally -- so an
      # archive full of embedded video lost all of it while the summary
      # said nothing, against what migrate_feed.rb's own header promises.
      @linked_images += linked_images(html)
      blocks = localize_images(parsed.blocks, media, item)
      # Registered AFTER the body's images, deliberately: media are
      # numbered in the order an adapter registers them, so registering
      # the featured image first would move every picture in every post
      # that has one down a number -- and a re-import then finds 01.jpg
      # already on disk and keeps the old bytes under the new post's
      # name. Its block still goes first, where the old site showed it.
      featured = featured_image(item, media, parsed.blocks)
      blocks.unshift(featured) if featured
      # A subclass may have a picture of its own to put at the head, which
      # it adds after this method returns -- Squarespace keeps the feature
      # image in the entry AFTER the post. Asked here, and only asked:
      # fetching it here would number it before the body's own audio and
      # move every media file in every such post, and a re-import then
      # finds somebody else's bytes under the new name. What the emptiness
      # test needed was the question, not the file. Without it a photo
      # post whose body parses to nothing was refused as :empty together
      # with the one picture it had, and the summary counted a skipped
      # post and a skipped attachment without ever saying they were the
      # same post.
      return :empty if blocks.empty? && !extra_leading?(item)

      date = item_date(item)
      state = item_state(item)
      post = {
        'slug' => item_slug(item),
        'title' => text_of(item, 'title'),
        'date' => date.iso8601,
        'state' => state,
        'tags' => item_tags(item),
        'content' => blocks,
        'source' => {
          'platform' => wordpress? ? 'wordpress' : 'feed',
          'account' => channel_host,
          'post_url' => item_link(item),
          'original_id' => item_id(item)
        }.compact
      }
      # A record rather than a path, because everything the summary says
      # about a page is settled later: where it landed is the writer's
      # answer, not this one's.
      page = nil
      if is_page
        post['page'] = true
        @pages << (page = { post: post, already_home: false })
      end
      # The WXR <link> is the post's real published address whatever the
      # site's permalink structure was -- better data than WordPress's own
      # importer reads. Drafts never had a public address, and a plain
      # "?p=123" permalink has its identity in the query string, which a
      # static stub can never answer -- those are counted, not guessed at.
      #
      # published_at_source?, not the state above: a password-protected
      # post lands here as a draft (see item_state) and WordPress had it
      # PUBLISHED -- the shell was on the open web, only the body was
      # behind the password. Read as a draft it lost its redirect and was
      # not even counted, so a public address died with nothing said.
      if @keep_permalinks && published_at_source?(item)
        path = Permalinks.local_path(item_link(item))
        if path.nil?
          # Split from the case below because they are opposite news. An
          # address that could not be read is a loss; a page that already
          # sits where it sat is the move working exactly as intended, and
          # counting it as unreadable told everybody moving to their own
          # domain -- the only people KEEP_PERMALINKS is for -- that
          # something had not fitted, blaming a permalink shape their
          # export does not contain.
          is_page ? @unmapped_page_permalinks += 1 : @unmapped_permalinks += 1
        elsif page && path == "/#{post['slug']}/"
          # A page that already lived at the root keeps that very address
          # here, so a redirect from it would point the page at itself --
          # which the build reports on every run and no edit ever clears.
          page[:already_home] = true
        else
          post['redirect_from'] = [path]
        end
      end
      post
    end

    # More than one note is possible now, so this takes the shape the
    # other adapters already have -- a single-note postscript silently
    # loses whichever note came second.
    def postscript
      notes = []
      if @repaired&.ampersands&.positive?
        notes << I18n.t('import.note.feed_ampersands_escaped', count: @repaired.ampersands)
      end
      if @repaired&.controls&.positive?
        notes << I18n.t('import.note.feed_controls_dropped', count: @repaired.controls)
      end
      notes << I18n.t('import.note.feed_unmapped', count: @unmapped_permalinks) if @unmapped_permalinks.positive?
      if @unmapped_page_permalinks.positive?
        notes << I18n.t('import.note.feed_unmapped_pages', count: @unmapped_page_permalinks)
      end
      live, reserved = written_pages.partition { |page| !RESERVED_PAGE_SLUGS.include?(page[:slug].downcase) }
      home = live.count { |page| page[:already_home] }
      notes << I18n.t('import.note.feed_pages_home', count: home) if home.positive?
      notes << I18n.t('import.note.feed_linked_images', count: @linked_images) if @linked_images.positive?
      notes << reserved_pages_note(reserved)
      notes.compact!
      notes.empty? ? nil : notes.join("\n  ")
    end

    private

    # --- what the summary owes the author -------------------------------

    # Sorted by count so the loudest loss is read first, and named element
    # by element: "3 iframe" is a video the post no longer has, where a
    # bare total says only that something went.
    # An <a> wrapped around a picture, which an image block has nowhere to
    # put: the picture arrives and the address it pointed at does not. Only
    # counted -- where a link would live is a question about the block
    # schema, not one this adapter gets to answer -- so at least the
    # summary says how much of the post's wiring was left behind.
    #
    # Read from the markup rather than the blocks because by then it is
    # already gone. The two cheap tests keep the second parse off every
    # body that cannot possibly contain one, which on an archive of
    # thousands is most of them.
    def linked_images(html)
      return 0 unless html.include?('<img') && html.include?('<a')

      count_linked_images(HtmlBlocks::Tree.build(HtmlBlocks::Tokenizer.tokenize(html)))
    end

    def count_linked_images(node)
      node.children.sum do |child|
        next 0 if child.text?

        own = linking_image?(child) ? 1 : 0
        own + count_linked_images(child)
      end
    end

    # One per LINK, not per picture: what is lost is the address, and a
    # gallery thumbnail wrapped in one anchor loses it once.
    def linking_image?(node)
      node.name == 'a' && !node.attrs['href'].to_s.strip.empty? && holds_image?(node)
    end

    def holds_image?(node)
      node.children.any? { |child| !child.text? && (child.name == 'img' || holds_image?(child)) }
    end

    # Every page paired with the slug it actually GOT. Both halves of the
    # pages note were wrong before: the addresses were read off the slug
    # the mapping proposed, before anything had been written, and a page
    # sitting on an address the engine owns was listed as though the build
    # would put it up. The note is the only thing pointing at these pages,
    # and somebody copies it into `nav:`.
    #
    # Asked of the writer rather than worked out again here, so it cannot
    # drift from what is on disk: PostWriter suffixes a slug already taken,
    # and WordPress hands the same post_name to two pages under different
    # parents often enough that /about/ and /about-2/ is the ordinary case.
    # Nothing is written on a dry run, and then the proposed slug is the
    # honest answer -- a preview is a prediction.
    def written_pages
      @written_pages ||= @pages.map do |page|
        path = PostWriter.find_by_source(page[:post]['source'])
        page.merge(slug: path ? File.basename(path, '.json') : page[:post]['slug'].to_s)
      end
    end

    def reserved_pages_note(reserved)
      return nil if reserved.empty?

      I18n.t('import.note.feed_pages_reserved', count: reserved.size,
                                                paths: reserved.map { |page| "/#{page[:slug]}/" }.join(', '))
    end

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
        # Read ONCE. The salvage below parses a second time, but never
        # fetches a second time: for a feed given as a URL that would pull
        # the whole archive down twice, and a second request that went
        # worse than the first would report a network problem about a file
        # that had already arrived intact.
        raw = read_source
        doc = begin
          REXML::Document.new(raw)
        rescue REXML::ParseException => e
          salvage(raw, e)
        end

        # XML that parses but isn't a feed used to end as "Done. 0 post(s)"
        # and exit 0 -- the same output as a feed that really is empty, so
        # an author who pasted a page URL instead of its feed URL was told
        # their import worked. The root element is the whole diagnosis:
        # <html> means the wrong URL, <rdf:RDF> means RSS 1.0, which this
        # adapter does not read.
        root = doc.root&.expanded_name
        unless %w[rss feed].include?(root)
          abort("❌ #{@source} is valid XML, but not an RSS/Atom feed or a WordPress export " \
                "(its root element is <#{root || 'nothing'}>).")
        end

        # Only now is a repair worth mentioning. A file that had to be
        # patched and then turned out to be someone's HTML error page is
        # refused on the line above, and announcing what was done to it on
        # the way there would only read as though the export had been
        # edited on disk.
        @repaired = @salvage if @salvage&.changed?
        doc
      end
    end

    # One more attempt, and only ever after REXML has already refused the
    # file as it stands -- so an export that parses today is not read,
    # scanned or rewritten by any of this, and cannot change because of it.
    #
    # When the patched copy still will not parse, the refusal names the
    # defect that SURVIVED rather than the ampersand this just proved it
    # can handle: a truncated export used to complain about a query
    # string, sending the author looking for the wrong thing.
    def salvage(raw, original_error)
      repaired = XmlRepair.call(raw)
      if repaired&.changed?
        begin
          doc = REXML::Document.new(repaired.text)
          @salvage = repaired
          return doc
        rescue REXML::ParseException => e
          original_error = e
        end
      end
      # label() parses the document before the run even starts, so a
      # malformed file used to take the wizard down with a raw REXML
      # backtrace pages long. One line naming the source and the actual
      # problem is what the author can act on.
      abort("❌ #{@source} is not readable as XML: " \
            "#{original_error.message.lines.find { |l| !l.strip.empty? }.to_s.strip[0, 120]}")
    end

    def read_source
      # A DIRECTORY is the answer people give here -- they unpack the export
      # and hand over the folder, not the .xml inside it -- and a file whose
      # permissions were lost in a copy is the other. Both used to end in a
      # raw Errno backtrace out of File.read, in a wizard whose whole job is
      # to hold somebody's hand through their first import.
      if File.directory?(@source.to_s)
        inside = PathGlob.under(@source.to_s, '*.{xml,rss,atom}').sort
        hint = inside.empty? ? '' : " Did you mean #{File.basename(inside.first)} inside it?"
        abort("❌ #{@source} is a folder, and this import wants the file itself.#{hint}")
      end

      if File.exist?(@source.to_s) && !File.readable?(@source.to_s)
        abort("❌ #{@source} cannot be read -- check the file's permissions.")
      end

      return File.read(@source, encoding: 'utf-8') if File.exist?(@source.to_s)

      begin
        # No body ceiling here: this is a whole archive, not a widget --
        # a WXR export of a few thousand posts is legitimately tens of MB.
        # The ceiling that does apply is memory, not a number in this
        # file: REXML builds the whole document before the first item is
        # read. WordPress's own 9.5 MB test export takes 188 MB to hold,
        # and 28 MB of the same items takes 281 -- so tens of MB really
        # does mean hundreds, and the cost follows how many elements the
        # file has rather than how many bytes. #preamble says so once the
        # file is big enough for it to matter. Reading items as they
        # stream would remove the ceiling, and would be a different
        # adapter.
        FeedHttp.get(@source, max_body: nil, accept: FeedHttp::XML_ACCEPT)
      rescue StandardError => e
        # A feed URL that 404s, times out or resolves nowhere raised through
        # to the wizard as a raw backtrace: the same defect the malformed-XML
        # abort below already fixed for files, just on the network path. The
        # message from FeedHttp already names the status and the URL.
        abort("❌ #{@source} could not be fetched: #{e.message}")
      end
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
               # text_of, not .text: REXML's .text returns only the FIRST
               # text child, so a pretty-printed feed (a newline before the
               # value) yields whitespace, URI.parse raises, the account
               # comes out nil -- and without an account PostWriter cannot
               # build a source key, so re-importing DUPLICATES the whole
               # archive instead of matching it. The same fault c3f768b
               # fixed for item bodies, one screen above.
               text_of(document.elements['rss/channel'], 'link')
             end
      # @source only when it is an ADDRESS. A local export path would
      # otherwise be read as a host -- "Downloads/blog.xml" giving the
      # account "Downloads", so two unrelated exports in one folder
      # share an identity and overwrite each other's posts. A file has
      # no host, and inventing one is worse than admitting it.
      source_url = @source.to_s.match?(%r{\Ahttps?://}) ? @source : nil
      host_of(link) || host_of(fallback_channel_link) || host_of(source_url)
    end

    # The host is the account half of every post's source key, and a nil
    # account switches re-import matching OFF -- so the run that the
    # engine advertises as safe writes the entire archive a second time,
    # with no undo but deleting the files by hand. Four shapes reached
    # nil before this: an Atom feed whose only <link> is rel="self", an
    # RSS channel whose link is relative or absent, a bare domain
    # ("example.com" parses with a nil host), and an internationalised
    # domain (URI::InvalidURIError). Each of them is an ordinary feed.
    # ...and if the feed names no address anywhere, the address it was
    # fetched FROM is still a stable identity for it -- better than nil,
    # which turns re-import matching off entirely. A feed read from a local
    # file has no host and stays nil; that case cannot be helped from here.
    def fallback_channel_link
      parent = atom? ? document.elements['feed'] : document.elements['rss/channel']
      return nil unless parent

      # Only the rels that name THIS feed's own site. "Any link" was far too
      # generous: a feed that declares its licence first ("rel=license",
      # pointing at creativecommons.org) handed that host over as the
      # account -- and a wrong account is worse than no account, because
      # every unrelated feed carrying the same licence link then shares one
      # identity and their posts overwrite each other. rel=hub (WebSub) and
      # rel=next (paged feeds) are the same trap.
      own = %w[alternate self]
      links = children_of(parent, 'link').select do |l|
        rel = l.attribute('rel')&.value
        rel.nil? || own.include?(rel)
      end
      links.filter_map { |l| l.attribute('href')&.value }.first ||
        text_of(parent, 'link') || text_of(parent, 'id')
    end

    # Pinned rather than DEFAULT_PARSER, because Ruby 3.4 rewired that
    # constant to the RFC3986 parser, whose escape calls itself obsolete
    # on every internationalised feed. The pin is the same one
    # Media.parse_url holds, so the host escaped here and the media URLs
    # escaped there can never drift apart between Ruby versions.
    ESCAPER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER

    def host_of(link)
      value = link.to_s.strip
      return nil if value.empty?

      # A bare domain has no scheme, so URI.parse puts it in `path` and
      # `host` is nil; assume https, which is what the address means.
      value = "https://#{value}" unless value.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      host = URI.parse(value).host
      host && !host.empty? ? host : nil
    rescue URI::InvalidURIError
      # Non-ASCII (internationalised) domains raise; escape and retry the
      # way Media.parse_url already does.
      begin
        host = URI.parse(ESCAPER.escape(value)).host
        host && !host.empty? ? host : nil
      rescue StandardError
        nil
      end
    end

    def atom_alternate(parent)
      return nil unless parent

      links = children_of(parent, 'link')
      picked = links.find { |l| l.attribute('rel')&.value == 'alternate' } ||
               links.find { |l| l.attribute('rel').nil? }
      picked&.attribute('href')&.value
    end

    # --- per-item -------------------------------------------------------

    # A WXR holds far more than posts: in a stock export, menu items,
    # attachments and pages outnumber them. Attachments are named
    # separately from the rest because their files are what the posts'
    # images point at -- worth seeing in a summary rather than lumped in.
    #
    # And a custom post type is named after itself. A blog with a portfolio
    # or a recipe section keeps those in their own type, with a title, a
    # body and categories like any post -- TryGhost's mg-wp-xml fixtures
    # carry two such items ("My CPT Post" as customcpt, a published article
    # as enmse_message). Under one shared :not_a_post they were counted
    # beside the menu items, and in an export where the menu contributes
    # four figures a line reading "1234 skipped (not a post)" hides forty
    # articles inside itself. Named by type, the summary says "40 skipped
    # (portfolio)" and the author can see what stayed behind.
    #
    # Named, not imported: WordPress exports every registered type that
    # allows it, so a shop's products and orders travel in the same file,
    # and importing them -- as posts or as drafts -- would fill the archive
    # (and the media folder) with things the author never wrote. Whether a
    # type belongs on the blog is their call; the summary's job is to let
    # them make it.
    def skip_reason(item)
      return false unless wordpress?

      type = text_of(item, 'wp:post_type')
      case type
      when 'post' then trashed?(item) ? :trashed : false
      when 'attachment' then :attachment
      # A page is imported as a page now rather than skipped -- trashed
      # ones stay out for the same reason a trashed post does.
      when 'page' then trashed?(item) ? :trashed : false
      else custom_type_reason(type)
      end
    end

    # Namespaced with "wp:", and not for tidiness. The reasons an import
    # can give are a flat set of words, and the summary translates the
    # ones the engine owns -- so a WordPress site whose custom type is
    # called quote, comment or reply (all of them ordinary names for a
    # section of a blog) would have had its type printed as this engine's
    # own wording for something else entirely: "skipped (quote)" would
    # come out in Czech as the reason a Bluesky quote-post is skipped.
    # A colon cannot occur in a type slug, so the prefix is a namespace
    # nothing can collide with, and the summary prints it as it stands.
    def custom_type_reason(type)
      return :not_a_post if WP_INTERNAL_TYPES.include?(type) || type.start_with?('wp_')
      return :not_a_post unless POST_TYPE_SLUG.match?(type)

      :"wp:#{type}"
    end

    def trashed?(item)
      %w[trash auto-draft].include?(text_of(item, 'wp:status'))
    end

    def item_state(item)
      return 'published' unless wordpress?

      # A password-protected post is <wp:status>publish</wp:status> with a
      # wp:post_password beside it: WordPress publishes the shell and
      # holds the body back until the password is typed. This engine has
      # no such gate, so mapping the status alone put the entire body of
      # a deliberately closed post on the open web (one such item in each
      # of WordPress's own test exports, 17 in their 10MB one). Draft is
      # the honest landing place -- the text is kept, behind a token that
      # cannot be guessed, for the author to decide about.
      return 'draft' unless text_of(item, 'wp:post_password').empty?

      POST_STATES.fetch(text_of(item, 'wp:status'), 'published')
    end

    # What the OLD site published, which is a different question from what
    # this one will -- and the right one to ask about an address. The
    # password branch above is the whole gap: everything else this maps to
    # a draft (pending, private, future) never had a public address, so the
    # mapping is read here exactly as item_state reads it, minus the
    # password.
    def published_at_source?(item)
      return true unless wordpress?

      POST_STATES.fetch(text_of(item, 'wp:status'), 'published') == 'published'
    end

    def body_html(item)
      candidates = if atom?
                     %w[content summary]
                   else
                     %w[content:encoded description]
                   end
      candidates.each do |name|
        # Atom's third content type holds MARKUP, not text:
        # <content type="xhtml"><div>…</div></content>. text_of reads text
        # children, of which such an element has none, so every entry in a
        # feed written that way imported empty and was reported as
        # "skipped (empty)" -- a whole blog counted and thrown away.
        node = child_of(item, name)
        if node && node.attributes['type'].to_s.downcase == 'xhtml'
          markup = node.children.map(&:to_s).join.strip
          # The wrapper <div> the format requires is scaffolding, not
          # content: kept, it would wrap every post in a stray block.
          markup = markup[%r{\A<div[^>]*>(.*)</div>\z}m, 1] || markup
          return markup unless markup.strip.empty?
        end

        text = text_of(item, name)
        return text unless text.empty?
      end
      ''
    end

    # --- shortcodes ------------------------------------------------------

    # Only a WXR needs this. What a feed carries is what the site RENDERED,
    # with every shortcode already turned into markup; content:encoded in
    # an export is the raw editor text, and the classic (pre-Gutenberg)
    # editor wrote pictures like this:
    #
    #   [caption id="attachment_906" align="alignnone" width="580"]<img …> Look at 580x300[/caption]
    #
    # HtmlBlocks has no idea what a square bracket is, so that arrived as
    # three blocks -- a paragraph reading '[caption id="attachment_906" …]',
    # the image, and a paragraph 'Look at 580x300[/caption]' -- with the
    # caption detached from what it describes. 7 of 57 posts in WordPress's
    # own theme test data are affected.
    CAPTION_SHORTCODE = %r{\[caption\b([^\]]*)\](.*?)\[/caption\]}m
    # Nothing generic: a rule broad enough to match any [word] would eat
    # "[citation needed]" and every footnote marker in the archive. This is
    # WordPress's own core set, the ones that appear in real exports.
    STRAY_SHORTCODE = %r{\[/?(?:caption|gallery|playlist|audio|video|embed)\b[^\]]*\]}

    def expand_shortcodes(html)
      # Most bodies have no bracket in them at all, and this walks every
      # post of an archive that can run to thousands.
      return html unless html.include?('[')

      html = html.gsub(CAPTION_SHORTCODE) do
        caption_figure(Regexp.last_match(1), Regexp.last_match(2))
      end
      # What is left is a shortcode this engine cannot render either way.
      # Dropping it loses nothing that was ever going to appear -- and
      # leaving it printed the raw text in the middle of the post.
      html.gsub(STRAY_SHORTCODE, '')
    end

    # <figure>/<figcaption> because HtmlBlocks already reads that pair into
    # one image block carrying its caption -- the shape the shortcode meant.
    def caption_figure(attrs, inner)
      # Two spellings, a decade apart: the older one puts the text in a
      # caption= attribute, the current one after the image.
      text = attrs[/\bcaption\s*=\s*(["'])(.*?)\1/m, 2].to_s
      markup = inner
      if text.empty?
        # Up to the FIRST image, plus the </a> that closes a link wrapped
        # around it -- a shortcode holds one picture. Reaching for the last
        # </a> instead looked tidier and cut the caption in half: real
        # captions have links INSIDE them ("getting some <a>caption</a>
        # love"), and everything before that anchor was thrown away with
        # the markup.
        split = inner.match(%r{\A(.*?<img\b[^>]*>(?:\s*</a>)?)(.*)\z}m)
        markup, text = split[1], split[2] if split
      end
      text = text.strip
      return markup if text.empty?

      "<figure>#{markup}<figcaption>#{text}</figcaption></figure>"
    end

    # WordPress already stores the slug it published under, so an import
    # keeps the URLs the old site had rather than inventing new ones.
    # Capped, because a feed's <title> is not always a title: some sources
    # put the whole post in it, and slugifying that produced 400-character
    # URLs. A WordPress export's own post_name is trusted as-is -- that's
    # the slug the site already published under.
    # Nothing for a plain feed or a WordPress export; see Squarespace.
    def extra_leading?(_item)
      false
    end

    # The title as the slug fallback should read it. Squarespace escapes
    # its titles TWICE, so "&" is still "&amp;" at this point and the
    # draft was filed under skillman-amp-hackett -- that adapter decodes
    # here rather than after the post is built.
    def slug_title(item)
      text_of(item, 'title')
    end

    def item_slug(item)
      # Guarded like the two fallbacks below it: a post_name that folds to
      # nothing (raw non-ASCII or punctuation only -- WordPress itself
      # percent-encodes, but a hand-edited or third-party WXR does not)
      # produced an empty slug, and PostWriter then wrote <year>/.json --
      # an invisible dotfile that every glob in the engine skips, with its
      # media dumped loose in the year directory.
      name = Slug.slugify(text_of(item, 'wp:post_name'))
      return name unless name.empty?

      slug = Slug.slugify(slug_title(item).split(/\s+/).first(10).join(' '))
      return slug unless slug.empty?

      # A title-less feed entry still needs a stable slug, and the id is
      # the only thing guaranteed to be there.
      Slug.slugify(item_id(item).to_s.sub(%r{\Ahttps?://}, '')).slice(0, 60)
    end

    # pubDate over wp:post_date on purpose: the wp: one has no offset, so
    # it would be read in site.timezone and shift the post by hours. It is
    # still read as the LAST resort -- see the candidates below.
    #
    # A date that parses is not a date that is true, and PostWriter turns
    # the year into a directory name without asking. WordPress gives every
    # post it never published <pubDate>Wed, 30 Nov -0001 00:00:00 +0000</pubDate>
    # (export.php formats a zero GMT date), which Time.parse accepts and
    # returns as year -1: a real export of 46 posts wrote 11 of them into
    # content/posts/-1/. A Squarespace export supplied a year of
    # 146140482 by the same route. Both are outside anything an archive
    # can mean, and the candidate after them knows better.
    PLAUSIBLE_YEARS = (1000..Time.now.year + 50).freeze

    def item_date(item)
      raw = if atom?
              [text_of(item, 'published'), text_of(item, 'updated')]
            else
              # wp:post_date last: for a draft it is the ONLY field that
              # holds the day it was written -- pubDate is the -0001
              # sentinel and post_date_gmt is 0000-00-00 -- and being read
              # in site.timezone puts it a few hours out at worst, where
              # the alternative was a year that does not exist.
              [text_of(item, 'pubDate'), gmt_date(item), text_of(item, 'wp:post_date')]
            end
      raw.each do |value|
        next if value.empty?

        begin
          time = Time.parse(value)
        rescue ArgumentError
          next
        end
        next unless PLAUSIBLE_YEARS.cover?(time.year)

        return time
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
    # WordPress files three different things under the same <category>
    # element and tells them apart by a domain attribute: the post's
    # categories, its tags, and its FORMAT. A format is a property of how
    # the theme draws a post -- aside, status, quote, gallery -- and never
    # was a word anyone tagged anything with. Read as one, a blog that
    # used formats grew a /tag/aside/ and a /tag/status/ it never had:
    # 221 of them across WordPress's own 10MB test export.
    NOT_A_TAG_DOMAIN = %w[post_format].freeze

    def item_tags(item)
      item.elements.to_a('category').filter_map do |node|
        next if !atom? && NOT_A_TAG_DOMAIN.include?(node.attribute('domain')&.value)

        value = atom? ? node.attribute('term')&.value : node.text
        value&.strip
      end.reject(&:empty?).uniq { |t| t.downcase }
    end

    # REXML matches an unprefixed step against whatever default namespace
    # is in scope AT THE CANDIDATE ELEMENT, not against "no namespace at
    # all". Buzzsprout and Simplecast both write
    #
    #   <atom:link href="…" rel="hub" xmlns="http://www.w3.org/2005/Atom"/>
    #
    # above the channel's own <link>, and that redundant xmlns puts the
    # element in a default namespace of its own -- so REXML hands it back
    # for channel.elements['link']. The redeclaration is the whole
    # trigger: a plain <atom:link rel="self"/>, which those feeds also
    # carry, is skipped correctly, and the same xmlns on any OTHER sibling
    # changes nothing. That is why this reads as a phantom until a real
    # feed is put through it.
    #
    # The address of an atom:link lives in an attribute, so the text came
    # out empty: channel_host was nil, a nil account switches off
    # PostWriter's re-import matching, and the second run of an import
    # this engine advertises as safe wrote the whole feed again (2
    # episodes, then 4, with "-2" slugs) -- re-downloading the show's
    # audio to do it, which for a podcast is gigabytes.
    #
    # Preferring the unprefixed child and only then falling back to
    # REXML's own answer leaves every prefixed lookup -- wp:post_date,
    # content:encoded -- exactly as it was. REXML's answer is taken first
    # and the scan happens only when it came back prefixed: this runs a
    # dozen times per item, and a 10MB export is 969 of them.
    def child_of(element, path)
      return nil unless element

      node = element.elements[path]
      return node if node.nil? || path.include?(':') || node.prefix.to_s.empty?

      element.elements.find { |child| child.name == path && child.prefix.to_s.empty? } || node
    end

    def children_of(element, path)
      nodes = element.get_elements(path)
      return nodes if path.include?(':')

      unprefixed = nodes.select { |child| child.prefix.to_s.empty? }
      unprefixed.empty? ? nodes : unprefixed
    end

    def text_of(element, path)
      return '' unless element

      node = path == 'title' && element.name == 'feed' ? child_of(element, 'title') : child_of(element, path)
      return '' unless node

      # ALL text children, not the first. `element.text` returns only the
      # first text node -- and a feed generator that writes a newline
      # before its CDATA section makes that first node pure whitespace,
      # which read as "this item has no body" for every item in the feed.
      # The posts were there the whole time, one indentation away.
      node.texts.map(&:value).join.strip
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

    # WordPress's featured image is a property of the post, not part of its
    # body: the theme paints it above the text, and the export mentions it
    # only as a _thumbnail_id pointing at an attachment item somewhere else
    # in the same file. Reading the body alone therefore lost the ONLY
    # picture some posts have -- 3 of the 6 posts that carry a featured
    # image in WordPress's own theme test data have no <img> in the body.
    def featured_image(item, media, body_blocks)
      return nil unless wordpress?

      entry = attachment_index[postmeta(item, '_thumbnail_id')]
      return nil unless entry
      return nil if in_body?(entry['url'], body_blocks, item)

      filename = media.from_url(entry['url'])
      return nil unless filename

      width, height = media.dimensions(filename)
      picture = { 'url' => filename }
      picture['width'] = width if width
      picture['height'] = height if height
      block = { 'type' => 'image', 'media' => [picture] }
      block['alt_text'] = entry['alt'] unless entry['alt'].empty?
      block
    end

    # post_id -> the file it stands for, built once from every attachment
    # item in the export. Attachments are skipped as posts (see
    # skip_reason), but they are where the addresses live.
    def attachment_index
      @attachment_index ||= entries.each_with_object({}) do |item, acc|
        next unless text_of(item, 'wp:post_type') == 'attachment'

        id = text_of(item, 'wp:post_id')
        url = text_of(item, 'wp:attachment_url')
        next if id.empty? || url.empty?

        acc[id] = { 'url' => url, 'alt' => postmeta(item, '_wp_attachment_image_alt') }
      end
    end

    def postmeta(item, key)
      node = item.get_elements('wp:postmeta').find { |meta| text_of(meta, 'wp:meta_key') == key }
      node ? text_of(node, 'wp:meta_value') : ''
    end

    # Publishing the same picture twice, once as the featured image and
    # again where the author put it, is the obvious way to get this wrong.
    # The two URLs rarely match letter for letter -- the body usually holds
    # one of WordPress's resized copies, "…-580x300.jpg" of the file the
    # attachment names -- so the comparison is on the filename with that
    # suffix taken off.
    def in_body?(url, body_blocks, item)
      key = image_key(url)
      return false unless key

      base = item_link(item)
      body_blocks.any? do |block|
        block['type'] == 'image' &&
          image_key(absolute(block.dig('media', 0, 'url'), base)) == key
      end
    end

    def image_key(url)
      name = File.basename(url.to_s.split('?').first.to_s)
      return nil if name.empty?

      name.sub(/-\d+x\d+(?=\.[a-z0-9]+\z)/i, '').downcase
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
