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
