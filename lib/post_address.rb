# frozen_string_literal: true

# lib/post_address.rb -- where a post lives on the site.
#
# One rule, in one place, because three places were answering it and one of
# them was answering it wrong. The build has always known that a draft is
# served under its token, a page at the site root and everything else under
# its year; `check --repair` grew its own copy of that rule with the first
# two branches missing, and so offered to rewrite a working link into an
# address the site never answers at.
#
# The module deliberately holds no state and requires nothing: the build,
# the checker and the repair pass can all depend on it without depending on
# each other.
module PostAddress
  module_function

  # `year` is passed by the build, which has the post's time parsed and
  # cached already; everyone else lets this read it from the date. The two
  # must not diverge, which is the whole reason for the parameter.
  def path(post, year: nil)
    return "/draft/#{post['draft_token']}/#{post['slug']}/" if draft?(post)
    return "/#{post['slug']}/" if page?(post)

    "/posts/#{year || date_year(post)}/#{post['slug']}/"
  end


  # The address a post is being moved AWAY from, in the shape the archive
  # records such debts. Two shapes, because a page's address has no year in
  # it and former_slugs (which is "<year>/<slug>") cannot say so:
  #   a post -> "2026/old-slug", spent into former_slugs
  #   a page -> "/old-slug/",    spent into redirect_from
  # Written down in ONE place because it was worked out separately in five
  # (edit, rename, unpublish, publish, re-import) and each of them got it
  # wrong at a different time: the year came off the FOLDER, which parts
  # company with the address the moment a date is corrected across a year.
  def vacated_marker(post, slug: nil)
    name = slug || post['slug']
    return "/#{name}/" if page?(post)

    "#{date_year(post)}/#{name}"
  end

  # Spends such a marker into whichever list can express it, and never lets
  # a post redirect to itself.
  def spend_vacated(post, marker, slug: nil, year: nil)
    return post if marker.to_s.empty?

    name = slug || post['slug']
    if marker.to_s.start_with?('/')
      olds = (Array(post['redirect_from']).map(&:to_s) + [marker.to_s]).uniq - ["/#{name}/"]
      olds.empty? ? post.delete('redirect_from') : post['redirect_from'] = olds
    else
      former = (Array(post['former_slugs']).map(&:to_s) + [marker.to_s]).uniq - ["#{year || date_year(post)}/#{name}"]
      former.empty? ? post.delete('former_slugs') : post['former_slugs'] = former
    end
    post
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  def page?(post)
    value = post['page']
    return post['type'].to_s == 'page' if value.nil?

    ![false, 'false', 'no', 0, '0'].include?(value)
  end

  # The year in the post's own date -- what the address is built from.
  def date_year(post)
    post['date'].to_s[0, 4]
  end

  # The year of the DIRECTORY the file sits in, which is what the checker
  # loads and what names the file on disk. Usually the same as date_year
  # and occasionally not: a post whose date was corrected after publishing
  # keeps its file where it was, because moving it would change its
  # address. "Where it is served" and "where it is stored" are two
  # questions, and the repair pass used to answer both with one value.
  def file_year(post)
    post['__year'] || date_year(post)
  end
end
