# frozen_string_literal: true

require_relative 'slug'

# lib/post_text.rb -- what a post says, as plain text.
#
# Two places need that answer and must agree on it: the build, which
# writes the search index and the meta description from it, and the
# archive browser in the CLI, which searches the same words offline with
# no index to consult. It lived inside build_blog.rb while the build was
# its only caller; moving it here is the same move markdown_parser.rb and
# markdown_writer.rb made before it.
#
# Agreement is the whole point. A query typed into the site's search box
# and the same query typed into `./blog.sh browse` have to find the same
# posts, and they only can if both sides fold the same text.
module PostText
  module_function

  # Deliberately not every string in the post: a URL, a slug or an embed
  # provider is not something anyone searches for in prose, and dropping
  # them keeps the index from matching a word that appears nowhere on the
  # page. Nested list items are not walked, matching what the site's index
  # has always contained.
  def plain(post)
    parts = (post['content'] || []).flat_map do |block|
      case block['type']
      when 'text' then [block['text']]
      when 'list' then (block['items'] || []).map { |it| it['text'] }
      when 'table' then ((block['header'] || []) + (block['rows'] || []).flatten).map { |c| c['text'] }
      when 'image' then [block['alt_text'], block['caption']]
      when 'link' then [block['title'], block['description']]
      else []
      end
    end
    parts.compact.join(' ')
  end

  # Everything a query is matched against -- title, text and tags -- folded
  # the way search.js folds what a visitor types. Tags are in there on
  # purpose: "the post about the iPhone" is as often a tag as a word.
  #
  # `text` is optional so a caller that already has the plain text (the
  # build, which also cuts an excerpt from it) doesn't walk the blocks
  # twice.
  def searchable(post, text = nil)
    Slug.fold([post['title'], text || plain(post), (post['tags'] || []).join(' ')].compact.join(' '))
  end
end
