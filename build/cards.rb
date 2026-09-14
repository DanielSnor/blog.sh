# frozen_string_literal: true

# build/cards.rb -- one post as it appears in a list.
#
# A card is not a small page: it is a decision about how much of a post
# a reader is shown before they choose to open it, and that decision is
# measured in HEIGHT rather than in characters, because a picture costs
# no characters and several hundred pixels. CardTeaser makes the cut;
# this turns what survives it into markup.
#
# Two functions, one of them called from the listing writer and the
# other from it. Everything about WHICH posts are on which page, and in
# what order, belongs to the listings and stays there.
module Cards
  module_function

  def render_list_item(post, pinned: false)
    # The pinned copy is rendered separately and NOT cached under the same
    # key: it differs from the post's ordinary appearance by exactly the
    # badge mark, and caching one over the other would leak the mark into
    # the chronological copy (or lose it from the pinned one).
    return build_list_item(post, pinned: true) if pinned

    LIST_ITEM_CACHE[post] ||= build_list_item(post)
  end

  def build_list_item(post, pinned: false)
    prefix = post_path(post)
    # A post that wrote its own teaser shows exactly that here, and nothing
    # below it: the listing is where the site invites, and an author who wrote
    # the invitation should not have it padded with the first 500px of the
    # article. The CSS clip is dropped with it -- there is nothing left to
    # clip, and a fade over a finished sentence reads as damage. "Read more"
    # stays, because the post does continue.
    #
    # An empty teaser is honoured in the toot but not here: a card with a
    # heading and no words looks like a build that went wrong, and nobody
    # asking for a quiet announcement is asking for that.
    teaser = PostText.teaser_blocks(post['content'])
    teaser = nil unless teaser&.any?
    # `lifted:` on this branch too. A post's own page passes it so the link
    # block renders WITHOUT the title the heading borrowed from it; the
    # teaser branch did not, so a card printed the borrowed headline twice
    # -- once as its <h2> and again in the body under it -- while the post's
    # own page printed it once.
    # Without a teaser of its own the card is cut HERE rather than by the
    # stylesheet: blocks until the budget, never through one, and the first
    # one always. See lib/card_teaser.rb for what that costs and why the
    # budget is measured in height rather than in characters.
    #
    # A post that fits whole reuses the memoized render, so nothing about it
    # changes -- 77% of this archive is in that case.
    cut = false
    content = if teaser
                Blocks.render_content(teaser, prefix, lifted: link_title_block(post))
              else
                kept, cut = CardTeaser.blocks(post['content'])
                cut ? Blocks.render_content(kept, prefix, lifted: link_title_block(post)) : post_content_html(post)
              end
    # Heading anchors belong to the post's own page. A listing stacks ten
    # posts' bodies into ONE document, so two posts that both have a
    # "Co dal?" section put id="co-dal" on the page twice -- 105 pages of a
    # real archive carried duplicate ids, which makes the document invalid
    # and sends any same-page anchor to whichever came first. heading_id
    # de-duplicates within a post; nothing could de-duplicate across them,
    # because each post's HTML is rendered (and cached) on its own.
    content = content.gsub(%r{<(h[1-6])([^>]*) id="[^"]*"}) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2)}" }
    # The link is there exactly when a block did not fit -- or when the
    # author wrote a teaser, which says the same thing about the post. It
    # used to follow a separate rule (400 characters, or more than one
    # picture), so it could sit under a card that showed everything.
    read_more = teaser || cut ? %(<a class="read-more" href="#{prefix}">#{h(t('post.read_more'))}</a>) : ''
    title = post_heading_html(post, 'h2', prefix)
    stats = post_meta_html(post, reading_labels(post))
    <<~HTML
      <div class="card post-list-item">
        <div class="post-header">
          #{date_badge(post, link: prefix, pinned: pinned)}
          <div class="post-body">
            #{title}
            #{stats}
            <div class="content">
              #{content}
            </div>
            #{read_more}
            #{tags_html(post)}
          </div>
        </div>
      </div>
    HTML
  end
end
