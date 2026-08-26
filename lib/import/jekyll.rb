# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'json'
require 'time'
require 'yaml'
# For the run's postscript below -- the other adapters that speak in the
# summary require it the same way.
require_relative '../i18n'
require_relative '../slug'
require_relative '../path_glob'
require_relative '../markdown_parser'
# Only the postscript needs these, and only to say where a page actually
# landed -- the same pair (and the same reason) as feed.rb.
require_relative '../post_writer'
require_relative 'html_blocks'
require_relative 'pages_note'
require_relative 'permalinks'

module Import
  # Imports a tree of markdown posts with front matter -- a Jekyll site
  # (_posts/ and _drafts/), a Hugo content/ directory, or any folder of
  # .md files a converter produced (Meddler's Medium output,
  # Substack2Markdown's, ...). The body IS blog.sh's native language, so
  # it goes through the same MarkdownParser that authoring uses -- no
  # HTML round-trip -- and .html bodies take the HtmlBlocks path instead.
  #
  # Images come from the tree where the tree has them -- a relative or
  # root-relative path is read off disk, and that half really does work
  # for a site that died years ago. An absolute URL goes to the network
  # like anywhere else, and a tree exported from a hosted platform is
  # mostly those: a real Hugo `content/` gave this 72 images to resolve
  # and 70 were https:// links back to the WordPress it had been migrated
  # from, of which 66 answered 404. The archive is only as complete as the
  # old host is still willing to be, and the summary is where that is said.
  class Jekyll
    attr_accessor :keep_permalinks

    # PERMALINK is a pattern like "/:year/:month/:day/:title/" --
    # Jekyll's permalink config, which the tree itself does not reveal
    # post by post. Without one, only posts with an explicit front
    # matter permalink get a redirect.
    def initialize(dir, permalink: nil, keep_permalinks: false)
      @dir = File.expand_path(dir)
      @permalink = permalink
      @keep_permalinks = keep_permalinks
      # The identity of the TREE, which its last path component is not:
      # "content" is what Hugo calls the directory on every site there is,
      # and _posts/ what Jekyll calls it on every site there is. Two blogs
      # imported one after the other therefore minted the same source keys
      # -- and a source key is what PostWriter matches a re-import on, so
      # the second blog's posts landed ON the first blog's and overwrote
      # them in place, silently, one for one.
      #
      # What tells two of them apart is the name the site gives itself: a
      # Hugo configuration's baseURL, a Jekyll _config.yml's url, either
      # one's title. That name travels WITH the tree, so an export moved
      # out of ~/Downloads, restored to another folder or unpacked on a
      # second machine still recognises itself -- and it is the one thing
      # read out of the tree that editing the blog does not change.
      #
      # A tree that declares nothing (a converter's dump, a bare content/)
      # falls back to the digest of its own path, which tells two of them
      # apart but only while both stay where they were. See
      # declared_identity for what the fallback costs and docs/importing.md
      # for how it is said to the author.
      @account = source_account
      @rearranged = 0
      @liquid_links = 0
      # Keyed by path rather than counted as they go: the wizard runs the
      # same adapter over the tree twice (a preview pass, then the real
      # one), and a counter would say everything twice.
      @slugs = Hash.new { |h, k| h[k] = [] }
      @authored = []
      # Published pages, keyed by path for the same two-pass reason as
      # @slugs; the value is what the postscript needs to name the page's
      # address after the run has written it.
      @page_notes = {}
      # Per post, set by map before the blocks are built -- empty for any
      # tree this engine did not write.
      @own_media_src = {}
      # Origin -> the file it belongs to, keyed by path for the same
      # two-pass reason as @slugs. A redirect is one address pointing at
      # one place, so the first claim wins and stays won across passes.
      @origins = {}
      # Files the tree names but does not hold, keyed by path for the
      # two-pass reason again -- the postscript says how many.
      @missing_media = {}
    end

    # The directory this export lives in. Media#from_file refuses any path
    # that resolves outside it -- an export naming a file on the importer's
    # own disk got it copied into the archive and published.
    def import_root
      @dir
    end


    # Said out loud when the run rearranged anything -- see
    # free_inline_images. An import may transform, but not quietly.
    def postscript
      notes = []
      notes << I18n.t('import.note.ssg_hugo_site_root') unless tree_root == @dir
      # The same decision the other way round, which was the silent half:
      # a folder with Hugo's configuration in it and markdown of its own
      # at the top is walked whole -- layouts/ and archetypes/ included --
      # because that markdown may be the tree the author meant. Which file
      # decided it is the only thing that makes the outcome fixable.
      if tree_root == @dir && hugo_layout?
        notes << I18n.t('import.note.ssg_hugo_site_root_declined', files: stray_root_names)
      end
      notes << I18n.t('import.note.ssg_images_freed', count: @rearranged) if @rearranged.positive?
      notes << I18n.t('import.note.ssg_liquid_links_dropped', count: @liquid_links) if @liquid_links.positive?
      notes << I18n.t('import.note.ssg_media_missing', count: @missing_media.length) unless @missing_media.empty?
      collisions = @slugs.count { |_, paths| paths.length > 1 }
      notes << I18n.t('import.note.ssg_slug_collisions', count: collisions) if collisions.positive?
      notes << I18n.t('import.note.ssg_author_dropped', count: @authored.length) unless @authored.empty?
      notes.compact!
      notes.empty? ? nil : notes.join("\n  ")
    end

    def label
      "Markdown tree (#{File.basename(@dir)})"
    end

    def total
      @total
    end

    # Nil for a post this engine wrote itself (see apply_own_keys): it
    # already knows where it came from, and a round-trip through export
    # and back must not leave a "jekyll" pill behind on every post.
    def platform_tag
      @own_post ? nil : 'jekyll'
    end

    def each_item(&block)
      posts = PathGlob.under(@dir, '_posts', '**', '*.{md,markdown,html}')
      drafts = PathGlob.under(@dir, '_drafts', '**', '*.{md,markdown,html}')
      # No _posts/ means either a plain folder of markdown -- a
      # converter's output -- or a site built entirely on collections
      # (_docs, _tutorials), which Jekyll allows and jekyll/jekyll's own
      # docs/ is. Same shape, wider net, minus the machinery.
      swept = posts.empty? && drafts.empty?

      # A folder with no markdown in it at all is not an empty blog, it is
      # the wrong folder -- and "Done. 0 post(s) written", exit 0, reads as
      # a successful import of nothing. Somebody who has just pointed the
      # importer at their Downloads instead of the export inside it needs
      # to hear that, not a tick.
      if swept && wider_net.empty?
        abort("❌ #{@dir} holds no markdown files, so there is nothing here to import. " \
              'Point this at the folder that holds the posts -- in a Hugo site that is ' \
              'usually content/, in a Jekyll one _posts/.')
      end

      if swept
        root, nested = wider_net.partition { |path| File.dirname(path) == tree_root }
        # Whether a file in the root of a swept tree is a page or a post is
        # the one thing the tree does not say outright, and both answers
        # are wrong somewhere: a Hugo export keeps its articles in posts/,
        # navody/, zpravy/ and its standalone pages in the root, while a
        # plain dump of markdown out of a converter is all posts and has no
        # subdirectories at all. So the subdirectories are the answer: when
        # the articles live somewhere else, what is left at the top is a
        # page. When everything is at the top, it is all posts, exactly as
        # before.
        #
        # Except where the tree has already said what it is: a Hugo SITE
        # root names itself in Hugo's own vocabulary, and the top of its
        # content/ is where a Hugo site keeps its standalone pages -- a
        # site with no section at all has nowhere to LIST an article, so a
        # flat content/ is a site of pages rather than a blog. The guess
        # above exists for the converter's flat dump, and a converter's
        # dump does not arrive with a hugo.toml beside it; without this a
        # site whose content/ happens to be flat got the narrowed walk and
        # none of what narrowing is for -- its front page came in as a post
        # called "index" carrying the site's own blurb, and its about page
        # as an article.
        split = tree_root != @dir || !nested.empty?
        #
        # Section listings are furniture at any depth, not just at the top
        # -- see section_listing?, which is asked about the root as well
        # for the same reason: `_index.md` is Hugo's word, not a guess.
        # Both lists are counted through the ledger, so `files` is simply
        # everything the net caught; the walk is sorted below, and was
        # never in this order anyway.
        @furniture = (root + nested).select { |path| section_listing?(path) }
        @furniture |= root.select { |path| not_a_page?(path) } if split
        @pages = split ? root - @furniture : []
        files = root + nested
      else
        candidates = PathGlob.under(@dir, '*.{md,markdown}')
        @furniture = candidates.select { |path| not_a_page?(path) }
        @pages = candidates - @furniture
        files = posts + drafts + @pages + @furniture
      end

      @total = files.size
      files.sort.each(&block)
    end

    def map(path, media)
      # The furniture is refused, as ever -- but through the ledger, not
      # by silence: left out of the walk entirely, a root _index.md
      # holding real prose was missing from the totals, and the tree read
      # as imported in full when it was not.
      raw = File.read(path, encoding: 'utf-8')
      meta, body = front_matter(raw)
      return :bad_frontmatter if meta.nil?

      # A tree WE wrote says so, and then the furniture list has no
      # business judging it. The two lists never agreed: the build serves
      # a page slugged `changelog`, `index` or `tags` perfectly happily,
      # while the importer treated all sixteen of those names as a
      # repository's own files -- so an export and a re-import came home
      # short by every page that happened to be called one of them.
      own_tree = meta['blogsh'].is_a?(Hash)
      return :site_furniture if !own_tree && @furniture&.include?(path)

      # Read before the blocks are built, because localize is where each
      # file is registered and the address has to be in hand by then.
      # A tree from anywhere else has no such key and this stays empty.
      own = meta['blogsh']
      src_map = own.is_a?(Hash) ? own['media_src'] : nil
      @own_media_src = src_map.is_a?(Hash) ? src_map : {}

      blocks = if path.end_with?('.html')
                 HtmlBlocks.parse(body).blocks
               else
                 markdown_blocks(body)
               end
      blocks = lead_image(meta, body) + blocks
      blocks = localize(blocks, media, path)
      # ...unless the tree is ours and the post really is empty. A post
      # can be live, listed, tagged and titled with content: [] -- the
      # build gives it a real page, and two such posts sit on the archive
      # this was measured against. The exporter writes its front matter
      # and an empty body; read back as "an empty file", both 404'd after
      # a round trip.
      return :empty if blocks.empty? && !own_tree

      draft = path.include?("#{File::SEPARATOR}_drafts#{File::SEPARATOR}") ||
              meta['published'] == false || meta['draft'] == true
      date = item_date(meta, path)
      slug = slug_of(meta, path)
      @slugs[slug] |= [path]
      @authored |= [path] unless meta['author'].to_s.strip.empty?
      title = clean_title(meta['title'])

      post = {
        'slug' => slug,
        'title' => title.empty? ? slug : title,
        'date' => date.iso8601,
        'state' => draft ? 'draft' : 'published',
        'tags' => tags_of(meta),
        'content' => blocks,
        'source' => {
          'platform' => 'jekyll',
          'account' => @account,
          'original_id' => path.delete_prefix("#{@dir}#{File::SEPARATOR}")
        }
      }
      # A file the tree keeps at its root is a page, and saying so is the
      # whole point of walking the root at all. It used to depend on the
      # front matter carrying `type: page` -- which is a key this engine's
      # own export writes and no other generator does, so the feature
      # worked on a round trip and on nothing else. Measured on a real
      # Hugo tree: 74 posts imported, none of them a page, and Kontakt,
      # Komunita and Podpořte nás went into the archive, the tags and the
      # feed as dated articles.
      #
      # The front matter still wins where it says something: `type:` is
      # how a post declares its content type, and a root file that calls
      # itself a quote is a quote. apply_own_keys reads that a few lines
      # down, so this only sets the flag it does not touch.
      post['page'] = true if @pages&.include?(path) && meta['type'].to_s.strip.empty?

      if @keep_permalinks && !draft
        # `type: page` is read by apply_own_keys a few lines down -- too
        # late for the decisions here, where an exported page carrying it
        # must already count as one.
        page = post['page'] == true || meta['type'].to_s.strip == 'page'
        origin = origin_path(meta, served_slug(meta, path, slug), date, page: page)
        # A page already lands at the root, so an origin of /<slug>/ would
        # redirect the address at itself -- which the build then complains
        # about once per build, forever. The Ghost importer has guarded
        # against this since pages arrived; this one had nothing to guard
        # because it never made a page.
        origin = nil if page && origin == "/#{slug}/"
        post['redirect_from'] = [origin] if origin && claim_origin(origin, path)

        # A permalink of our own shape goes on former_slugs instead: see
        # own_former_slug. apply_own_keys below may bring a former_slugs
        # list back from the `blogsh:` key, so this adds rather than
        # replaces, and only when the address is not already there.
        former = own_former_slug(meta)
        if former
          post['former_slugs'] = (Array(post['former_slugs']) + [former]).uniq
        end
      end
      apply_own_keys(post, meta)
      # After apply_own_keys on purpose: `type: page` in the front matter
      # and a returning export's own `state` both land there, and either
      # can change the answer. Only a published page goes on the list --
      # a draft lives under /draft/<token>/, so its root address in `nav:`
      # would be a menu item leading to 404 (the rule ghost.rb set).
      @page_notes[path] = { source: post['source'], slug: post['slug'] } if post['page'] && post['state'] == 'published'
      post
    end

    private

    # The addresses as WRITTEN, not as proposed: PostWriter suffixes a
    # slug that is already taken, and this sentence is what somebody
    # copies into `nav:` -- a predicted address that was never written
    # points the menu at a 404. Nothing is written on a dry run, and then
    # the proposed slug is the honest prediction; feed.rb reads its pages
    # back the same way and for the same reason.
    def page_paths
      @page_notes.values.map do |entry|
        written = PostWriter.find_by_source(entry[:source])
        "/#{written ? File.basename(written, '.json') : entry[:slug]}/"
      end
    end

    # Front matter this engine wrote itself. `./blog.sh export` writes
    # everything markdown has no word for under a single `blogsh:` key,
    # so a tree that came out of blog.sh can go back in whole -- the
    # series, the redirects, the announcement URLs, a draft's token,
    # and above all `source`, which is what makes a re-import land on
    # the same posts instead of doubling the archive. A tree from
    # anywhere else has no such key and nothing here fires.
    #
    # A whitelist rather than a merge: front matter is a file somebody
    # handed us, and a post is not a place to let arbitrary keys in.
    OWN_NESTED_KEYS = %w[source former_slugs redirect_from unpublished_from
                         mastodon_url bluesky_url bluesky_uri draft_token
                         created_at scheduled state page].freeze
    # The ones that sit flat, because a destination engine plausibly
    # understands them too -- Hugo has series, most engines have a pinned.
    OWN_FLAT_KEYS = %w[series series_part pinned hero toc unlisted].freeze

    def apply_own_keys(post, meta)
      own = meta['blogsh']
      # Read per post rather than per tree: a folder can hold both an
      # export and something somebody wrote by hand, and only the posts
      # that carry their own history should be treated as returning
      # home. platform_tag asks this too.
      @own_post = own.is_a?(Hash)

      # A post this engine exported as untitled comes home untitled. Without
      # this the importer sees title: '' and substitutes the slug, which is
      # right for a foreign tree and wrong for ours.
      post['title'] = nil if @own_post && own['untitled']

      OWN_FLAT_KEYS.each do |key|
        value = meta[key]
        post[key] = value unless value.nil?
      end
      # `type: page` is how a page is written -- the same reading
      # scripts/manage_post.rb gives it. Any other type is a content-type
      # override and passes through as one.
      type = meta['type'].to_s.strip
      if type == 'page' then post['page'] = true
      elsif !type.empty? then post['type'] = type
      end

      return unless own.is_a?(Hash)

      OWN_NESTED_KEYS.each do |key|
        value = own[key]
        post[key] = value unless value.nil?
      end
    end

    # Not writing: _site/ is what Jekyll BUILT (every page a second
    # time), public/ and resources/ are Hugo's, the rest is machinery or
    # somebody else's code. Cast over jekyll/jekyll's own docs/, the
    # undiscriminating glob imported the built copies, the template
    # fragments from _includes/ and the repository's readme -- all of it
    # published, all of it dated the day of the import, because a page
    # in a collection carries no date to fall back on.
    NOT_CONTENT = %w[_site _includes _layouts _data _sass _plugins .jekyll-cache .git
                     node_modules vendor public resources themes].freeze
    # The files a repository keeps for people, not readers. Only in the
    # root: _docs/readme.md is a page about something.
    NOT_A_POST = %w[readme license licence contributing changelog code_of_conduct authors].freeze

    # A Jekyll site keeps its pages as markdown in the ROOT -- about.md,
    # colophon.md -- and `./blog.sh export` writes them there for the
    # same reason. Without this they were the one thing a tree could
    # hold that the importer walked straight past, so a site exported
    # and imported back came home one page short.
    #
    # Only when _posts/ or _drafts/ turned something up: with neither,
    # wider_net has already swept the whole tree and would hand the same
    # files over twice. And only files, never directories -- a Hugo page
    # bundle in the root is a post, and comes in through wider_net.
    NOT_A_PAGE = %w[index home 404 feed rss atom sitemap search tags categories archive robots].freeze

    # The names that are furniture rather than a page, wherever the tree
    # was walked from. Hugo's _index.md and home.md are the section and
    # home listings -- pages of the SITE, not pages in it -- and importing
    # them yields a post whose body is the front page.
    def not_a_page?(path)
      # The leading underscore comes off first: Hugo names a section's own
      # listing `_index.md`, and matched literally that is not the "index"
      # this list already knows about -- so the front page of an imported
      # site arrived as a page called "index", with the site's own
      # introduction as its body.
      base = File.basename(path, '.*').downcase.delete_prefix('_')
      NOT_A_PAGE.include?(base) || NOT_A_POST.include?(base)
    end

    # `_index.md` is Hugo's listing for the directory it sits in, and a
    # site has one per section -- so unlike the names above, this one is
    # furniture wherever it is found rather than only at the top. Pointed
    # at a content/ tree, content/posts/_index.md came in as a post called
    # "index" whose body was the section's blurb, dated the day of the
    # import; a site with a dozen sections brought a dozen of them.
    #
    # The underscore is half the test, and it has to be: `index.md`
    # WITHOUT one is the content of a Hugo page bundle -- a real post that
    # happens to live in a directory of its own with its pictures.
    #
    # The other half is whether the directory has anything to list. Hugo
    # spells a BRANCH BUNDLE `_index.md` too -- a page that owns a folder
    # of its own pictures, which is how the themes named further up write
    # About and Contact -- and the name alone cannot tell one from a
    # section's blurb. Refusing both took a real page's prose out of the
    # import entirely, with nothing in the summary naming the file.
    def section_listing?(path)
      return false unless File.basename(path).downcase.start_with?('_index.')

      dir = File.dirname(path)
      # The tree's own top, which is the home page's listing whatever else
      # is or is not beside it.
      return true if dir == tree_root
      # The pages a section exists to list.
      return true if PathGlob.under(dir, '**', '*.{md,markdown,html}').any? { |other| other != path }

      empty_section?(path, dir)
    end

    # A directory holding nothing but its own `_index.md` is either a
    # section nobody has filled yet or a branch bundle -- and a bundle
    # carries what a listing does not: prose of its own, or the files it
    # owns. Either one reads as content; neither leaves it furniture.
    #
    # Both halves are needed. The real Hugo archive has two sections of the
    # first kind, navody/ and zpravy/: a title, no body, nothing beside
    # them -- and a rule that went by files alone would have published both
    # as posts, while one that went by prose alone would still drop an
    # About page that happens to have no pictures.
    def empty_section?(path, dir)
      return false if PathGlob.under(dir, '**', '*').any? { |entry| entry != path && !File.directory?(entry) }

      _meta, body = front_matter(File.read(path, encoding: 'utf-8'))
      body.to_s.strip.empty?
    rescue SystemCallError
      true
    end

    # Hugo's own names for a site's configuration. Their presence next to
    # a content/ directory is what separates a SITE from a tree of posts.
    HUGO_CONFIGS = %w[hugo.toml hugo.yaml hugo.yml hugo.json
                      config.toml config.yaml config.yml config.json].freeze

    # What actually gets walked. Normally the directory that was named --
    # but a Hugo SITE root is not a tree of posts, it is a tree of posts
    # inside content/ with the machinery of a website around it, and
    # pointing at one is what a person naturally does ("import ~/mysite").
    # Walked whole it cost the import everything the root split is for:
    # nothing at all sat at the top level, so nothing was a page and
    # nothing was furniture, and content/_index.md, content/about.md and
    # layouts/_default/single.md alike came in as posts dated the day of
    # the import.
    #
    # Guarded by the config file, because "content" is also just a word: a
    # folder that merely has one is walked exactly as it always was, and
    # only a directory that says in Hugo's own vocabulary what it is gets
    # read as one. Said out loud in the postscript either way -- narrowing
    # the walk is a decision, and a silent one would leave a stray note in
    # the site root unimported and unmentioned.
    def tree_root
      @tree_root ||= hugo_site? ? File.join(@dir, 'content') : @dir
    end

    def hugo_site?
      hugo_layout? && stray_root_markdown.empty?
    end

    # Everything that makes a folder a Hugo site except its own top level.
    # Kept apart from hugo_site? so the postscript can say the one case
    # where the answer is no for a reason the author can act on -- see
    # stray_root_markdown.
    def hugo_layout?
      # A directory holding _posts/ has already said what it is, and it is
      # not this -- checked here rather than left to the caller so the two
      # readings of the tree can never disagree.
      return false if File.directory?(File.join(@dir, '_posts')) || File.directory?(File.join(@dir, '_drafts'))
      return false if PathGlob.under(@dir, 'content', '**', '*.{md,markdown}').empty?

      HUGO_CONFIGS.any? { |name| File.file?(File.join(@dir, name)) } ||
        File.directory?(File.join(@dir, 'config', '_default'))
    end

    # Markdown of its own at the top means the tree IS here, whatever else
    # is beside it -- except for the files a repository keeps for people
    # rather than readers, which wider_net refuses at the root anyway. A
    # Hugo site kept in git has a readme, and reading that as content would
    # have left the feature never firing on the sites it was written for.
    #
    # One TODO.md next to hugo.toml therefore turns the site reading off
    # for the whole folder, which is the safe way round -- but it used to
    # do it in silence, and the postscript that exists to make this
    # decision audible only spoke when the decision went the other way.
    def stray_root_markdown
      @stray_root_markdown ||= PathGlob.under(@dir, '*.{md,markdown}')
                                       .reject { |path| NOT_A_POST.include?(File.basename(path, '.*').downcase) }
    end

    # How many of those names the note carries. A folder with a hundred of
    # them is a markdown tree and the reading is not in doubt anyway; the
    # case the note is written for is one or two stray files.
    STRAY_ROOT_SAMPLE = 5

    def stray_root_names
      names = stray_root_markdown.first(STRAY_ROOT_SAMPLE).map { |path| File.basename(path) }
      names << '...' if stray_root_markdown.length > names.length
      names.join(', ')
    end

    # Jekyll's configuration, the counterpart of HUGO_CONFIGS. Read only
    # for the name the site gives itself -- everything else in it describes
    # a build this engine does not run.
    JEKYLL_CONFIGS = %w[_config.yml _config.yaml].freeze

    # The keys that name a site, per generator. baseURL and url first
    # because a domain belongs to one blog; a title is a fallback, and two
    # blogs can share one.
    HUGO_IDENTITY_KEYS = %w[baseurl title].freeze
    JEKYLL_IDENTITY_KEYS = %w[url title].freeze

    # What `hugo new site` and `jekyll new` leave in the file untouched.
    # Two skeletons nobody has edited declare the SAME name, and an
    # identity two different blogs share is worse than none: it is exactly
    # the silent overwrite the path digest was introduced to end. A tree
    # that still says these things is treated as saying nothing.
    PLACEHOLDER_IDENTITIES = [
      %r{\Ahttps?://(www\.)?example\.(org|com|net)/?\z}i,
      %r{\Ahttps?://localhost(:\d+)?/?\z}i,
      /\Amy new hugo site\z/i,
      /\Ayour awesome title\z/i,
      /\Ayour awesome site\z/i
    ].freeze

    def source_account
      names = declared_identity
      return "#{File.basename(@dir)}-#{Digest::MD5.hexdigest(@dir)[0, 8]}" if names.empty?

      # A readable half out of the strongest name the tree gave -- the host
      # of a baseURL, or the title -- so the account in the archive still
      # says which blog it is. The digest is over all of them.
      label = Slug.slugify(names.first[%r{//([^/]+)}, 1] || names.first)
      label = File.basename(@dir) if label.empty?
      "#{label}-#{Digest::MD5.hexdigest(names.join('|'))[0, 8]}"
    end

    # The names the tree gives itself, strongest first, or empty. Every
    # configuration the tree holds is read and every identity key in it
    # kept, so a site that edited its title but not its baseURL (or the
    # other way round) is still told apart from the skeleton it started as.
    def declared_identity
      names = []
      HUGO_CONFIGS.each { |name| names.concat(identity_values(File.join(@dir, name), HUGO_IDENTITY_KEYS)) }
      PathGlob.under(@dir, 'config', '_default', '*.{toml,yaml,yml,json}').sort.each do |path|
        names.concat(identity_values(path, HUGO_IDENTITY_KEYS))
      end
      JEKYLL_CONFIGS.each { |name| names.concat(identity_values(File.join(@dir, name), JEKYLL_IDENTITY_KEYS)) }
      names
    end

    # A configuration file is somebody else's, in a format this engine does
    # not otherwise read -- so anything it does badly costs the identity
    # and nothing more, and the path digest takes over.
    def identity_values(path, keys)
      return [] unless File.file?(path)

      raw = File.read(path, encoding: 'utf-8')
      data = path.end_with?('.toml') ? toml_subset(raw) : config_yaml(raw)
      return [] unless data.is_a?(Hash)

      lower = data.each_with_object({}) { |(key, value), out| out[key.to_s.downcase] = value }
      keys.filter_map { |key| declared_name(lower[key]) }
    rescue StandardError
      []
    end

    # safe_load, and deliberately without `aliases:`. The file belongs to
    # somebody else, so it is read under the narrowest reader there is --
    # the same one front_matter uses. A `_config.yml` written with a YAML
    # anchor (`<<: *defaults`) therefore reads as nothing here, and the
    # tree falls back to the path digest: one more way to declare nothing,
    # not a way to read a stranger's file more liberally.
    def config_yaml(raw)
      YAML.safe_load(raw, permitted_classes: [Date, Time])
    end

    def declared_name(value)
      name = value.to_s.strip
      return nil if name.empty? || PLACEHOLDER_IDENTITIES.any? { |shape| name.match?(shape) }

      name
    end

    # Markdown only, deliberately, even though a tree WITH _posts/ reads
    # .html as well. This net is cast over a directory nobody has
    # vouched for, and an .html file in one is far more often a rendered
    # page than a post: pointed at a server backup it turned a scan of
    # nothing into 3,237 items, and pointed at a Jekyll site it made
    # posts out of 404.html and the feed. The narrower net loses the
    # rare .html post in a folder with no _posts/; the wider one loses
    # the author's confidence in the whole import.
    def wider_net
      PathGlob.under(tree_root, '**', '*.{md,markdown}').reject do |path|
        parts = path.delete_prefix("#{tree_root}#{File::SEPARATOR}").split(File::SEPARATOR)
        parts[0..-2].any? { |dir| NOT_CONTENT.include?(dir) } ||
          (parts.length == 1 && NOT_A_POST.include?(File.basename(parts[0], '.*').downcase))
      end
    end

    # YAML between --- fences, or Hugo's TOML between +++ -- the TOML
    # reader is a deliberate subset (key = value, arrays, one level),
    # which is what front matter in the wild actually uses.
    def front_matter(raw)
      if (m = raw.match(/\A---\s*\n(.*?)\n---\s*\n?/m))
        [YAML.safe_load(m[1], permitted_classes: [Date, Time]) || {}, m.post_match]
      elsif (m = raw.match(/\A\+\+\+\s*\n(.*?)\n\+\+\+\s*\n?/m))
        [toml_subset(m[1]), m.post_match]
      elsif (m = raw.match(/\A\{\s*\n(.*?)\n\}\s*\n?/m))
        # Hugo's third dialect. Unrecognised, the whole block fell through
        # as BODY: the title, the date, the tags and the draft flag were
        # all lost, and the post was published with its own front matter
        # printed at the top as text.
        begin
          [JSON.parse("{\n#{m[1]}\n}"), m.post_match]
        rescue JSON::ParserError
          [{}, raw]
        end
      else
        [{}, raw]
      end
    rescue Psych::Exception
      [nil, nil]
    end

    # A subset of TOML, deliberately -- but the value scanner was crude
    # enough to be wrong about four ordinary things at once.
    #
    #   draft = true # nekdy pozdeji
    # is not the string "true", so it fell through to the else branch and
    # became a truthy STRING. Hugo's own `draft = true` with a note beside
    # it therefore imported as PUBLISHED, and a post the author was still
    # writing went onto the open web. That is the worst thing an importer
    # can do, and the note is what people write on exactly that line.
    #
    #   tags = [
    #     "kolo",
    #   ]
    # is how a list of any length is written. Read a line at a time, the
    # first one gave the value "[" -- so every tag was lost and a junk tag
    # named "[" took their place.
    #
    # And `.delete(%q{"'})` removed every apostrophe ANYWHERE in a value,
    # so "Novy rok's" became "Novy roks", while a trailing comment stayed
    # in the title.
    def toml_subset(text)
      out = {}
      pending_key = nil
      pending = +''
      text.each_line do |line|
        if pending_key
          pending << line
          next unless pending.include?(']')

          out[pending_key] = toml_array(pending)
          pending_key = nil
          pending = +''
          next
        end
        next unless (m = line.match(/\A\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*\z/))

        key, value = m[1], strip_toml_comment(m[2])
        if value.start_with?('[') && !value.end_with?(']')
          pending_key = key
          pending = value.dup
          next
        end

        out[key] = case value
                   when /\A\[(.*)\]\z/ then toml_array(value)
                   when 'true' then true
                   when 'false' then false
                   else unquote_toml(value)
                   end
      end
      # A list left open at the end of the block is still the author's
      # list: better a tag too many than a post with none.
      out[pending_key] = toml_array(pending) if pending_key
      out
    end

    # A '#' that starts a comment, rather than one inside a quoted value
    # -- a title may hold one, and a colour certainly does.
    def strip_toml_comment(value)
      in_single = false
      in_double = false
      value.each_char.with_index do |c, i|
        in_single = !in_single if c == "'" && !in_double
        in_double = !in_double if c == '"' && !in_single
        return value[0, i].rstrip if c == '#' && !in_single && !in_double
      end
      value
    end

    def toml_array(raw)
      inner = raw[/\[(.*)\]/m, 1] || raw.sub(/\A\[/, '')
      inner.split(',').map { |v| unquote_toml(v.strip) }.reject(&:empty?)
    end

    # The OUTER quotes only. Everything between them is what somebody
    # wrote, apostrophes included.
    def unquote_toml(value)
      text = value.to_s.strip
      return text[1..-2].to_s if text.length >= 2 && (
        (text.start_with?('"') && text.end_with?('"')) ||
        (text.start_with?("'") && text.end_with?("'"))
      )

      text
    end

    # Markdown is the native tongue, with three dialect notes: reference
    # links are markdown this parser does not speak, so they are folded
    # into inline ones first; Liquid tags are Jekyll's, not markdown's --
    # highlight becomes a code fence, the rest is dropped; and image
    # lines point at files in THIS tree (MarkdownParser would treat them
    # as authoring uploads), so they ride through the parse as sentinels
    # and become blocks in localize().
    def markdown_blocks(body)
      # First, before any other rewriting: the comment carries a block's
      # JSON verbatim, and a pass meant for prose (Liquid, lazy lists,
      # inline images) has no business reaching inside it.
      body = own_blocks_to_sentinels(body)
      body = resolve_references(body)
      # Everything from here down is a rewrite of PROSE, so all of it runs
      # through outside_fences. A fence is the one place in a post where
      # markdown, Liquid and shortcodes are the subject rather than the
      # medium: an article explaining how Hugo writes an image showed the
      # reader a code block, and the pass below planted its own sentinel
      # inside it -- @@ssg-image:obrazek.jpg:...@@ went out on the article
      # page, the front page, the tag pages and the feed. The same held
      # for Liquid: a post about {% include %} lost the tag it was about.
      body = outside_fences(body) { |prose| liquid_free(hugo_figures(prose)) }
      body = outside_fences(body) { |prose| join_lazy_list_lines(prose) }
      body = outside_fences(body) { |prose| free_inline_images(prose) }
      body = outside_fences(body) { |prose| images_to_sentinels(prose) }
      blocks, = MarkdownParser.parse_body(body, nil)
      blocks
    end

    # Three parts, and the third is why: markdown puts a picture's
    # caption in the title position -- ![alt](path "caption") -- which
    # is where `./blog.sh export` writes it and where CommonMark says
    # it goes. Carrying only the path and the alt meant an export read
    # back lost the caption outright AND filed the alt text as one, so
    # a photograph came home described by words written for somebody
    # who cannot see it. Every part is CGI-escaped, so a colon inside
    # any of them arrives as %3A and the split stays unambiguous.
    def images_to_sentinels(body)
      body = body.gsub(MarkdownParser::IMAGE_RE) do
        image_sentinel(Regexp.last_match(2), Regexp.last_match(1), Regexp.last_match(3))
      end
      # Line-anchored form ([ \t], NOT \s -- \s eats the newlines and
      # with them the paragraph break after the image).
      body.gsub(/^!\[([^\]]*)\]\(([^)"]+?)(?:[ \t]+"([^"]*)")?\)[ \t]*$/) do
        image_sentinel(Regexp.last_match(2), Regexp.last_match(1), Regexp.last_match(3))
      end
    end

    # Hands BODY to the block a piece at a time, skipping fenced code: a
    # fence is verbatim, so a reference link, a Liquid tag or a wrapped
    # line inside one is somebody's EXAMPLE of markdown and must arrive
    # exactly as written. An unterminated fence runs to the end, the same
    # reading MarkdownParser gives it.
    def outside_fences(body, &block)
      out = +''
      prose = +''
      fence = nil
      body.each_line do |line|
        marker = line.strip[/\A`{3,}/]
        if fence
          out << line
          fence = nil if marker && marker.length >= fence.length && line.strip == marker
        elsif marker
          out << rewritten(prose, &block) << line
          prose = +''
          fence = marker
        else
          prose << line
        end
      end
      out << rewritten(prose, &block)
    end

    # A fence marker only opens a fence when it stands at the start of its
    # own line, and free_inline_images strips the paragraphs it rebuilds --
    # so a chunk of prose that ENDED in a picture came back without its
    # last newline and the ``` below it was glued onto the text. Every
    # fence after that point in the post read as its own opposite: code
    # became prose, prose became code, and the passes that skip fences
    # skipped the wrong half of the article. Harmless while the whole body
    # was rewritten in one piece; not once the rewriting happens chunk by
    # chunk.
    def rewritten(prose)
      text = yield(prose)
      return text if text.empty? || text.end_with?("\n") || !prose.end_with?("\n")

      "#{text}\n"
    end

    # --- reference links -------------------------------------------------

    # [text][label] with [label]: url written somewhere else is ordinary
    # markdown that MarkdownParser does not know. Half of jekyll/jekyll's
    # own release notes use it, and left alone the brackets were
    # published verbatim while the definitions arrived as a paragraph of
    # body text reading "[roadmap]: https://...". Folded into inline
    # links here, before Liquid is stripped -- a definition whose address
    # is Liquid has to still be recognizable as Liquid when it gets there.
    REF_DEF = /\A[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*(\S.*?)[ \t]*\z/
    # The code-span alternative comes first so that `[a][b]` inside
    # backticks is left as the example it is. The trailing lookahead
    # keeps an ordinary inline [text](url) out: without it, a [text]
    # whose words happen to match a defined label grew a second address.
    REF_USE = /(`+[^`]*`+)|(!?)\[([^\]\[\n]+)\](?:\[([^\]\n]*)\])?(?![(\[])/

    def resolve_references(body)
      defs = {}
      body = outside_fences(body) { |prose| take_reference_defs(prose, defs) }
      return body if defs.empty?

      outside_fences(body) { |prose| apply_references(prose, defs) }
    end

    # Only a paragraph made up of nothing BUT definitions is taken --
    # that is how they are written (a block of their own at the foot of
    # the post), and it means a line of prose that merely starts with a
    # bracket cannot be mistaken for one and deleted.
    def take_reference_defs(text, defs)
      text.split(/(\n[ \t]*\n)/).map do |chunk|
        lines = chunk.split("\n").reject { |line| line.strip.empty? }
        next chunk if lines.empty?

        found = lines.map { |line| REF_DEF.match(line) }
        next chunk unless found.all?

        found.each { |m| defs[m[1].strip.downcase] ||= reference_url(m[2]) }
        ''
      end.join
    end

    # The address is the first word -- what may follow it is a title in
    # quotes, not part of the link. Liquid is taken whole instead: it
    # holds spaces ({% post_url 2013-05-06-jekyll-1-0-0-released %}) and
    # liquid_free below needs to see all of it to know the address is
    # unusable.
    def reference_url(value)
      liquid = value[/\A(?:\{%[^%]*%\}|\{\{[^}]*\}\})\S*/]
      return liquid if liquid

      value[/\A\S+/].to_s.delete_prefix('<').delete_suffix('>')
    end

    def apply_references(text, defs)
      text.gsub(REF_USE) do
        m = Regexp.last_match
        next m[0] if m[1] # a code span

        label = m[4].to_s.strip.empty? ? m[3] : m[4]
        url = defs[label.strip.downcase]
        next "#{m[2]}[#{m[3]}](#{url})" if url
        # [text][label] with no such label is a broken reference. The
        # words were meant to be read; the brackets were not.
        next "#{m[2]}#{m[3]}" if m[4]

        m[0] # a plain [bracketed] phrase, not a reference at all
      end
    end

    # --- Liquid ----------------------------------------------------------

    # {% raw %} is the author saying "print this, do not run it", and
    # what it wraps is almost always an EXAMPLE of Liquid -- precisely
    # the text the blanket strip below eats. It ate `{{ page.name }}` out
    # of Jekyll's own release notes and left an empty code span, an odd
    # number of backticks, and the list around it collapsed into one
    # paragraph.
    RAW_BLOCK = /\{%\s*raw\s*%\}\n?(.*?)\n?\{%\s*endraw\s*%\}/m
    LIQUID = /\{%[^%]*%\}|\{\{[^}]*\}\}/
    # site.baseurl and site.url are this very site's own root, spelled
    # the way Jekyll wants it spelled: what is left after removing it is
    # still an address that resolves. Every other variable pointed
    # somewhere else entirely.
    SITE_ROOT = /\A\{\{\s*site\.(?:baseurl|url)\s*\}\}/

    # --- Hugo shortcodes -------------------------------------------------

    # {{< figure src="x.jpg" alt="..." >}} is how Hugo writes a picture --
    # its one built-in shortcode that every theme's documentation leads
    # with. To the blanket strip below it is just another {{ }}, so the
    # line vanished and with it the photograph, which in a page bundle
    # was lying on disk right next to the article. Nothing said so
    # either: no file was named, so nothing could be reported missing.
    #
    # Read before the strip and turned straight into a sentinel rather
    # than back into markdown: the caption is somebody else's sentence
    # and may hold the quotes that markdown's title position cannot.
    # Every other shortcode still falls through to the strip.
    FIGURE = /\{\{[<%]\s*figure\s+(.*?)\s*\/?[>%]\}\}/m
    FIGURE_ATTR = /([a-z]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/

    def hugo_figures(text)
      text.gsub(FIGURE) do
        whole = Regexp.last_match(0)
        attrs = {}
        Regexp.last_match(1).scan(FIGURE_ATTR) { |key, dq, sq| attrs[key] = dq || sq }
        src = attrs['src'].to_s.strip
        # A figure with no src names no picture; let the strip have it.
        next whole if src.empty?

        # Hugo's caption is the line under the picture, its title a
        # heading above -- either is a caption here, and the alt stays
        # the alt. Blank lines around it because a figure is a block, and
        # a shortcode may sit at the end of a paragraph.
        caption = attrs['caption'].to_s.strip
        caption = attrs['title'].to_s.strip if caption.empty?
        "\n\n#{image_sentinel(src, attrs['alt'], caption)}\n\n"
      end
    end

    def liquid_free(body)
      out = +''
      rest = body
      while (m = RAW_BLOCK.match(rest))
        out << strip_liquid(m.pre_match) << m[1]
        rest = m.post_match
      end
      out << strip_liquid(rest)
    end

    # The first word after "highlight" is the language; what may follow
    # it are the tag's other arguments, which Jekyll documents
    # ({% highlight ruby linenos %}, mark_lines="1 2"). Insisting on the
    # language alone let those blocks fall through to the blanket strip,
    # and a code sample came out as prose: indentation gone, the line
    # breaks turned into spaces, a blank line inside it splitting the
    # sample into several paragraphs.
    #
    # The body may not contain another opening tag, so a block whose
    # {% endhighlight %} was never written stops at itself instead of
    # reaching forward to the next block's closing tag and swallowing
    # everything a reader had in between.
    def strip_liquid(text)
      text = text.gsub(%r{\{%\s*highlight\s+(\S+)[^%]*%\}((?:(?!\{%\s*highlight\b).)*?)\{%\s*endhighlight\s*%\}}m) do
        "\n```#{Regexp.last_match(1)}\n#{Regexp.last_match(2).strip}\n```\n"
      end
      text = drop_liquid_addresses(text)
      text.gsub(/\{%[^%]*%\}/, '').gsub(/\{\{[^}]*\}\}/, '')
    end

    # The one place a blanket strip does damage rather than harm: it
    # leaves the REST of the path standing, so
    # [check the issues]({{ site.repository }}/issues) turned into a
    # working link to /issues -- of the NEW blog. A dead link gets
    # noticed and fixed; a live wrong one never does. Images are left to
    # the strip on purpose: their Liquid is a path prefix, and what
    # remains is a file that really is in this tree.
    def drop_liquid_addresses(text)
      text.gsub(/(?<!!)\[([^\]\n]*)\]\(([^)\n]*)\)/) do
        whole, label, url = Regexp.last_match.values_at(0, 1, 2)
        next whole unless url.match?(LIQUID)

        rest = url.sub(SITE_ROOT, '')
        next "[#{label}](#{rest})" unless rest.match?(LIQUID) || rest.strip.empty?

        @liquid_links += 1
        label
      end
    end

    # --- lists -----------------------------------------------------------

    # kramdown hard-wraps at column ~120, so a long list item continues
    # on the next line with no bullet in front of it -- a lazy
    # continuation, ordinary markdown. parse_list refuses a paragraph it
    # cannot read as a list end to end, so ONE wrapped item turned the
    # whole list into a paragraph with the dashes showing. Two of the ten
    # posts in jekyll/jekyll's own docs do it.
    #
    # Only a paragraph that OPENS with a list item is touched: text
    # followed by a list is a different shape with a different answer,
    # and joining there would eat the text.
    def join_lazy_list_lines(text)
      text.split(/(\n[ \t]*\n)/).map do |chunk|
        lines = chunk.split("\n", -1)
        next chunk unless lines.length > 1 && list_item?(lines.first)

        lines.each_with_object([]) do |line, out|
          if out.empty? || line.strip.empty? || list_item?(line) || interrupts_list?(line)
            out << line
          else
            out[-1] = "#{out[-1]} #{line.strip}"
          end
        end.join("\n")
      end.join
    end

    def list_item?(line)
      stripped = line.strip
      MarkdownParser::UL_ITEM_RE.match?(stripped) || MarkdownParser::OL_ITEM_RE.match?(stripped)
    end

    # Markdown lets these end a paragraph without a blank line before
    # them, so they are a new block, not the tail of the item above.
    def interrupts_list?(line)
      line.match?(/\A[ \t]*(?:\#{1,6}[ \t]|>|\||`{3,}|-{3,}[ \t]*\z|_{3,}[ \t]*\z)/)
    end

    # An image the schema cannot place: one sitting inside a line of text
    # rather than alone on its own. The parser ABORTS on those, which is
    # right when you are saving a post you just wrote -- it stops you
    # losing a picture and points at the line. It is wrong here: nobody
    # importing somebody else's site wrote that line, cannot fix it in the
    # archive, and one such paragraph used to take the whole run down with
    # it. A real Hugo export of 77 posts had 23 of them across 11 files --
    # 14% of the site, and none of the other 66 posts imported either.
    #
    # None of the shapes are exotic. Every WordPress-to-Hugo conversion
    # writes "![](photo.png)*caption*"; every README puts badges in a list;
    # screenshots end sentences. So they are rearranged the way a person
    # would rearrange them, rather than refused:
    #
    #   [![alt](img)](href)  ->  [alt](href)      a badge: keep the LINK,
    #                                             drop the decoration
    #   [![](img)](href)     ->  ![](img)         a thumbnail: keep the
    #                                             PICTURE, drop the
    #                                             click-through
    #   text ![](img) text   ->  text / img / text, each on its own line
    #
    # The count rides back to the caller so the run can say it happened --
    # a silent rewrite of somebody's archive is exactly what an import
    # must not do.
    LINKED_IMAGE = /\[!\[([^\]]*)\]\(([^)\s]+)[^)]*\)\]\(([^)\s]+)[^)]*\)/
    INLINE_IMAGE = /(?<!\\)!\[[^\]]*\]\([^)\s]+[^)]*\)/

    def free_inline_images(body)
      body = body.gsub(LINKED_IMAGE) do
        alt = Regexp.last_match(1).to_s.strip
        img = Regexp.last_match(2)
        href = Regexp.last_match(3)
        @rearranged += 1
        # With alt text the link can speak for itself ("Google Play");
        # without it the picture is the only thing there is to keep.
        alt.empty? ? "\n\n![](#{img})\n\n" : "[#{alt}](#{href})"
      end

      body.split(/\n[ \t]*\n/).map { |para| split_around_images(para) }.join("\n\n")
    end

    def split_around_images(para)
      # Code spans first: "`![x](y)`" is an example of the syntax, not an
      # image, and the parser masks them for the same reason.
      return para unless para.gsub(/`[^`]*`/m, '`x`').match?(INLINE_IMAGE)
      return para if para.strip.match?(/\A#{INLINE_IMAGE.source}\z/)

      pieces = []
      rest = para
      while (m = INLINE_IMAGE.match(rest))
        before = m.pre_match
        pieces << before unless before.strip.empty?
        image, rest = fold_caption(m[0], m.post_match)
        pieces << image
        @rearranged += 1
      end
      pieces << rest unless rest.strip.empty?
      # A list whose item ended in a screenshot keeps its bullet and the
      # picture follows it -- the image was last in the item anyway, so
      # nothing changes order.
      pieces.map(&:strip).join("\n\n")
    end

    # "![](photo.png)*co je na obrázku*" -- WordPress's caption, and what
    # every conversion out of it writes. Moving the picture onto its own
    # line left the italics behind as a paragraph, which reads as a
    # sentence fragment even when the photograph arrives; when it does
    # not (an archive whose images are on a domain that no longer
    # answers) the picture is dropped and the fragment is all that is
    # left -- an install guide down to three paragraphs reading "výběr
    # jazyka", "výběr časového pásma", "rozložení klávesnice". It is a
    # caption, so it goes where a caption goes, and it lives or dies with
    # the picture it belongs to.
    #
    # Only italics that finish the line, and only onto a picture that has
    # no caption of its own already.
    TRAILING_CAPTION = /\A[ \t]*(?:\*([^*\n]+)\*|_([^_\n]+)_)[ \t]*(?=\n|\z)/

    def fold_caption(image, rest)
      return [image, rest] if image.match?(/\s"[^"]*"\)\z/)
      return [image, rest] unless (m = TRAILING_CAPTION.match(rest))

      caption = (m[1] || m[2]).strip
      # The title position is quote-delimited, so a caption holding one
      # would rewrite the picture's address. Rare enough to leave alone.
      return [image, rest] if caption.empty? || caption.include?('"')

      # Block form: a caption is prose, and sub's replacement string reads
      # a backslash in it as a back-reference.
      [image.sub(/\)\z/) { " \"#{caption}\")" }, m.post_match]
    end

    SENTINEL = /@@ssg-image:([^:@]*):([^:@]*):([^@]*)@@/

    def image_sentinel(src, alt, title)
      "@@ssg-image:#{CGI.escape(src.to_s.strip)}:#{CGI.escape(alt.to_s)}:#{CGI.escape(title.to_s)}@@"
    end

    # What `./blog.sh export` writes above the HTML it had to fall back
    # to for a block markdown cannot express -- video, audio, a link
    # card. Reading it back is what turns an export into a round-trip
    # instead of a one-way door: the block comes home as a block rather
    # than as a paragraph of markup. The comment ends at the first
    # " -->", which the exporter guarantees by escaping "--" inside the
    # JSON; the HTML under it runs to the blank line and is dropped with
    # it, since the block itself says everything that markup did.
    #
    # Anybody else's HTML comments are untouched: the marker is specific,
    # and a tree that never came from here simply has none.
    OWN_BLOCK_RE = /^<!-- blogsh:block (\{.*?\}) -->\n.*?(?=\n\n|\z)/m
    OWN_BLOCK_SENTINEL = %r{\A@@blogsh-block:([A-Za-z0-9+/=]+)@@\z}

    def own_blocks_to_sentinels(body)
      body.gsub(OWN_BLOCK_RE) { "@@blogsh-block:#{[Regexp.last_match(1)].pack('m0')}@@" }
    end

    # The block as it was written, with its media re-registered: the JSON
    # names each file where it sits in the export
    # (/assets/<year>/<slug>/01.mp4), and from_file copies it into this
    # archive under the number it gets here -- the same path an image
    # takes through image_block.
    # The types `./blog.sh export` actually writes through this channel:
    # the four it always renders as HTML, plus the ones MarkdownWriter has
    # no form for. Anything else claiming to be one of ours is a block
    # somebody typed into a markdown file, and the import wizard offers to
    # read "any folder of markdown files a converter produced" -- trees
    # nobody here wrote. The comment above OWN_BLOCK_RE assumed the marker
    # was proof of where a block came from; it is not, and anyone can type
    # it. This does not make the restored block trusted -- see the note in
    # own_block -- it only stops the marker from being a way to invent
    # block types the markdown path could never produce.
    OWN_BLOCK_TYPES = %w[video audio link file chat code embed gallery].freeze

    def own_block(packed, media)
      block = JSON.parse(packed.unpack1('m'))
      return nil unless block.is_a?(Hash)
      return nil unless OWN_BLOCK_TYPES.include?(block['type'].to_s)

      # ⚠️ What this does NOT close: `embed_html` is rendered raw by the
      # build (build/build_blog.rb, the video branch), so a crafted tree
      # can still put markup on the page through a block that IS one of
      # ours. That is not a Jekyll question -- Import::Tumblr passes an
      # export's embed_html through the same way -- but a property of the
      # whole import surface, and deciding it means deciding whether a
      # legitimate Instagram or Twitter embed (blockquote plus script)
      # still renders. Daniel's call, not one to make inside a bug fix.

      %w[media poster].each do |key|
        entries = block[key]
        next unless entries.is_a?(Array)

        block[key] = entries.filter_map do |entry|
          next entry unless entry.is_a?(Hash) && entry['url']

          src = entry['url'].to_s
          local = src.start_with?('/') ? root_relative(src) : File.expand_path(src, @dir)
          name = media.from_file(local, src: entry['src'] || own_media_src(local))
          name ? entry.merge('url' => name) : nil
        end
      end
      block
    rescue JSON::ParserError
      nil
    end

    # `image:` in the front matter is how Hugo's themes -- Blowfish,
    # Congo, PaperMod -- name the picture an article leads with. This
    # engine has no such field, and the key was read by nobody: three
    # articles in a real Hugo tree named one, and all three lost it.
    # What it does have is a first image block, which is what a lead
    # picture is; Ghost's feature image and Wix's cover come home the
    # same way, and localize turns the name into a file in this archive.
    #
    # Not when the body already shows the same file: a theme's `image:`
    # doubles as the social-card picture and is usually the very
    # photograph the post opens with, so importing both shows it twice.
    def lead_image(meta, body)
      src = meta['image']
      return [] unless src.is_a?(String)

      src = src.strip
      return [] if src.empty? || body.include?(src)

      [{ 'type' => 'image', 'media' => [{ 'url' => src }] }]
    end

    def localize(blocks, media, post_path)
      blocks.filter_map do |block|
        if block['type'] == 'text' && (m = block['text'].to_s.strip.match(OWN_BLOCK_SENTINEL))
          own_block(m[1], media)
        elsif block['type'] == 'text' && (m = block['text'].to_s.strip.match(/\A#{SENTINEL}\z/))
          image_block(CGI.unescape(m[1]), CGI.unescape(m[2]), CGI.unescape(m[3]), media, post_path)
        elsif block['type'] == 'image'
          # From the HtmlBlocks path: the URL is still the tree's own.
          image_block(block.dig('media', 0, 'url').to_s, nil, nil, media, post_path)
        else
          block
        end
      end
    end

    # Where the file in the tree was originally fetched from, if the tree
    # says. `./blog.sh export` writes that under `blogsh: media_src:`,
    # keyed by the file's own name -- the width and the height an importer
    # can measure back out of the bytes, but nothing in a JPEG remembers
    # the address it was downloaded from. Without it coming home, an
    # archive exported and imported back would fetch every one of its
    # images again on the next run.
    def own_media_src(local_path)
      @own_media_src[File.basename(local_path)]
    end

    # A root-relative path is looked up in the tree, a relative one next
    # to the post, an absolute URL downloaded -- in that order of
    # likelihood for a static site's own images.
    # Where a root-relative src actually lives. Hugo serves static/ AT the
    # site root, so /images/foto.jpg in a Hugo tree is static/images/foto.jpg
    # on disk -- looked for at the root it was reported missing while the
    # file sat right there, and the post lost a picture the tree still had.
    # Jekyll serves from the root itself, so both shapes have to be tried;
    # whichever is there wins, and when neither is, the root path is what
    # the miss is reported against, exactly as before.
    def root_relative(src)
      candidates = [File.join(@dir, 'static', src), File.join(@dir, src)]
      candidates.find { |path| File.file?(path) } || candidates.last
    end

    def image_block(src, alt, title, media, post_path)
      # A data: URI is the image itself, inline -- nothing to fetch,
      # nothing on disk, and no block form for inline bytes here. Dropped
      # quietly and without a number: handed to from_file it showed up in
      # the summary as a missing file, base64 body and all.
      return nil if src.start_with?('data:')

      # Protocol-relative means "the page's scheme", and the page is
      # long gone -- assume https, as a browser on an https page does.
      src = "https:#{src}" if src.start_with?('//')

      # Any scheme, not just http(s): an ftp: or mailto: src is no path
      # in this tree, and joining it onto @dir named a local file the
      # archive never had. from_url's failure line tells the real story
      # -- a remote resource that could not be fetched.
      local = nil
      filename = if src.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
                   media.from_url(src)
                 else
                   local = src.start_with?('/') ? root_relative(src) : File.expand_path(src, File.dirname(post_path))
                   # Unconditionally: from_file spends the number and records
                   # the miss itself. Stat-ing here instead made numbering
                   # depend on which files happened to be present.
                   media.from_file(local, src: own_media_src(local))
                 end
      if filename
        entry = { 'url' => filename }
        width, height = media.dimensions(filename)
        entry['width'] = width if width
        entry['height'] = height if height
      elsif local
        # A file the tree names but does not hold. Dropping the block
        # dropped more than the picture -- its alt text and caption went
        # with it, and a post whose ONLY block it was vanished from the
        # import whole. The build already lives with a named file that is
        # not there (it says MISSING and renders the alt), so the block
        # stays, under the name the tree used: put the file into the
        # post's media folder and the next build picks it up. from_file
        # above has recorded the miss; the postscript counts these.
        @missing_media[local] = true
        entry = { 'url' => File.basename(local) }
        known = own_media_src(local)
        entry['src'] = known if known
      else
        return nil
      end
      block = { 'type' => 'image', 'media' => [entry] }
      # Each word where it belongs. The alt text is what a picture is for
      # somebody who cannot see it; the caption is what it says to
      # everybody. They are different sentences and the markdown keeps
      # them apart, so this does too -- it used to file the alt as the
      # caption and drop the caption, which printed the description under
      # the photograph and left the screen reader with nothing.
      #
      # And never one from the other: markdown renders no alt text, so a
      # picture that has only an alt shows no caption on the site it came
      # from. Copying the alt in printed a sentence under the photograph
      # that the original page never showed -- and an export read back
      # stopped matching itself on exactly the alt-only images.
      block['alt_text'] = alt unless alt.to_s.empty?
      block['caption'] = title unless title.to_s.empty?
      block
    end

    # Jekyll pads neither the month nor the day when it reads a filename,
    # and exports in the wild are written both ways
    # (2021-9-1-alt-date-format.md). Insisting on two digits missed the
    # date AND the prefix in the slug, so the post arrived called
    # "2021-9-1-alt-date-format", dated the moment of the import, filed
    # under this year.
    DATED_NAME = /\A(\d{4})-(\d{1,2})-(\d{1,2})-/

    # A filename that has been through a URL keeps its escapes on disk --
    # a WordPress export writes %ef%bf%bcawesomewm-basics.md, which is the
    # object-replacement character U+FFFC and then the title. Slugified as
    # written, the escaping itself became the address: ef-bf-bcawesomewm-
    # basics. Decoded by hand rather than with CGI.unescape, which also
    # reads "+" as a space and would take the plus out of c++-tutorial.md.
    PERCENT_ESCAPE = /%[0-9A-Fa-f]{2}/

    def percent_decode(name)
      return name unless name.match?(PERCENT_ESCAPE)

      name.gsub(PERCENT_ESCAPE) { |hex| hex[1, 2].hex.chr }
          .force_encoding(Encoding::UTF_8).scrub('')
    end

    def base_name(path)
      base = File.basename(path).sub(/\.(md|markdown|html)\z/, '').sub(DATED_NAME, '')
      # A Hugo page bundle is a directory with an index.md -- the
      # directory is the name. A branch bundle spells the same thing
      # `_index.md` (see section_listing?) and Hugo serves it from the
      # directory just the same, so an About page written that way comes
      # in at /about/ rather than as a post called "index".
      %w[index _index].include?(base) ? File.basename(File.dirname(path)) : base
    end

    def explicit_slug(meta)
      value = (meta['slug'] || meta['basename']).to_s
      value.empty? ? nil : value
    end

    def slug_of(meta, path)
      explicit = explicit_slug(meta)
      # A slug that came out of ./blog.sh export is the address the site is
      # serving TODAY, not a name to be tidied. Running slugify over it
      # renamed every slug that was not already slugify-stable -- an
      # underscore, a trailing dash -- and wrote no former_slugs, no
      # redirect_from and no stub, so 25 live URLs on one real archive
      # answered before the round trip and 404'd after it. Only OUR export
      # is trusted this way: a tree from anywhere else has no blogsh: key
      # and is tidied as before.
      return explicit if explicit && meta['blogsh'].is_a?(Hash)
      return Slug.slugify(explicit) if explicit

      Slug.slugify(percent_decode(base_name(path)))
    end

    # What the old site actually served, which is the only thing a
    # redirect is worth writing about. Normally that is the slug -- but an
    # escaped filename IS a URL path segment already, and the generator
    # handed it out letter for letter. Redirecting from the decoded name
    # would send visitors from an address nobody ever had.
    def served_slug(meta, path, slug)
      return slug if explicit_slug(meta)

      raw = base_name(path)
      raw.match?(PERCENT_ESCAPE) ? raw : slug
    end

    # Characters that occupy no space and say nothing. U+FFFC is what a
    # WordPress export leaves where an embed used to be, and it rode into
    # the title untouched: an archive entry, a heading and a <title> tag
    # that all opened with a gap nobody could see, let alone delete.
    INVISIBLE = /[\u00AD\u200B-\u200F\u202A-\u202E\u2060\uFEFF\uFFFC]/

    def clean_title(value)
      value.to_s.gsub(INVISIBLE, '').strip
    end

    def item_date(meta, path)
      return Time.parse(meta['date'].to_s) if meta['date'] && !meta['date'].to_s.empty?

      if (m = File.basename(path).match(DATED_NAME))
        # Noon, not midnight: a date-only value read at UTC midnight can
        # land on yesterday in the site's timezone.
        return Time.local(m[1].to_i, m[2].to_i, m[3].to_i, 12)
      end
      File.mtime(path)
    rescue ArgumentError
      File.mtime(path)
    end

    def tags_of(meta)
      %w[tags tag categories category].flat_map do |key|
        value = meta[key]
        case value
        when Array then value.map(&:to_s)
        when String then value.split(/[,\s]+/)
        else []
        end
      end.map(&:strip).reject(&:empty?).uniq { |t| t.downcase }
    end

    # The front matter's own permalink wins, then the pattern given at
    # the door. No pattern, no redirect -- a guessed address would 404
    # with a straight face.
    #
    # The pattern never applies to a page: it says where the old site
    # kept its POSTS, and a root page never lived on a dated address --
    # a /:year/:month/:day/:title/ pattern gave kontakt a redirect from
    # /2021/12/11/kontakt/, an address the old site never served, and
    # the build wrote a stub on it.
    # A permalink under /posts/ is where the post lived on THIS engine,
    # which is what former_slugs records -- redirect_from is for addresses
    # from somewhere else, and the build refuses any whose first segment
    # is one of its own. Every post blog.sh exports carries
    # permalink: /posts/<year>/<slug>/, so KEEP_PERMALINKS=1 -- the one
    # thing an operator can do to save a renamed address -- wrote exactly
    # the entry the build throws away, with a warning in the middle of a
    # build log. Returned as nil here and handled as a former slug by the
    # caller instead.
    def own_former_slug(meta)
      explicit = (meta['permalink'] || meta['url']).to_s
      m = explicit.match(%r{\A/posts/(\d{4}/[^/]+)/?\z})
      m && m[1]
    end

    def origin_path(meta, slug, date, page: false)
      return nil if own_former_slug(meta)

      explicit = meta['permalink'] || meta['url']
      return explicit.to_s if explicit && !explicit.to_s.empty?
      return nil if page || !@permalink

      @permalink.gsub(':year', format('%04d', date.year))
                .gsub(':month', format('%02d', date.month))
                .gsub(':day', format('%02d', date.day))
                .gsub(':title', slug)
                .gsub(':slug', slug)
    end

    # One old address redirects to one place. A tree that holds two files
    # for one slug -- the flat post and the page bundle it grew into --
    # derives the same origin for both, and handing it to both makes the
    # build choose. The first file in walk order gets it, which is also
    # the file PostWriter writes first, i.e. the one that keeps the
    # unsuffixed slug the origin used to serve; the later copy arrives
    # with no redirect, exactly like a post that never had an address.
    def claim_origin(origin, path)
      @origins[origin] ||= path
      @origins[origin] == path
    end
  end
end
