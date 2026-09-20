# frozen_string_literal: true

# lib/translations.rb -- which text of a post this run is rendering.
#
# A post keeps ONE set of metadata and as many texts as it has languages.
# The metadata stay flat on the post, where they have always been: the
# date, the tags, the series, the state and the source belong to the piece
# of writing, not to a language, and a translation that could disagree
# about any of them is how a post ends up published in one language and a
# draft in another.
#
# The text of the post's own language stays flat too, so a site that never
# translates anything is byte for byte the archive it already has and
# needs no migration -- a post with no `translations` key is a post in the
# site's own language, which is exactly what every post is today.
#
# Anything else goes under `translations`, keyed by language:
#
#   "translations": { "de": { "title": "…", "content": [ … ] } }
#
# A language with no entry here is not an error and not a hole: the post
# is rendered as it stands. On a site published in two languages a piece
# that exists in one is shown as it is rather than hidden (Daniel,
# 18. 9. 2026) -- a reader who does not read it can tell at a glance, and
# a reader who does would have lost it.
#
# 🪤 A translation may carry TEXT and nothing else. The list below is the
# whole of it, and it is a list rather than "everything the entry has" on
# purpose: `merge` with an entry somebody hand-wrote would otherwise let a
# translation quietly carry its own `state`, `date` or `source`, which are
# the three the paragraph above says it must not.
module Translations
  TEXT_KEYS = %w[title content excerpt].freeze

  module_function

  # The post as this language renders it. The post itself when there is
  # nothing for that language, so the caller never has to ask.
  def for_lang(post, lang)
    entry = post.is_a?(Hash) ? post['translations'] : nil
    return post unless entry.is_a?(Hash)

    one = entry[lang.to_s]
    return post unless one.is_a?(Hash)

    text = one.slice(*TEXT_KEYS).reject { |_, value| value.nil? }
    return post if text.empty?

    post.merge(text)
  end

  # Which languages this post has a text of its own for -- the site's own
  # language is not among them, because that one is the post itself.
  # What `hreflang` may promise is built from this and nothing else: a
  # list from the config would promise addresses that were never written.
  def languages(post)
    entry = post.is_a?(Hash) ? post['translations'] : nil
    return [] unless entry.is_a?(Hash)

    entry.select { |_, one| one.is_a?(Hash) && !one.slice(*TEXT_KEYS).compact.empty? }.keys
  end
end
