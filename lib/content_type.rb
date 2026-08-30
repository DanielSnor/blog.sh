# frozen_string_literal: true

# lib/content_type.rb -- a post's dominant content type (video > audio >
# image > chat > quote > link > text), shared by the build (the /type/
# listings and date-badge icons) and the CLI's `list` output. The two used
# to compute this separately and could disagree on a post with an unknown
# `type` value -- now both normalize the same way: an explicit, recognized
# `type` wins, anything else falls back to scanning the post's blocks.
module ContentType
  # Media outranks form: audio outranks image because a song post usually
  # carries cover art too, and the song is the point; a chat with a photo
  # is a photo post for the same reason.
  PRIORITY = %w[document video audio image chat quote link text].freeze

  # A media post is one where the text is just a caption. Past this many
  # characters the post is an article and its media are illustrations, so
  # video/audio/image no longer claim it. 500 is a Mastodon toot: any
  # imported status with a photo stays a photo post (a tweet is 280),
  # while a review with a poster falls to text.
  CAPTION_LIMIT = 500

  # A file claims the post only caption-deep, exactly like a photo: a
  # short line plus an attachment is a document post ("here, take this"),
  # while an article that happens to attach its data stays an article.
  MEDIA = %w[document video audio image].freeze

  module_function

  def dominant(post)
    explicit = post['type']
    return explicit if PRIORITY.include?(explicit)

    # Array(), like every other reader of this key in the build -- and a
    # nil INSIDE the array too. A post with no `content`, or with a null
    # entry among its blocks, killed the whole build here with a raw
    # NoMethodError naming this file and no post, before a single page
    # was written; `check` read the same archive and called it sound.
    blocks = Array(post['content']).compact
    return 'text' if blocks.empty?

    types = blocks.map { |b| b['type'] == 'file' ? 'document' : b['type'] }
    # A quote is a text subtype, not a block type, so it can't win the scan
    # on its own. Only a post that OPENS with one counts as a quote post --
    # a quote cited mid-text leaves the post a text post.
    first = blocks.first
    types << 'quote' if first && first['type'] == 'text' && first['subtype'] == 'quote'
    chars = blocks.sum { |b| b['type'] == 'text' ? b['text'].to_s.length : 0 }
    types -= MEDIA if chars > CAPTION_LIMIT
    PRIORITY.find { |t| types.include?(t) } || 'text'
  end
end
