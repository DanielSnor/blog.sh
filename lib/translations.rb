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

  # The address this language serves the post at, kept beside its words.
  #
  # 🪤 NOT the post's own `slug`, which is the name of its file and of its
  # media directory -- identity, and identity does not change with the
  # language somebody is reading in. Swapping it would move the file, take
  # the pictures with it and turn one post into two. So it travels as
  # `address_slug`, which only PostAddress reads.
  ADDRESS_KEY = 'slug'

  module_function

  # The post as this language renders it. The post itself when there is
  # nothing for that language, so the caller never has to ask.
  # `chain` is what to try when this language has nothing: the site's
  # `fallback` for it, nearest first. The post itself is the end of every
  # chain -- it is the one text that always exists.
  def for_lang(post, lang, chain: [])
    entry = post.is_a?(Hash) ? post['translations'] : nil
    return post unless entry.is_a?(Hash)

    wanted = ([lang.to_s] + Array(chain).map(&:to_s)).uniq
    one = wanted.filter_map { |code| entry[code] }.find { |value| written?(value) }
    return post unless one.is_a?(Hash)

    text = one.slice(*TEXT_KEYS).reject { |_, value| value.nil? }
    return post if text.empty?

    merged = post.merge(text)
    # A translation with words and no title of its own is an UNTITLED post
    # in that language, not a post wearing the other language's headline:
    # the engine names an untitled post from its own first sentence, and
    # that sentence is now in this language (lib/post_text.rb).
    merged['title'] = nil unless one['title'].to_s.strip.empty? == false
    address = one[ADDRESS_KEY].to_s.strip
    merged['address_slug'] = address unless address.empty?
    merged
  end

  # Which languages this post has a text of its own for -- the site's own
  # language is not among them, because that one is the post itself.
  # What `hreflang` may promise is built from this and nothing else: a
  # list from the config would promise addresses that were never written.
  def languages(post)
    entry = post.is_a?(Hash) ? post['translations'] : nil
    return [] unless entry.is_a?(Hash)

    entry.select { |_, one| written?(one) }.keys
  end

  # What counts as HAVING a language: words. A title with nothing under it
  # is a translation somebody started, and treating it as a language built
  # a page with that headline over the other language's text -- which
  # three separate review passes flagged independently (Daniel, 20. 9.
  # 2026: it counts when it has a body). It stays in the archive and the
  # matrix in `check --languages` shows it as started.
  def written?(one)
    one.is_a?(Hash) && !Array(one['content']).empty?
  end
end
