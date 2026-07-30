# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'feed_http'
require_relative 'site_config'
require_relative 'i18n'

# lib/github_fetcher.rb -- data for the "Recent commits" sidebar widget.
# Optional: only active when config/site.yml has a `widgets.commits` section.
#
# Originally fetched by the visitor's browser: 1 request to /events/public
# plus another per commit, so 4 requests on every page view. GitHub's
# unauthenticated limit is 60/hour per IP, so the widget would disappear
# after a few dozen page views. Now fetched server-side into
# public/commits.json: still 1 + LIMIT requests (a PushEvent payload only
# carries the sha, so the commit message needs a separate fetch), but once
# per cron run instead of on every page view.
module GithubFetcher
  USERNAME = SiteConfig.get('widgets', 'commits', 'username')
  LIMIT = SiteConfig.get('widgets', 'commits', 'limit', default: 3)

  def self.configured?
    !USERNAME.nil?
  end

  def self.fetch_items
    return [] unless configured?

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
end
