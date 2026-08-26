# frozen_string_literal: true

require_relative 'slug'

# lib/search_query.rb -- the search box's query language, in Ruby.
#
# Mirrors parseQueryTokens/searchRank in assets/js/search.js, and the two
# MUST change together: the site and `./blog.sh browse` search the same
# archive, and a query that means one thing in the browser and another in
# the terminal is worse than no search in the terminal at all.
#
# The language, in one line: words are ANDed, "text in quotes" is one
# phrase, a leading - excludes. Typographic quotes count as quotes,
# because a Czech or German keyboard produces „these" without being asked
# and a query that silently searched for the quote mark would be a
# mystery, not a feature.
#
# Folding is Slug.fold on both sides, so diacritics never decide a match:
# zpravobot finds Zprávobot.
module SearchQuery
  # -?  optional exclusion, then either a quoted phrase or a bare word.
  # [^[:space:]] rather than \S: Ruby's \S is ASCII-only, so a query typed
  # with a non-breaking space (every Czech keyboard puts one after a
  # one-letter preposition) stayed a single token here and split into two
  # in the browser -- the terminal and the web page answered the same
  # query differently. [[:space:]] is Unicode-aware and matches JS.
  TOKEN_RE = /(-?)(?:["„“”]([^"„“”]+)["„“”]|([^[:space:]]+))/.freeze

  Token = Struct.new(:text, :negated, keyword_init: true)

  module_function

  def parse(raw)
    raw.to_s.scan(TOKEN_RE).filter_map do |negated, phrase, word|
      text = Slug.fold(phrase || word)
      Token.new(text: text, negated: negated == '-') unless text.empty?
    end
  end

  # An empty query matches nothing rather than everything -- the caller
  # decides what to show when nobody has typed anything, and on the site
  # that decision is the invitation to type. A query of nothing but
  # exclusions matches nothing for the same reason: "-twitter" is not a
  # search, and answering it with the entire archive would bury the one
  # thing the visitor did say.
  def match?(folded, tokens)
    positive = tokens.reject(&:negated)
    return false if positive.empty?

    positive.all? { |t| folded.include?(t.text) } &&
      tokens.select(&:negated).none? { |t| folded.include?(t.text) }
  end

  def filter(entries, raw, &folded)
    tokens = parse(raw)
    return [] if tokens.empty?

    entries.select { |e| match?(folded.call(e), tokens) }
  end
end
