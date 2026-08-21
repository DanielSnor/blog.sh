# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

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
  USERNAME = SiteConfig.get('widgets', 'commits', 'username')
  LIMIT = SiteConfig.get('widgets', 'commits', 'limit', default: 3)
  INSTANCE = SiteConfig.get('widgets', 'commits', 'instance')

  def self.configured?
    !USERNAME.nil?
  end

  # A base address, and nothing else: a handle, a path to one repository or
  # a bare host would each fail differently and late (a 404 parsed as JSON,
  # an empty widget nobody notices). doctor says the same thing at setup
  # time; this is the build's own refusal, so a bad key cannot quietly
  # become an empty card.
  def self.instance_base
    base = INSTANCE.to_s.strip.sub(%r{/+\z}, '')
    return nil if base.empty?
    return base if base.match?(%r{\Ahttps?://[^/\s]+\z})

    warn I18n.t('cron.commits_instance_bad', value: INSTANCE.to_s)
    nil
  end

  def self.fetch_items
    return [] unless configured?
    return github_items if INSTANCE.to_s.strip.empty?

    base = instance_base
    base ? forge_items(base) : []
  end

  # --- GitHub ---------------------------------------------------------------

  def self.github_items
    events = JSON.parse(FeedHttp.get("https://api.github.com/users/#{USERNAME}/events/public?per_page=30"))

    events.select { |e| e['type'] == 'PushEvent' }.first(LIMIT).filter_map do |event|
      repo = event.dig('repo', 'name').to_s
      sha = event.dig('payload', 'head').to_s
      next if repo.empty? || sha.empty?

      commit(repo, sha)
    end
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
      'date' => Time.parse(data.dig('commit', 'author', 'date')).getlocal.strftime(I18n.t('date_format')),
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
    url = "#{base}/api/v1/users/#{USERNAME}/activities/feeds?only-performed-by=true&limit=30"
    JSON.parse(FeedHttp.get(url))
        .select { |item| item['op_type'] == 'commit_repo' }
        .flat_map { |item| forge_commits(item) }
        .first(LIMIT)
  rescue StandardError => e
    warn "Forge feed fetch failed (#{base}): #{e.message}"
    []
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

    payload = JSON.parse(item['content'].to_s)
    Array(payload['Commits']).filter_map do |c|
      sha = c['Sha1'].to_s
      next if sha.empty? || repo_url.empty?

      {
        'date' => Time.parse(c['Timestamp'].to_s).getlocal.strftime(I18n.t('date_format')),
        'repo' => repo,
        'message' => c['Message'].to_s.split("\n").first.to_s,
        'url' => "#{repo_url}/commit/#{sha}"
      }
    end
  rescue StandardError => e
    warn "Forge activity item skipped: #{e.message}"
    []
  end
end
