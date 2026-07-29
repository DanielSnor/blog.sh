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

  # NFKD + strip combining marks transliterates any diacritic generically
  # (e.g. "želnavský" -> "zelnavsky", not just Czech), then lowercases and
  # collapses whitespace. Without the NFKD step, accented characters would
  # just get dropped as "non a-z0-9" by slugify below, fragmenting the slug
  # instead of romanizing it. Mirrored client-side by fold() in search.js.
  def fold(s)
    s.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase.gsub(/\s+/, ' ').strip
  end

  # fold + everything non-alphanumeric collapsed to single dashes, trimmed.
  def slugify(s)
    fold(s).gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
  end
end
