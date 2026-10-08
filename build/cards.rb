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

  def render_list_item(post, pinned: false, series: false, lead: false)
    # The pinned copy is rendered separately and NOT cached under the same
    # key: it differs from the post's ordinary appearance by exactly the
    # badge mark, and caching one over the other would leak the mark into
    # the chronological copy (or lose it from the pinned one).
    # The card that opens the front page with its picture (layout.lead_card)
    # is a third copy kept out of the cache, for the same reason.
    return build_list_item(post, pinned: pinned, lead: true) if lead
    return build_list_item(post, pinned: true) if pinned
    # The copy on a series' own listing carries the part's number, and is
    # kept out of the cache for the same reason: the card every other
    # listing shows must stay the card it was.
    return build_list_item(post, series: true) if series

    LIST_ITEM_CACHE[post] ||= build_list_item(post)
  end

  # The lead card's body: the post's first picture, then its opening. The
  # picture is taken by IDENTITY out of whatever follows, so a post that
  # opens with it does not show it twice, and it is not weighed against
  # the budget -- that it would not have fitted is the reason this exists.
  # Nil for a post with no picture worth leading with: its card is then the
  # card it always was.
  def lead_content(post, prefix)
    block, = first_usable_image(post)
    return nil unless block

    teaser = PostText.teaser_blocks(post['content'])
    teaser = nil unless teaser&.any?
    rest = (teaser || post['content'] || []).reject { |b| b.equal?(block) }
    kept, cut = teaser ? [rest, true] : CardTeaser.blocks(rest)
    html = Blocks.render_content([block] + kept, prefix, lifted: link_title_block(post))
    [html, cut || kept.length < rest.length]
  end

  # What the stylesheet lets a medium taller than it is wide take on a card
  # (22rem, at the 16px a browser starts from), so the budget is charged
  # what the reader will see rather than what the file would have taken.
  MEDIA_TALL_HEIGHT = 352

  # The medium a post of its kind is about: the picture of a picture post,
  # the video of a video post. Nil for every other kind -- an article with a
  # photograph in it is an article -- and for a post that says it is one of
  # the two and carries no such block.
  def medium_block(post)
    case dominant_content_type(post).to_s
    when 'image' then first_usable_image(post)&.first
    when 'video' then (post['content'] || []).find { |b| b.is_a?(Hash) && b['type'] == 'video' }
    end
  end

  # Taller than wide, or square: the shapes that at a card's full width
  # take a screen to themselves. Unknown dimensions are not tall -- there
  # is nothing to cap a size nobody wrote down against.
  def tall_medium?(block)
    media = (block['media'] || []).first || {}
    width = media['width'].to_f
    width.positive? && media['height'].to_f >= width
  end

  # A picture post's card with the picture on it, a video post's with the
  # video. The cut is by height and keeps the FIRST block whatever it
  # weighs, so a photograph under one line of words was left off the card
  # of a post that is that photograph: on one real archive the first page
  # of the pictures showed three pictures in thirteen cards.
  #
  # So the medium goes first and the same cut runs over what follows. A
  # post that opened with its medium keeps exactly the blocks it kept; one
  # that opened with words keeps its medium and as many of the words as
  # still fit. A teaser the author wrote stands under it whole, as it does
  # everywhere.
  def media_content(post, prefix, block)
    teaser = PostText.teaser_blocks(post['content'])
    teaser = nil unless teaser&.any?
    rest = (teaser || post['content'] || []).reject { |b| b.equal?(block) }
    kept, cut = if teaser
                  [[block] + rest, true]
                else
                  CardTeaser.blocks([block] + rest,
                                    first_height: tall_medium?(block) ? MEDIA_TALL_HEIGHT + CardTeaser::GAP : nil)
                end
    [Blocks.render_content(kept, prefix, lifted: link_title_block(post)), cut]
  end

  def build_list_item(post, pinned: false, series: false, lead: false)
    prefix = post_href(post)
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
    led = lead ? lead_content(post, prefix) : nil
    content, cut = led if led
    # The card that leads the front page was asked for by the site and is
    # left exactly as it was; every other card of a picture or video post
    # carries its medium.
    medium = led ? nil : medium_block(post)
    content, cut = media_content(post, prefix, medium) if medium
    kind = if led then ' post-list-item--lead'
           elsif medium then " post-list-item--media#{tall_medium?(medium) ? ' post-list-item--media-tall' : ''}"
           else ''
           end
    content = content.gsub(%r{<(h[1-6])([^>]*) id="[^"]*"}) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2)}" }
    # The link is there exactly when a block did not fit -- or when the
    # author wrote a teaser, which says the same thing about the post. It
    # used to follow a separate rule (400 characters, or more than one
    # picture), so it could sit under a card that showed everything.
    read_more = teaser || cut ? %(<a class="read-more" href="#{prefix}">#{h(t('post.read_more'))}</a>) : ''
    title = post_heading_html(post, 'h2', prefix)
    stats = post_meta_html(post, reading_labels(post))
    # On the stats' own line, so a card without one is the bytes it was.
    series_note = series ? series_card_note(post) : ''
    <<~HTML
      <div class="card post-list-item#{kind}">
        <div class="post-header">
          #{date_badge(post, link: prefix, pinned: pinned)}
          <div class="post-body">
            #{title}
            #{stats}#{series_note}
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
