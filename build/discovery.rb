# frozen_string_literal: true

# build/discovery.rb -- what a post says about itself to something that
# is not a reader.
#
# A search engine, a chat app unfurling a link, a Mastodon card: none of
# them read the page, they read the head. Three functions decide what
# they get -- which picture represents the post, what one sentence
# describes it, and the JSON-LD that names its author and its dates.
#
# Kept together because they answer one question between them and are
# asked in one place (render_post_html), and kept away from the page
# renderers because none of what they produce is visible to anybody
# looking at the site.
#
# The `@context` and `@type` in here are JSON-LD keys, not instance
# variables -- schema.org spells them that way and the strings are
# quoted. Nothing in this file holds state.
module Discovery
  module_function

  # Every post is automatically tooted to Mastodon, where the link shows a
  # preview -- without og:image that would be bare text. Uses the post's first
  # non-degenerate image; text posts fall back to the site banner.
  def post_og_image(post)
    block = post['content'].find { |b| b['type'] == 'image' && !Blocks.degenerate_image?(b) }
    media = block && (block['media'] || []).first
    return DEFAULT_OG_IMAGE unless media && media['url']

    # Basename, the same as the page's own <img> uses: this address goes into
    # og:image and into the JSON-LD, and a name carrying "../" pointed both
    # of them outside the post -- at whatever happens to sit there.
    # Percent-encoded, like the page's own <img>. 83baf51 escaped the URL
    # in the markup and left these two behind, so the picture on the page
    # pointed at foto%20%231.jpg while og:image pointed at "foto #1.jpg" --
    # where a scraper reads everything from the # as a fragment, requests
    # "foto " and gets a 404. The link card on Mastodon and Bluesky and the
    # search engine's thumbnail were then blank for exactly the pictures
    # whose names needed the encoding most.
    "#{SITE_BASE_URL}#{post_path(post)}#{media_name_encoded(media['url'])}"
  end

  def post_description(post)
    # A teaser the author wrote is what the post says about itself, so it wins
    # over the cut here too. The empty teaser is the one place this parts ways
    # with the toot: there, "marker on the first line" means "announce with the
    # title and link alone" and an empty perex honours it. A description is not
    # a message but standing metadata -- it is what a search engine quotes
    # months later -- so an empty one would cost the post something without
    # anybody having asked for that, and the cut stands in.
    # A link card shows the title above the description, so when the title was
    # taken from the post's own opening the description has to carry on from
    # there. Otherwise the card reads the same sentence twice -- which did not
    # happen while the title was a slug, and would have arrived with this
    # release as a new defect rather than a fix.
    # ...but only while there IS something after the name. A post short enough
    # to be named in full leaves nothing behind it, and taking that emptiness
    # at face value cost 286 posts on one real archive their own description
    # and gave them the site's instead -- a card that stopped saying what the
    # post is and started saying what the site is. Repeating the text under
    # the title is the lesser of the two: it still describes this post.
    name, rest = PostText.name_and_rest(post)
    text = if name && !rest.to_s.strip.empty? && name_stands_as_title?(post)
             rest
           else
             teaser = PostText.teaser_blocks(post['content'])
             raw = teaser&.any? ? PostText.plain({ 'content' => teaser }) : plain_text_for_search(post)
             without_borrowed_title(raw, post)
           end
    text = post['title'].to_s if text.to_s.strip.empty?
    text = SITE_DESCRIPTION if text.strip.empty?
    truncate_excerpt(text, META_DESCRIPTION_LENGTH)
  end

  # What a crawler is told about a post beyond the OG basics: the article's
  # time and tags as og meta, and the same facts once more as schema.org
  # JSON-LD, which is what rich results actually read. Only for published
  # posts -- a draft's date is bookkeeping and the page is noindex anyway.
  #
  # The JSON-LD block is data, not script: CSP's script-src governs
  # execution, and a text/ld+json block never executes, so the strict
  # policy above needs no widening. "</" is escaped so post text can never
  # close the script element from inside the JSON.
  def post_structured_head(post)
    published = post_display_time(post).iso8601
    tags = post['tags'] || []
    lines = [%(<meta property="article:published_time" content="#{h(published)}">)]
    lines += tags.map { |tag| %(<meta property="article:tag" content="#{h(tag)}">) }

    data = {
      '@context' => 'https://schema.org',
      '@type' => 'BlogPosting',
      'headline' => post_title_for(post),
      'datePublished' => published,
      'url' => "#{SITE_BASE_URL}#{post_path(post)}",
      'mainEntityOfPage' => "#{SITE_BASE_URL}#{post_path(post)}",
      'author' => { '@type' => 'Person', 'name' => SITE_AUTHOR },
      'image' => post_og_image(post),
      'description' => post_description(post)
    }
    data['keywords'] = tags.join(', ') unless tags.empty?
    # Both sequences that can end a script block from inside a JSON string:
    # "</" closes it, and "<!--" opens an HTML comment whose scope runs to the
    # next "-->" -- so a post whose text held an unterminated comment followed
    # by another "<script" swallowed the rest of the page and rendered blank.
    # Escaping the "<" is invisible once the JSON is parsed and stops both.
    json_ld = JSON.generate(data).gsub('</', '<\/').gsub('<!--', '<\u0021--')
    lines << %(<script type="application/ld+json">#{json_ld}</script>)
    lines.map { |line| "\n  #{line}" }.join
  end
end
