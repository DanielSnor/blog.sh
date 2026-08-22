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
# The module deliberately holds no state and requires nothing beyond the
# standard library's date parsing: the build, the checker and the repair
# pass can all depend on it without depending on each other.
require 'time'

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
  #
  # "Itself" is asked of the post's CURRENT state, not guessed from the
  # shape of the debt. Unpublish a post, turn it into a page, publish it:
  # the debt reads "2026/aaa" because a post wrote it, while the thing
  # paying it is now a page served at /aaa/. Matching shape against shape
  # read that as a redirect to self and threw a real debt away.
  #
  # A marker that is nil or empty still runs the self-reference sweep --
  # publish did that unconditionally before this became one function, and
  # an archive that arrived carrying a redirect to itself (an import, a
  # hand edit, an older engine) was quietly healed by the next publish
  # instead of warning on every build with nothing able to clear it.
  def spend_vacated(post, marker, slug: nil, year: nil)
    name = (slug || post['slug']).to_s
    # A draft is served under its token and nowhere else, so there is no
    # address it could be redirecting to itself. Working one out anyway
    # subtracted a debt the post genuinely owes: one ordinary edit of a
    # draft and the redirect to its old public address was gone, with the
    # build silent and check calling the archive sound.
    mine = if draft?(post)
             nil
           elsif page?(post)
             "/#{name}/"
           else
             "#{year || date_year(post)}/#{name}"
           end
    debts = Array(marker).map(&:to_s).reject(&:empty?)

    olds = (Array(post['redirect_from']).map(&:to_s) + debts.grep(%r{\A/})).uniq - [mine].compact
    former = (Array(post['former_slugs']).map(&:to_s) + debts.grep_v(%r{\A/})).uniq - [mine].compact

    olds.empty? ? post.delete('redirect_from') : post['redirect_from'] = olds
    former.empty? ? post.delete('former_slugs') : post['former_slugs'] = former
    post
  end

  # Every way two posts can end up on top of each other.
  #
  # The build refuses to run on two posts sharing a year and a slug: they
  # would write one output directory and one media/<year>/<slug>/ between
  # them, so one of them would silently disappear. Pages add a second way,
  # because a page is served at the root: two of them with one slug collide
  # however far apart their dates are, and that one the build did not catch
  # at all -- it built both and served whichever it wrote last.
  #
  # Three places were answering this and no two of them agreed -- the build
  # by year and slug, the checker by "page" OR year, the rename guard by
  # the served address -- so each let through what the others refused. A
  # rename could hand the archive a state the build then declined to build:
  # the whole site stopped by an answer to a question nobody had written
  # down once.
  #
  # A draft gets the year/slug key (its file and its media live there like
  # everyone else's) but never the page key: it is served under its token,
  # not at the root.
  def collision_keys(post, slug: nil, year: nil)
    name = (slug || post['slug']).to_s
    keys = [[(year || date_year(post)).to_s, name]]
    keys << ['page', name] if page?(post) && !draft?(post)
    keys
  end

  def draft?(post)
    post['state'].to_s == 'draft'
  end

  # The build asks this now instead of keeping its own copy, which read
  # only `page` and read it with a different notion of "no": `page: "No"`
  # was a page to one of them and an ordinary post to the other, so the
  # site served it under its year while the checker, the repair pass and
  # the rename guard all thought it lived at the root. Since the collision
  # keys, that disagreement also decides whether the build runs at all.
  def page?(post)
    value = post['page']
    return post['type'].to_s == 'page' if value.nil?
    return false if value == false

    !%w[false no 0].include?(value.to_s.strip.downcase)
  end

  # The year in the post's own date -- what the address is built from.
  def date_year(post)
    raw = post['date'].to_s
    return raw[0, 4] if raw.match?(/\A\d{4}/)

    # An imported archive can carry "Thu, 01 Jan 2026 10:00:00 +0100", and
    # four characters off the front of that is "Thu,". The build parses the
    # date to find the year, so taking a substring here was one more way
    # for the two to disagree -- with a redirect written to /posts/Thu,/ to
    # show for it.
    begin
      Time.parse(raw).year.to_s
    rescue StandardError
      raw[0, 4]
    end
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
