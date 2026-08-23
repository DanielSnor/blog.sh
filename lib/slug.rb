# frozen_string_literal: true

# lib/slug.rb -- the one shared implementation of diacritic folding and
# slugification. Used for post slugs (manage_post.rb and both migration
# scripts), tag and heading slugs, and the search index's folded text
# (build_blog.rb). It matters that all of these stay identical: post and
# tag slugs become URLs, and the index's folding must match what search.js
# does to the query on the client -- a drifted copy would quietly break
# links or search. Until this file existed, the same logic lived as four
# separate copies.
module Slug
  module_function

  # Letters NFKD cannot decompose, because they are letters of their own
  # rather than base + combining mark: German ß, the Latin ligatures and
  # the stroked/crossed letters of Polish, the Nordic languages, Icelandic,
  # Croatian, Maltese and Sami. Without this table they were dropped as
  # "non a-z0-9", shredding the word around them -- "Größere" became
  # "gro-ere" and "Żółć" became "zo-c". Only lowercase keys: fold below
  # downcases first, and every uppercase form ("ẞ", "Ł", "Æ"...) downcases
  # onto one of these.
  #
  # Deliberately NOT here: language-specific conventions like the German
  # ü -> ue, which would be wrong for every other language using the same
  # letter (French, Spanish, Turkish...). NFKD's generic ü -> u stays.
  TRANSLITERATION = {
    'ß' => 'ss', 'æ' => 'ae', 'œ' => 'oe', 'ø' => 'o', 'đ' => 'd',
    'ð' => 'd', 'þ' => 'th', 'ł' => 'l', 'ħ' => 'h', 'ŧ' => 't',
    'ŋ' => 'n', 'ı' => 'i',
    # Greek writes its sigma differently at the end of a word, and a
    # reader searching for one form must find the other: without this the
    # index and the query folded the same word two ways.
    'ς' => 'σ'
  }.freeze
  TRANSLITERATION_RE = /[#{TRANSLITERATION.keys.join}]/

  # NFKD + strip combining marks transliterates any diacritic generically
  # (e.g. "želnavský" -> "zelnavsky", not just Czech), then the table above
  # catches what NFKD can't, then lowercase and collapsed whitespace.
  # Without the NFKD step, accented characters would just get dropped as
  # "non a-z0-9" by slugify below, fragmenting the slug instead of
  # romanizing it. Mirrored client-side by fold() in search.js -- the two
  # MUST change together, or the folded search index stops matching what
  # the browser folds the query into.
  def fold(s)
    s.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase
     .gsub(TRANSLITERATION_RE, TRANSLITERATION).gsub(/\s+/, ' ').strip
  end

  # fold + everything non-alphanumeric collapsed to single dashes, trimmed.
  def slugify(s)
    fold(s).gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
  end
end
