# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'
require_relative 'forge_address'

# lib/commits_fetcher.rb -- data for the "Recent commits" sidebar widget.
# Optional: only active when config/site.yml has a `widgets.commits` section.
#
# Originally fetched by the visitor's browser: 1 request to /events/public
# plus another per commit, so 4 requests on every page view. GitHub's
# unauthenticated limit is 60/hour per IP, so the widget would disappear
# after a few dozen page views. Now fetched server-side into
# public/commits.json: still 1 + LIMIT requests on GitHub (a PushEvent
# payload only carries the sha, so the commit message needs a separate
# fetch), but once per cron run instead of on every page view.
#
# `instance:` points the same widget at a Gitea or Forgejo server instead --
# Codeberg, a company's own git, git.arch-linux.cz. Most of the Fediverse
# hosts its code somewhere other than GitHub, and the workaround until now
# was to mirror to GitHub for the sake of a sidebar card. The key holds the
# server's address, and its presence is the whole configuration: nothing
# else has to be said, because an address is already the answer to "which
# kind of host is this".
#
# The forge path costs ONE request where GitHub costs 1 + LIMIT: a Gitea
# activity item carries the commits it is about, message and timestamp
# included, so nothing has to be fetched a second time.
module CommitsFetcher
  # A setting that cannot work, as opposed to a request that did not: the
  # first empties the card (and the card then hides, which is the only way
  # anybody finds out), the second leaves the last good answer standing.
  # Until these were the same thing, a widget pointed at a typo looked
  # exactly like a widget whose author had not pushed lately -- forever.
  class BadConfig < StandardError; end

  RAW_USERNAME = SiteConfig.get('widgets', 'commits', 'username')
  RAW_LIMIT = SiteConfig.get('widgets', 'commits', 'limit', default: 3)
  INSTANCE = SiteConfig.get('widgets', 'commits', 'instance')
  # A commit older than the epoch or dated tomorrow is not a commit whose
  # date means anything: Gitea answers a missing timestamp with Go's zero
  # time, which rendered as "Jan 1, 0001" in the sidebar. The floor is the
  # epoch rather than git's own birthday -- a backdated or imported commit
  # from the nineties is somebody's real history, and this is not the place
  # to argue with it.
  EARLIEST_COMMIT = Time.utc(1970, 1, 1)

  # Asks only whether a username is written down at all. A malformed one
  # still counts as configured, or a broken widget would quietly cease to
  # exist instead of saying what is wrong with it.
  def self.configured?
    !RAW_USERNAME.nil?
  end

  def self.username
    ForgeAddress.username(RAW_USERNAME) ||
      raise(BadConfig, "widgets.commits.username is not a username: #{RAW_USERNAME.inspect}")
  end

  def self.limit
    value = RAW_LIMIT
    return value if value.is_a?(Integer) && value.positive?

    raise BadConfig, "widgets.commits.limit is not a positive number: #{value.inspect}"
  end

  # A base address, and nothing else: a handle, a path to one repository or
  # a bare host would each fail differently and late (a 404 parsed as JSON,
  # an empty widget nobody notices). doctor says the same thing at setup
  # time; this is the build's own refusal, so a bad key cannot quietly
  # become an empty card.
  def self.instance_base
    return nil if INSTANCE.to_s.strip.empty?

    ForgeAddress.base(INSTANCE) ||
      raise(BadConfig, I18n.t('cron.commits_instance_bad', value: INSTANCE.to_s))
  end

  def self.fetch_items
    return [] unless configured?

    # Read the settings BEFORE choosing a branch: a bad username used to be
    # raised inside the GitHub branch, where the rescue that catches network
    # trouble swallowed it as "fetch failed" -- and a fetch that failed keeps
    # the card's last good contents, so a widget that could never work again
    # showed January's commits forever. GitHub is the default branch, so that
    # was the common case, not the rare one.
    username
    limit
    base = instance_base
    base ? forge_items(base) : github_items
  end

  # Both branches assume they were handed a list. A forge that is unhappy
  # answers with an object instead ({"message": ...}), and Hash#select with
  # a one-argument block hands the block a KEY, so the filter quietly
  # produced an empty hash and the widget went blank without a word.
  def self.parse_list(body)
    data = JSON.parse(body.to_s)
    return data if data.is_a?(Array)

    said = data.is_a?(Hash) ? data['message'].to_s.strip : ''
    raise "expected a list, got #{data.class}#{said.empty? ? '' : " -- #{said}"}"
  end

  # One shared clock for both branches.
  def self.rendered_date(value)
    time = Time.parse(value.to_s)
    raise "implausible commit time #{value.inspect}" if time < EARLIEST_COMMIT || time > Time.now + 86_400

    # getlocal: git records the author's own offset, which is whatever
    # machine made the commit -- rendering it in site.timezone keeps the
    # widget consistent with every other date on the page.
    time.getlocal.strftime(I18n.t('date_format'))
  end

  # --- GitHub ---------------------------------------------------------------

  def self.github_items
    events = parse_list(FeedHttp.get("https://api.github.com/users/#{username}/events/public?per_page=30"))

    events.select { |e| e.is_a?(Hash) && e['type'] == 'PushEvent' }.first(limit).filter_map do |event|
      repo = event.dig('repo', 'name').to_s
      sha = event.dig('payload', 'head').to_s
      next if repo.empty? || sha.empty?

      commit(repo, sha)
    end
  rescue BadConfig
    raise
  rescue StandardError => e
    warn "GitHub feed fetch failed: #{e.message}"
    []
  end

  # One commit failing must not take down the whole widget -- the rest still render.
  def self.commit(repo, sha)
    data = JSON.parse(FeedHttp.get("https://api.github.com/repos/#{repo}/commits/#{sha}"))
    {
      # getlocal: git records the author's own offset, which is whatever
      # machine made the commit -- rendering it in site.timezone keeps the
      # widget consistent with every other date on the page.
      'date' => rendered_date(data.dig('commit', 'author', 'date')),
      'repo' => repo.split('/').last.to_s,
      'message' => data.dig('commit', 'message').to_s.split("\n").first.to_s,
      'url' => data['html_url'].to_s
    }
  rescue StandardError => e
    warn "GitHub commit fetch failed (#{repo}@#{sha[0, 7]}): #{e.message}"
    nil
  end

  # --- Gitea / Forgejo ------------------------------------------------------

  # only-performed-by: the feed otherwise carries what happened TO the user
  # as well (someone else's push to a repository they watch), and a card
  # headed "Recent commits" that lists a stranger's work is worse than an
  # empty one. 30 items, not LIMIT: the feed mixes issues, comments and
  # pull requests in with the pushes, so the pushes have to be found among
  # them -- the same reason the GitHub path asks for 30 events.
  def self.forge_items(base)
    user = username
    url = "#{base}/api/v1/users/#{user}/activities/feeds?only-performed-by=true&limit=30"
    pushes = parse_list(FeedHttp.get(url)).select { |item| item.is_a?(Hash) && item['op_type'] == 'commit_repo' }
    mine, theirs = pushes.partition { |item| performed_by?(item, user) }
    # Asking is not the same as being answered. `only-performed-by` is a
    # request the server MAY honour, and a card headed "Recent commits"
    # showing a stranger's work is worse than an empty one -- so the answer
    # is checked rather than trusted, and the difference is said out loud.
    unless theirs.empty?
      who = theirs.map { |item| actor(item) }.map { |name| name.empty? ? '(no act_user)' : name }.uniq
      warn "Forge feed: left out #{theirs.size} push(es) not by #{user} (#{who.join(', ')})"
    end
    # Newest first and each commit once: a feed item is a PUSH, and a push
    # of old work (a branch that sat around for months) arrives at the top
    # of the feed carrying commits from January. Sorting by the commit's own
    # time is what the GitHub branch has effectively always done, because
    # there one event is one commit. Duplicates come from the same commit
    # arriving in two pushes -- a merge, a force-push, a branch pushed twice.
    mine.flat_map { |item| forge_commits(item) }
        .uniq { |commit| commit['url'] }
        .sort_by { |commit| commit['__at'] }
        .reverse
        .first(limit)
        .each { |commit| commit.delete('__at') }
  rescue BadConfig
    raise
  rescue StandardError => e
    warn "Forge feed fetch failed (#{base}): #{e.message}"
    []
  end

  # `user_id` on a feed item is its RECIPIENT; `act_user` is whoever did the
  # thing. Verified against both live servers: every item of both feeds
  # carries act_user.
  def self.actor(item)
    who = item['act_user']
    (who.is_a?(Hash) ? (who['login'] || who['username']) : nil).to_s
  end

  def self.performed_by?(item, user)
    actor(item).casecmp?(user.to_s)
  end

  # The commits ride inside the activity item as a JSON string, newest
  # first, so one push of five commits is five entries here rather than one
  # -- which is what the widget wants: it counts commits, not pushes.
  def self.forge_commits(item)
    repo_url = item.dig('repo', 'html_url').to_s
    repo = item.dig('repo', 'full_name').to_s.split('/').last.to_s
    # A commit_repo item with no payload is a branch created or deleted --
    # a push with no commits in it. Ordinary, and not worth a line in cron
    # mail: seen twice in the first twenty items of a real instance.
    return [] if item['content'].to_s.strip.empty?

    commits = JSON.parse(item['content'].to_s)['Commits']
    raise "Commits is #{commits.class}, not a list" unless commits.is_a?(Array)

    commits.filter_map { |commit| forge_commit(commit, repo, repo_url) }
  rescue StandardError => e
    warn "Forge activity item skipped: #{e.message}"
    []
  end

  # Per COMMIT, not per push: Gitea packs up to five commits into one
  # activity item, so a single odd record used to cost the card five rows.
  # The promise the GitHub branch has always made -- one commit failing
  # must not take down the rest -- now holds on this branch too.
  def self.forge_commit(commit, repo, repo_url)
    return nil unless commit.is_a?(Hash)

    sha = commit['Sha1'].to_s
    return nil if sha.empty? || repo_url.empty?

    {
      # Kept for sorting and dropped before the JSON is written -- the
      # widget reads a rendered date, and a sort must not depend on how a
      # locale spells January.
      '__at' => Time.parse(commit['Timestamp'].to_s).to_i,
      'date' => rendered_date(commit['Timestamp']),
      'repo' => repo,
      'message' => commit['Message'].to_s.split("\n").first.to_s,
      'url' => "#{repo_url}/commit/#{sha}"
    }
  rescue StandardError => e
    warn "Forge commit skipped (#{repo}@#{commit.is_a?(Hash) ? commit['Sha1'].to_s[0, 7] : '?'}): #{e.message}"
    nil
  end
end
