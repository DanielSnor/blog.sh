# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'site_config'
require_relative 'i18n'

# lib/publishing.rb -- the mechanics of making a draft public, shared by
# the interactive CLI (scripts/manage_post.rb) and the scheduled-publish
# cron (scripts/publish_scheduled.rb). The split is decisions vs
# execution: the CLI owns every prompt and choice (which date to use,
# whether to toot outside the recency window), the cron owns none (a
# schedule IS the decision) -- and both execute through here, so the two
# paths can't drift apart.
module Publishing
  ROOT = File.expand_path('..', __dir__)
  CONTENT_DIR = File.join(ROOT, 'content.nosync', 'posts')
  MEDIA_DIR = File.join(ROOT, 'media.nosync')

  PEREX_LENGTH = 250
  TOOT_LENGTH = 500

  module_function

  def base_url
    (ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')).to_s.chomp('/')
  end

  def post_url(slug, year)
    "#{base_url}/posts/#{year}/#{slug}/"
  end

  # Rewrites a draft as published under `date`: drops the draft-only
  # fields (draft_token, the scheduled flag), moves the JSON -- and the
  # post's media directory -- into the right year when the date changed
  # it, and returns [new_path, updated_post]. Media files themselves are
  # never rewritten, only moved.
  def publish(path, post, date:)
    slug = post['slug']
    old_year = File.basename(File.dirname(path))
    new_year = date.year.to_s

    updated = post.merge('state' => 'published', 'date' => date.iso8601)
    updated.delete('draft_token')
    updated.delete('scheduled')

    new_path = File.join(CONTENT_DIR, new_year, "#{slug}.json")
    if new_year != old_year
      FileUtils.mkdir_p(File.dirname(new_path))
      old_media = File.join(MEDIA_DIR, old_year, slug)
      FileUtils.mv(old_media, File.join(MEDIA_DIR, new_year, slug)) if Dir.exist?(old_media)
      File.delete(path)
    end
    File.write(new_path, JSON.pretty_generate(updated))
    [new_path, updated]
  end

  # Up to `max_length` chars of the post's plain text (capped at
  # PEREX_LENGTH), trimmed to a whole word and marked with an ellipsis if
  # it got cut off. Soft line breaks the author typed inside a paragraph
  # are invisible in HTML but visible in a plain-text toot -- so all
  # internal whitespace collapses to single spaces first.
  def perex_for(blocks, max_length = PEREX_LENGTH)
    limit = [max_length, PEREX_LENGTH].min
    plain = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip
    return plain if plain.length <= limit
    return '' if limit <= 0

    "#{plain[0, limit].sub(/\s+\S*\z/, '')}…"
  end

  def hashtags_for(tags)
    tags.map { |t| "##{t.to_s.gsub(/\s+/, '')}" }.join(' ')
  end

  # title/url/hashtags must never be truncated (a cut-off URL is a dead
  # link, a cut-off hashtag is a broken one) -- only the perex shrinks to
  # make the whole toot fit under Mastodon's TOOT_LENGTH limit.
  def compose_toot(title:, slug:, year:, blocks:, tags:)
    url = post_url(slug, year)
    hashtags = hashtags_for(tags)
    fixed_length = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n").length
    budget = TOOT_LENGTH - fixed_length - 2 # 2 = the "\n\n" the perex adds once inserted

    [title, perex_for(blocks, budget), url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
  end

  # Build and deploy as one step (--prune included: after a delete or a
  # year-changing edit, live pages remain on the target that the build no
  # longer generates -- without prune, nothing would ever clean them up).
  def rebuild_and_deploy(reason)
    puts
    puts "#{reason}…"
    unless system('ruby', File.join(ROOT, 'build', 'build_blog.rb'))
      warn I18n.t('cli.build_failed')
      return false
    end

    return true if system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--prune')

    warn I18n.t('cli.deploy_failed')
    false
  end
end
