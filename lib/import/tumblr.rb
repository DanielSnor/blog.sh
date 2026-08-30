# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'
require 'uri'
require_relative '../i18n'
require_relative '../slug'
require_relative 'permalinks'
require_relative 'html_blocks'

module Import
  # Imports a Tumblr blog through the API in NPF format. Every post the
  # endpoint hands over is taken, reblogs included -- a Tumblr blog IS its
  # reblogs, and unlike a Bluesky repost or a Mastodon boost a reblog is an
  # entry of its own that often carries the owner's commentary. What the
  # other blogs in the trail contributed is kept WITH THEIR NAMES on it
  # (see #map) rather than merged into the owner's voice.
  #
  # The API-key endpoint is "retrieve published posts": drafts, the queue
  # and private posts live behind other endpoints that want OAuth, so they
  # are not in an import. The draft branch in #map is a safety net for a
  # response that does carry one, not a promise that any will arrive.
  #
  # All media is downloaded, so nothing stays hotlinked to Tumblr's CDN and
  # an import of a few thousand posts runs for hours.
  class Tumblr
    PAGE_SIZE = 20

    # Same writer-not-option shape as Feed, for the same reason: the
    # wizard asks about permalinks after the adapter exists.
    attr_accessor :keep_permalinks

    def initialize(blog, api_key:, keep_permalinks: false)
      @blog = blog
      @api_key = api_key
      @account = blog.split('.').first
      @keep_permalinks = keep_permalinks
      @unmapped_permalinks = 0
    end

    def label
      "Tumblr (#{@blog})"
    end

    # Known only once the first page comes back, which is why this is read
    # after iteration starts rather than up front.
    def total
      @total
    end

    def each_item
      offset = 0
      loop do
        data = fetch_page(offset)
        posts = data.dig('response', 'posts') || []
        @total ||= data.dig('response', 'blog', 'total_posts')
        break if posts.empty?

        posts.each { |post| yield post }

        offset += posts.size
        break if @total && offset >= @total
      end
    end

    def map(item, media)
      # An ask post keeps the question in `layout`, not in the blocks
      # themselves: {"type": "ask", "blocks": [0, 1], "attribution": {...}}
      # says which of `content`'s blocks somebody else wrote, and who. With
      # the field ignored, a stranger's question came out as the opening
      # paragraphs of the post, reading as the blog owner's own words, and
      # the asker's name never reached the archive at all -- it lives
      # nowhere else. The same defect the trail had, from the other end.
      #
      # A question is a quote with an attribution, and the schema already
      # has both: subtype "quote" and `cite`. Costs the link to the asker's
      # blog, since `cite` is plain text, and buys not inventing a word for
      # "asked" in three languages. An anonymous ask -- Tumblr simply omits
      # `attribution` -- stays an unattributed quote rather than gaining a
      # localized "Anonymous" the source never said.
      #
      # `layout` of type "rows" is left alone: it is a display grid, not a
      # statement about who wrote what.
      ask = (item['layout'] || []).find { |entry| entry['type'] == 'ask' } || {}
      ask_blocks = (ask['blocks'] || []).map(&:to_i)

      # The indices point into the ORIGINAL `content` array, so they have to
      # be read while walking it. Resolving them against the mapped blocks
      # instead would go wrong the moment map_block drops one (a block type
      # the engine has no shape for): everything after the hole shifts by
      # one, and the ask would mark the owner's own answer as the question.
      blocks = []
      quoted = []
      # Where the question starts, remembered as a POSITION while the walk is
      # here. Looking it up afterwards with Array#index finds the first block
      # that is EQUAL, and a post whose question is a picture it already
      # showed once put the credit above the wrong one -- at the top of the
      # post, in front of the owner's own words.
      quoted_at = nil
      (item['content'] || []).each_with_index do |b, index|
        mapped = map_block(b, media)
        next unless mapped

        if ask_blocks.include?(index)
          mapped = as_question(mapped)
          quoted_at ||= blocks.size
          quoted << mapped
        end
        blocks << mapped
      end
      asker = ask.dig('attribution', 'blog', 'name').to_s.strip
      unless asker.empty?
        # On the last quote, so it reads the way a quotation ends: the words,
        # then whose they were. An ask can be a picture and nothing else,
        # though, and then there is no quote to carry the name -- it used to
        # be dropped on the floor, publishing a stranger's image as the
        # blog's own with the one record of whose it was thrown away. A
        # credit line above it says the same thing the trail's does.
        last = quoted.reverse.find { |b| b['subtype'] == 'quote' }
        if last
          last['cite'] = asker
        elsif quoted_at
          blocks.insert(quoted_at, { 'type' => 'text', 'text' => "#{asker}:",
                                     'formatting' => [{ 'type' => 'bold', 'start' => 0, 'end' => asker.length }] })
        end
      end

      # A reblog carries the posts it was built on in `trail`, and those
      # belong to OTHER blogs -- 12 of 20 posts in one real capture had a
      # trail, 10 of them with nothing else, so the whole post was someone
      # else's photo or text. This used to append it bare, on the
      # assumption that everything on the blog was written by its owner:
      # one post came out as ten consecutive paragraphs by four different
      # people with nothing between them, reading as the owner's own
      # monologue. The content stays (skipping it would drop most of a
      # typical Tumblr blog, and the trail is what a reblog IS), but every
      # stretch of it now says whose it is.
      (item['trail'] || []).each do |entry|
        mapped = (entry['content'] || []).filter_map { |b| map_block(b, media) }
        next if mapped.empty?

        credit = trail_credit(entry)
        blocks << credit if credit
        blocks.concat(mapped)
      end

      title, blocks = extract_title(blocks)
      return :empty if blocks.empty? && title.nil?

      state = item['state'] == 'published' ? 'published' : 'draft'
      post = {
        'slug' => build_slug(item),
        'title' => title,
        'date' => Time.parse(item['date']).iso8601,
        'state' => state,
        'tags' => item['tags'] || [],
        'content' => blocks,
        'source' => {
          'platform' => 'tumblr',
          'account' => @account,
          'post_url' => item['post_url'],
          'original_id' => item['id']
        }
      }
      # post_url carries whatever domain the blog answers at -- the custom
      # domain if it has one, which is the only case the wizard says yes in.
      if @keep_permalinks && state == 'published'
        path = Permalinks.local_path(item['post_url'])
        path ? post['redirect_from'] = [path] : @unmapped_permalinks += 1
      end
      post
    end

    def postscript
      return nil if @unmapped_permalinks.zero?

      I18n.t('import.note.tumblr_unmapped', count: @unmapped_permalinks)
    end

    private

    def fetch_page(offset, retries = 3)
      uri = URI("https://api.tumblr.com/v2/blog/#{@blog}/posts")
      uri.query = URI.encode_www_form(api_key: @api_key, npf: true, limit: PAGE_SIZE, offset: offset)
      data = JSON.parse(Net::HTTP.get(uri))

      # A rejected key or a misspelled blog still returns valid JSON, with the
      # reason in `meta` and an empty Array where `response` would be an
      # object. Without this the first thing a new user sees is a TypeError
      # from Hash#dig several frames away from the actual problem.
      status = data.dig('meta', 'status')
      unless status.nil? || status == 200
        abort("❌ Tumblr API returned #{status} #{data.dig('meta', 'msg')} for #{@blog} -- check the API key and the blog name.")
      end

      data
    rescue StandardError
      raise if retries.zero?

      sleep 1
      fetch_page(offset, retries - 1)
    end

    # Tumblr's own first-class title is a leading heading1 block, so it's
    # lifted out of the content rather than duplicated in it.
    def extract_title(blocks)
      first = blocks.first
      return [nil, blocks] unless first && first['type'] == 'text' && first['subtype'] == 'heading1'

      [first['text'], blocks[1..]]
    end

    # The "blogname:" line Tumblr itself renders above a trail item, as a
    # link to that blog. Not a translated string: the only word in it is a
    # name the API supplied.
    #
    # Nothing is credited to the account itself -- its own posts come back
    # around in a trail all the time (1 of 12 trail items in the real
    # capture, and 2 of 4 in one four-blog thread), and crediting yourself
    # in your own archive is noise.
    def trail_credit(entry)
      blog = entry['blog'] || {}
      # broken_blog_name is what the API sends instead of `blog` when the
      # blog is gone -- the name is exactly what still matters then.
      name = (blog['name'] || entry['broken_blog_name']).to_s.strip
      return nil if name.empty? || name.casecmp?(@account)

      # Offsets are codepoints, as everywhere in NPF, and cover the name
      # rather than the colon after it.
      formatting = [{ 'type' => 'bold', 'start' => 0, 'end' => name.length }]
      url = blog['url'].to_s
      formatting << { 'type' => 'link', 'start' => 0, 'end' => name.length, 'url' => url } unless url.empty?
      { 'type' => 'text', 'text' => "#{name}:", 'formatting' => formatting }
    end

    # A heading keeps its own subtype: it is already marked as not being
    # running prose, and a question titled with one is nothing a real ask
    # produces. Everything else a text block can be (NPF's list and indent
    # subtypes) renders as a paragraph here anyway, so nothing is lost by
    # making it a quote instead.
    def as_question(block)
      return block unless block['type'] == 'text'
      return block if block['subtype'].to_s.start_with?('heading')

      block.merge('subtype' => 'quote')
    end

    def map_block(block, media)
      case block['type']
      when 'text' then text_block(block)
      when 'image' then image_block(block, media)
      when 'video' then video_block(block, media)
      when 'audio' then audio_block(block, media)
      when 'link' then link_block(block, media)
      when 'paywall' then paywall_block(block)
      else
        # A block type nobody wrote a branch for used to vanish whole: not
        # in the post, not in the summary, not visible to `check`. Tumblr
        # has served `poll` blocks since 2023, so a poll post imported as
        # whatever prose surrounded it and the reader had no way to tell a
        # question was ever asked. This is the failure the `paywall` branch
        # was added to fix, and it was fixed one type wide. Counted where
        # every other thing the schema cannot hold is counted: the run's
        # "what the block schema could not hold" line.
        kind = block['type'].to_s.strip
        HtmlBlocks.dropped[kind] += 1 unless kind.empty?
        nil
      end
    end

    def text_block(block)
      out = { 'type' => 'text', 'text' => block['text'] }
      out['subtype'] = block['subtype'] if block['subtype']
      out['formatting'] = block['formatting'] if block['formatting'] && !block['formatting'].empty?
      out
    end

    def image_block(block, media)
      largest = (block['media'] || []).max_by { |m| m['width'].to_i }
      filename = largest && media.from_url(largest['url'])
      # Every sibling adapter drops the block when the picture could not be
      # fetched -- a dead 64.media.tumblr.com address, a 404, a geo-block,
      # all routine in an archive of old posts -- and medium.rb states the
      # contract: download, measure, or lose the one image rather than the
      # post. Kept, the entry carried url: null, which the build renders as
      # <img src=""> (the browser resolves that to the post's own page, so
      # a published page shows a permanently broken picture) while `check`
      # skips an empty url and calls the archive sound. Media#failures
      # counts it, and the summary names the address that would not come.
      return nil unless filename

      {
        'type' => 'image',
        'media' => [{ 'url' => filename, 'width' => largest && largest['width'], 'height' => largest && largest['height'] }],
        'alt_text' => block['alt_text'],
        'caption' => block['caption']
      }.compact
    end

    def video_block(block, media)
      poster = (block['poster'] || []).first
      poster_filename = poster && media.from_url(poster['url'])

      # Self-hosted videos (provider "tumblr") carry a direct downloadable
      # file in `media`; YouTube/Instagram-style embeds don't -- they only
      # ever give an oEmbed iframe/blockquote, which stays external.
      item = block['media']
      media_filename = item && media.from_url(item['url'])

      {
        'type' => 'video',
        'provider' => block['provider'],
        'url' => block['url'],
        'embed_html' => embed_html_for(block),
        'media' => media_filename ? [{ 'url' => media_filename, 'width' => item['width'], 'height' => item['height'] }] : nil,
        'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
      }.compact
    end

    # Self-hosted audio carries a downloadable file. A third-party embed was
    # assumed to hand over nothing but an iframe -- it doesn't: Bandcamp and
    # SoundCloud both put a signed, expiring `audio/mpeg` address in `media`
    # (3 of 4 audio blocks in a real capture had one). Going by whether
    # `media` is there therefore downloaded someone else's track, and named
    # it `NN.jpg`, because those stream URLs have no extension in their path
    # and Media falls back to .jpg for anything unnamed -- which the build
    # then served through <audio src="01.jpg">, a player that plays nothing.
    # So the split is decided by the PROVIDER: a named third party keeps its
    # embed and stays external, as the docs have always said it does.
    #
    # Title and artist become the caption, since that's what a music post
    # shows.
    def audio_block(block, media)
      item = self_hosted?(block) ? block['media'] : nil
      media_filename = item && media.from_url(item['url'])
      caption = [block['title'], block['artist']].compact.reject(&:empty?).join(' — ')

      {
        'type' => 'audio',
        'provider' => block['provider'],
        'url' => block['url'],
        'embed_html' => embed_html_for(block),
        'media' => media_filename ? [{ 'url' => media_filename }] : nil,
        'caption' => (caption unless caption.empty?)
      }.compact
    end

    # An upload straight to Tumblr is provider "tumblr"; older posts come
    # with no provider at all, so absence counts as ours and only a named
    # third party is left alone.
    def self_hosted?(block)
      provider = block['provider'].to_s
      provider.empty? || provider == 'tumblr'
    end

    # Post+ (Tumblr Creator) posts arrive over the API-key path as the free
    # teaser plus this block; the paid part is not in the response at all,
    # because an anonymous reader is a non-member. Dropping the block --
    # which is what an unknown type used to get -- left an archive claiming
    # the teaser WAS the post, with nothing in the summary to say otherwise.
    # There is nothing to fetch, so the honest thing is to keep the dividing
    # line visible. Tumblr's own wording carries it (%s is where its clients
    # substitute the blog name), which is also why this needs no string of
    # our own.
    def paywall_block(block)
      # The spec's own switch for a paywall block that is not to be shown.
      return nil if block['is_visible'] == false

      text = [block['title'], block['text']].compact.map(&:to_s).reject(&:empty?).join(' — ')
      # A `divider` subtype can be a bare coloured rule with no words in it.
      return { 'type' => 'hr' } if text.empty?

      { 'type' => 'text', 'subtype' => 'quote', 'text' => text.gsub('%s') { @account } }
    end

    # Tumblr bakes its own sandbox origin (safe.txmblr.com) into the iframe
    # src. YouTube checks `origin` against the actual embedding page and
    # rejects playback (error 153) if it doesn't match, so strip it -- an
    # embed with no origin param is accepted from any domain.
    def embed_html_for(block)
      html = block['embed_html']
      return nil if html.to_s.strip.empty?

      html.gsub(/(?:&amp;|&)origin=[^&"]*/, '')
    end

    def link_block(block, media)
      poster = (block['poster'] || []).first
      poster_filename = poster && media.from_url(poster['url'])
      {
        'type' => 'link',
        'url' => block['url'],
        'title' => block['title'],
        'description' => block['description'],
        'site_name' => block['site_name'],
        'poster' => poster_filename ? [{ 'url' => poster_filename }] : nil
      }.compact
    end

    def build_slug(item)
      slug = Slug.slugify(item['slug'])
      slug = Slug.slugify(item['summary']) if slug.empty?
      slug.empty? ? "post-#{item['id']}" : slug
    end
  end
end
