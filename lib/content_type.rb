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
  PRIORITY = %w[video audio image chat quote link text].freeze

  module_function

  def dominant(post)
    explicit = post['type']
    return explicit if PRIORITY.include?(explicit)

    types = post['content'].map { |b| b['type'] }
    # A quote is a text subtype, not a block type, so it can't win the scan
    # on its own. Only a post that OPENS with one counts as a quote post --
    # a quote cited mid-text leaves the post a text post.
    first = post['content'].first
    types << 'quote' if first && first['type'] == 'text' && first['subtype'] == 'quote'
    PRIORITY.find { |t| types.include?(t) } || 'text'
  end
end
