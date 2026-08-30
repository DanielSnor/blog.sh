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
  ELLIPSIS = '…'
  # A sentence end, but only one followed by a space or the end of the text.
  # The four-word minimum below is what keeps "Apple Inc." from becoming the
  # name of a post about a share price -- and with it "tj.", "atd.", "č.".
  #
  # Two dots are not one of them. The class used to be a bare [.!?], so the
  # SECOND dot of ".." closed a sentence -- and ".." is a pause somebody
  # typed, not punctuation: it ends nothing, in any language. A golden diff
  # over a real archive put a number on it: 152 names ended on a dangling
  # "..", and 150 of those were a cut through the middle of a thought. One
  # of them turned "A hupky do peří .. d8-D" into the name "A hupky do peří
  # .." and pushed the author's own emoticon into the perex.
  #
  # Three dots ARE an ellipsis and do end a sentence, so they stay. This is
  # a rule about typography rather than about Czech, which is what the rest
  # of this file demands of itself: nothing here may be a language guess.
  SENTENCE_RE = /\A(.{3,}?(?:(?<!\.)\.(?!\.)|\.\.\.|[!?]))(?:[[:space:]]|\z)/

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
  # The first link block carrying a title, on a post that has none of its
  # own. The build lends that title to the post as its <h1>, so it is the
  # post's name -- and the announcement, which had its own idea (none at
  # all), went out as a bare address while the page it pointed at had a
  # real headline and a real description. Kept here rather than in the
  # build because both need it and neither should own it.
  def link_title_block(post)
    return nil unless post.is_a?(Hash)
    return nil if post['title']

    Array(post['content']).find do |b|
      b.is_a?(Hash) && b['type'] == 'link' && !b['title'].to_s.empty?
    end
  end

  # The text of a run of blocks, as one line.
  def joined_text(blocks)
    Array(blocks).select { |b| b.is_a?(Hash) && b['type'] == 'text' }
                 .map { |b| b['text'] }.join(' ').gsub(/[[:space:]]+/, ' ').strip
  end

  def name_and_rest(post)
    return nil unless post.is_a?(Hash)
    return nil if post['title']

    teaser = teaser_blocks(post['content'])
    # An empty teaser is an explicit "announce this with the title and the
    # link alone", and it stays honoured -- but a NAME is not an
    # announcement. The marker as the first block gives [], which is truthy
    # in Ruby, so the name was being drawn from no blocks at all: the cut
    # returned nil and the title fell through to the slug, which is exactly
    # the defect this design removed -- a date in the post's own heading and
    # "burtiky-opekame-hipstamatic-oggl-jane" in the browser tab, the link
    # card and the feed. So the name comes from the whole text either way
    # and only the REST is silenced. build_list_item and post_description
    # already refuse an empty teaser for standing output; this now agrees
    # with them on purpose instead of honouring it by accident.
    quiet = !teaser.nil? && joined_text(teaser).empty?
    text = joined_text(quiet || teaser.nil? ? post['content'] : teaser)
    return nil if text.empty?

    name, rest = cut_name(text)
    name, dropped = cap_bytes(name)
    return [name, ''] if quiet

    [name, open_rest(dropped, rest)]
  end

  # The words the cap took have to open the rest rather than vanish: there
  # is one cut in this text, not two. cut_name states that invariant and is
  # checked on it -- but only where no capping happens, so the cap was
  # quietly breaking the rule it was supposed to share. Whenever it bit (an
  # opening sentence carrying a long URL, or eight long Czech words) the
  # words between the name and the rest disappeared from the description,
  # the search row and the announcement, while staying on the page -- so
  # nothing looked broken anywhere.
  def open_rest(dropped, rest)
    return rest if dropped.empty?

    tail = rest.to_s.sub(/\A…\s*/, '')
    "…#{[dropped, tail].reject { |part| part.to_s.empty? }.join(' ')}"
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
  #
  # Returns the capped name AND what it took, because the caller owes those
  # words to the rest.
  def cap_bytes(name)
    return [name, ''] if name.bytesize <= NAME_MAX_BYTES

    # The ellipsis counts against the cap: a name popped to exactly the
    # limit and then given a three-byte tail is over the limit.
    limit = NAME_MAX_BYTES - ELLIPSIS.bytesize
    words = name.delete_suffix(ELLIPSIS).split(' ')
    dropped = []
    dropped.unshift(words.pop) while words.length > 1 && words.join(' ').bytesize > limit
    head = words.join(' ')
    if head.bytesize > limit
      # Text with no spaces is one "word", so popping words cannot touch it
      # -- Japanese, Chinese and Thai write that way, and so does a single
      # very long URL. The cap was never enforced and the ellipsis was
      # appended to text that had not been cut, which made the whole post
      # its own title: in the browser tab, the feed, the link card, and in
      # a toot the instance then refused for length, so the post published
      # with no announcement and no comment thread.
      kept = cut_to_bytes(head, limit)
      dropped.unshift(head[kept.length..].to_s) unless kept.length == head.length
      head = kept
    end
    ["#{head}#{ELLIPSIS}", dropped.join(' ').strip]
  end

  # Whole characters, never bytes, for the reason above.
  def cut_to_bytes(text, limit)
    out = +''
    text.each_char do |ch|
      break if out.bytesize + ch.bytesize > limit

      out << ch
    end
    out
  end

  # Deliberately not every string in the post: a URL, a slug or an embed
  # provider is not something anyone searches for in prose, and dropping
  # them keeps the index from matching a word that appears nowhere on the
  # page. Nested list items are not walked, matching what the site's index
  # has always contained.
  # `separator` is for a SNIPPET, and only for one. Joined with a space --
  # which is what everything else here wants -- the end of one paragraph
  # and the start of the next read as a single broken sentence: "…v lese
  # vlhko a listy Ranní mlha zrovna nezvala…". A search result is the one
  # place a reader meets that text with no paragraphs to tell them apart,
  # so it asks for a visible mark instead. Everything else keeps the space:
  # the reading time counts these words, and `folded` is what a query is
  # matched against -- a separator in it would stop "listy Ranní" finding
  # the post it is in.
  def plain(post, separator: ' ')
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
    # Blank parts dropped, not joined: an image with no alt text between two
    # paragraphs put a mark on the page with nothing on one side of it.
    parts.compact.reject { |part| part.to_s.strip.empty? }.join(separator)
  end

  # Everything a query is matched against -- title, text and tags -- folded
  # the way search.js folds what a visitor types. Tags are in there on
  # purpose: "the post about the iPhone" is as often a tag as a word.
  #
  # `text` is optional so a caller that already has the plain text (the
  # build, which also cuts an excerpt from it) doesn't walk the blocks
  # twice.
  def searchable(post, text = nil)
    Slug.fold([post['title'], text || plain(post), aside(post),
               (post['tags'] || []).join(' ')].compact.join(' '))
  end

  # Words the reader can see on the page and could not find from the search
  # box: a chat block is a conversation, a code block is often the only
  # place a command name appears, and a caption or a label is the only text
  # a video, a recording or an attachment has.
  #
  # Kept apart from `plain` rather than folded into it, because `plain` is
  # also what the description on a card is cut from, what the reading time
  # is measured on and what the word count in stats adds up. Widening it
  # would have put a shell command in a page's <meta description>. This is
  # about being findable, and only the two things that search -- the index
  # and the terminal's browser -- read it.
  def aside(post)
    (post['content'] || []).flat_map do |block|
      next [] unless block.is_a?(Hash)

      case block['type']
      when 'chat' then (block['lines'] || []).flat_map { |line| [line['name'], line['text']] }
      when 'code' then [block['text']]
      when 'video', 'audio' then [block['caption']]
      when 'file' then [block['label']]
      when 'list' then nested_items(block['items'])
      else []
      end
    end.compact.join(' ')
  end

  # The items UNDER an item. The page draws them as a list of their own, so
  # a reader sees those words and could not find them: `plain` walks the
  # top level only, and that is where the description, the reading time and
  # the word count are cut from -- widening it would change all three to
  # fix a search.
  #
  # Three shapes, because three are on disk. The renderer's own
  # `nested_list` accepts an Array of items, a Hash carrying its own
  # `type`, and a Hash of `{style, items}` -- which is what the archive
  # this was measured on actually holds. Anything findable has to follow
  # whatever the page drew, so the shapes are read here the same way.
  def nested_items(items)
    Array(items).flat_map { |item| item.is_a?(Hash) ? under(item['children']) : [] }
  end

  # Everything below one item: the children's own words and theirs in turn.
  def under(children)
    list = case children
           when Array then children
           when Hash then children['items']
           end
    Array(list).flat_map do |item|
      next [] unless item.is_a?(Hash)

      [item['text'], *under(item['children'])]
    end
  end
end
