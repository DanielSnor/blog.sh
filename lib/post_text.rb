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

  # The blocks above the teaser marker, or nil when the post carries none.
  #
  # nil rather than an empty array, because the two mean different things: a
  # post with no marker falls back to a machine-cut opening, while a marker
  # on the very first line is an author saying "announce this with the title
  # and the link alone" -- an explicit act, and one worth honouring rather
  # than second-guessing back into a cut.
  #
  # Lives here rather than in the build or in Publishing because both of
  # them need it and neither should own it: the same blocks feed the toot,
  # the link card and the listing, and those three must not disagree about
  # where a post's invitation ends.
  def teaser_blocks(blocks)
    list = Array(blocks)
    index = list.index { |b| b.is_a?(Hash) && b['type'] == 'teaser_end' }
    index && list[0...index]
  end

  # How many words a name gets when no sentence fits, and the window in
  # which a whole first sentence is preferred to that count. Eight is not a
  # new number: it is what post slugs have always been cut to, so a name and
  # an address come out of the same place in the same text.
  NAME_WORDS = 8
  NAME_SENTENCE_MIN = 4
  NAME_SENTENCE_MAX = 12
  # The cap the engine already chose for tag slugs, reused rather than
  # invented. On one real archive of 2754 untitled posts the longest name
  # this produces is 96 bytes and the median is 45, so this is a guard
  # against eight very long words, not against ordinary writing.
  NAME_MAX_BYTES = 200
  # A sentence end, but only one followed by a space or the end of the text.
  # The four-word minimum below is what keeps "Apple Inc." from becoming the
  # name of a post about a share price -- and with it "tj.", "atd.", "č.".
  SENTENCE_RE = /\A(.{3,}?[.!?])(?:[[:space:]]|\z)/

  # What an untitled post gets called, and where its text picks up
  # afterwards -- returned together, never separately.
  #
  # Together, because the two are one cut in one text and computing them
  # apart is how a post ends up introducing itself twice: the name is drawn
  # from the opening, so a preview that also starts at the opening repeats
  # it word for word. Whoever needs the name needs to know where the rest
  # begins, and this is the only place that decides.
  #
  # Returns nil for a post that names itself -- there is no cut to make.
  def name_and_rest(post)
    return nil if post['title']
    return nil unless post.is_a?(Hash)

    blocks = teaser_blocks(post['content']) || post['content']
    text = Array(blocks).select { |b| b.is_a?(Hash) && b['type'] == 'text' }
                        .map { |b| b['text'] }.join(' ').gsub(/[[:space:]]+/, ' ').strip
    return nil if text.empty?

    name, rest = cut_name(text)
    [cap_bytes(name), rest]
  end

  # The cut itself. A whole first sentence wins when one fits the window --
  # a name that ends where the writer ended reads like a name, while eight
  # words usually stop just before the point, because a Czech sentence puts
  # its verb and object at the end. Failing that, the word count, with a
  # trailing preposition or conjunction dropped: "...vyplynulo, že" reads as
  # a mistake where "...vyplynulo," reads as an interruption.
  #
  # The dropped word opens the rest rather than disappearing: there is one
  # cut here, not two, and text on either side of it has to add back up.
  def cut_name(text)
    words = text.split(' ')
    sentence = text[SENTENCE_RE, 1]
    if sentence && (NAME_SENTENCE_MIN..NAME_SENTENCE_MAX).cover?(sentence.split(' ').length)
      return [sentence, text[sentence.length..].to_s.strip]
    end
    return [text, ''] if words.length <= NAME_WORDS

    head = words.first(NAME_WORDS)
    head = head[0..-2] if head.last.gsub(/[[:punct:]]/, '').length < 3 && head.length > 1
    ["#{head.join(' ')}…", "…#{words[head.length..].join(' ')}"]
  end

  # Trimmed to whole words, never to a byte: a cut at the 200th byte splits
  # a multi-byte character down the middle, and Czech diacritics, emoji and
  # the emoticons this archive is full of are all multi-byte.
  def cap_bytes(name)
    return name if name.bytesize <= NAME_MAX_BYTES

    words = name.split(' ')
    words.pop while words.length > 1 && words.join(' ').bytesize > NAME_MAX_BYTES
    "#{words.join(' ')}…"
  end

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
