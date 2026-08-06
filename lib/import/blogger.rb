# frozen_string_literal: true

require_relative 'feed'

module Import
  # Imports a Blogger backup -- the Atom file from Settings → Manage blog
  # → Back up content. Feed already reads Atom; what Blogger adds is a
  # mess of its own making, all handled here:
  #
  # The backup mixes POSTS, COMMENTS, and blog settings in one flat list
  # of entries, told apart only by a kind category -- read naively, every
  # comment anyone ever left would import as a post of yours. Drafts hide
  # in app:control/app:draft. Image URLs carry a size token (s320 and
  # friends), so the files behind them are thumbnails unless the token is
  # rewritten up front. And each image sits inside a link to itself,
  # which would otherwise survive as a stray empty link.
  class Blogger < Feed
    KIND = /#kind\z/

    def label
      title = channel_title
      title.empty? ? 'Blogger backup' : "Blogger (#{title})"
    end

    def platform_tag
      'blogger'
    end

    def map(item, media)
      post = super
      return post unless post.is_a?(Hash)

      post['source']['platform'] = 'blogger'
      post['content'] = restore_videos(post['content'])
      post
    end

    private

    # The kind category names what an entry IS; everything that isn't a
    # post is counted under its own name -- 'comment' deserves to be seen
    # in the summary, not lumped into miscellany.
    def skip_reason(item)
      kind = item.get_elements('category').filter_map do |c|
        c.attribute('term')&.value if c.attribute('scheme')&.value.to_s.match?(KIND)
      end.first.to_s

      return false if kind.end_with?('#post')
      return :comment if kind.end_with?('#comment')

      :not_a_post
    end

    def item_state(item)
      item.elements['app:control/app:draft']&.text.to_s.strip == 'yes' ? 'draft' : 'published'
    end

    # The alternate link's basename is the slug the blog actually
    # published under -- /2019/05/my-post.html -- and keeping it keeps
    # the redirect readable. Drafts have no alternate link and fall back.
    def item_slug(item)
      base = File.basename(URI.parse(item_link(item)).path.to_s, '.html')
      slug = Slug.slugify(base)
      slug.empty? ? super : slug
    rescue URI::InvalidURIError
      super
    end

    # Labels are categories too, but so is the kind marker -- without the
    # scheme filter every post would be tagged with a schema URL.
    def item_tags(item)
      item.get_elements('category').filter_map do |c|
        next if c.attribute('scheme')&.value.to_s.match?(KIND)

        c.attribute('term')&.value&.strip
      end.reject(&:empty?).uniq { |t| t.downcase }
    end

    # Size tokens rewritten BEFORE parsing, so localize_images downloads
    # the full-size file instead of the 320px thumbnail the markup shows.
    # s2000 rather than s0: the token has to stay a valid size, and 2000px
    # is past any Blogger-era original. Then the self-link unwrap: an
    # image wrapped in a link to (a differently-sized copy of) itself is
    # navigation chrome, not a link worth keeping -- but a link to
    # anywhere ELSE is the author's and stays.
    SIZE_TOKENS = [
      [%r{/s[0-9]{2,5}(-[a-z0-9#,*]{1,4})?/}, '/s2000/'],
      [/=s[0-9]{2,5}(-[a-z0-9#,*]{1,4})?/, '=s2000'],
      [%r{/w[0-9]{2,5}-h[0-9]{2,5}(-[a-z0-9#,*]{1,4})?/}, '/w2000-h2000/'],
      [/=w[0-9]{2,5}-h[0-9]{2,5}(-[a-z0-9#,*]{1,4})?/, '=w2000-h2000']
    ].freeze

    SELF_LINKED_IMG = %r{<a[^>]*href="([^"]+)"[^>]*>\s*(<img[^>]*src="([^"]+)"[^>]*/?>)\s*</a>}m

    YOUTUBE_IFRAME = %r{<iframe[^>]*src="[^"]*youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{6,})[^"]*"[^>]*>\s*</iframe>}m

    def body_html(item)
      html = SIZE_TOKENS.reduce(super) { |acc, (re, sub)| acc.gsub(re, sub) }
      html = html.gsub(SELF_LINKED_IMG) do
        href, img, src = Regexp.last_match.captures
        normalize_image_url(href) == normalize_image_url(src) ? img : Regexp.last_match(0)
      end
      # An embedded YouTube player would be dropped by HtmlBlocks (rightly
      # -- it drops all iframes); a sentinel paragraph carries the video id
      # through the parse, and map() turns it into the same url+youtube_id
      # block a hand-written post gets.
      html.gsub(YOUTUBE_IFRAME) { "<p>@@blogger-video:#{Regexp.last_match(1)}@@</p>" }
    end

    def normalize_image_url(url)
      SIZE_TOKENS.reduce(url) { |acc, (re, sub)| acc.gsub(re, sub) }
    end

    def restore_videos(blocks)
      blocks.map do |block|
        id = block['type'] == 'text' && block['text'].to_s[/\A@@blogger-video:([A-Za-z0-9_-]{6,})@@\z/, 1]
        id ? { 'type' => 'video', 'url' => "https://www.youtube.com/watch?v=#{id}", 'youtube_id' => id } : block
      end
    end
  end
end
