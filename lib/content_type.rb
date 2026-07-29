# frozen_string_literal: true

# lib/content_type.rb -- a post's dominant content type (video > image >
# link > text), shared by the build (the /type/ listings and date-badge
# icons) and the CLI's `list` output. The two used to compute this
# separately and could disagree on a post with an unknown `type` value --
# now both normalize the same way: an explicit, recognized `type` wins,
# anything else falls back to scanning the post's blocks.
module ContentType
  PRIORITY = %w[video image link text].freeze

  module_function

  def dominant(post)
    explicit = post['type']
    return explicit if PRIORITY.include?(explicit)

    types = post['content'].map { |b| b['type'] }
    PRIORITY.find { |t| types.include?(t) } || 'text'
  end
end
