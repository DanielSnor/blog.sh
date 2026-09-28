# frozen_string_literal: true

# lib/link_card.rb -- the card at the top of a link post.
#
# A link post is a post whose FIRST content block is the link it is about:
#
#   {"type": "link", "url": "https://…", "title": "…", "description": "…"}
#
# It is written into the content rather than into a field because that is
# where the build renders it from, and it is always first -- the post is
# about that page, and the words under it are what the author has to say.
#
# Which makes it the one block that is not prose: the markdown editors
# cannot show it (a writer that turned it into text would turn "the post
# is about this page" into "here is a link"), so every editor takes it out
# of the body first and puts it back afterwards. This is where that is
# written down, because it was worked out twice and the second copy --
# in the translation editor -- got it wrong: it handed the whole content
# to the writer, which drops the card, and the translated page of a link
# post came out as the one thing a link post is not.
module LinkCard
  module_function

  # [card, the rest] -- card is nil for an ordinary post, and then the
  # rest is the content unchanged.
  def split(content)
    blocks = Array(content)
    first = blocks.first
    return [nil, blocks] unless first.is_a?(Hash) && first['type'] == 'link'

    [first, blocks.drop(1)]
  end
end
