# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'site_config'
require_relative 'atomic_write'
require_relative 'post_writer'
require_relative 'mastodon_poster'
require_relative 'bluesky_poster'
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
  # Mastodon's default status limit -- but instances routinely raise it,
  # so mastodon.toot_length in config/site.yml can too; the perex budget
  # scales with it.
  TOOT_LENGTH = SiteConfig.get('mastodon', 'toot_length', default: 500)
  # Bluesky's limit is fixed by the AT Protocol and counted in GRAPHEMES,
  # not characters -- hence the separate composition below.
  BLUESKY_LENGTH = 300

  module_function

  def base_url
    (ENV['SITE_BASE_URL'] || SiteConfig.get('site', 'base_url')).to_s.chomp('/')
  end

  def post_url(slug, year)
    "#{base_url}/posts/#{year}/#{slug}/"
  end

  # Moves a post's media directory into another year. Delegates to
  # PostWriter.move_media_dir for the two cautions a bare mv lacks: the
  # year folder under media.nosync/ may not exist yet (mkdir_p, or the mv
  # raises ENOENT -- that one used to kill the whole scheduled-publish
  # batch), and the target slug directory may already exist as an orphan,
  # where mv would NEST the source inside it and the page would silently
  # lose its files. One implementation, both call paths.
  def relocate_media(slug, from_year, to_year)
    return if from_year == to_year

    PostWriter.move_media_dir(File.join(MEDIA_DIR, from_year, slug),
                              File.join(MEDIA_DIR, to_year, slug))
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
      # A different post can already own <new_year>/<slug> -- writing
      # there would replace it wholesale, and the build's duplicate
      # check never fires because only one file remains.
      abort(I18n.t('cli.post_already_exists', slug: slug, path: new_path)) if File.exist?(new_path)

      FileUtils.mkdir_p(File.dirname(new_path))
      relocate_media(slug, old_year, new_year)
    end

    # Write first, delete second. A failure in between leaves the post
    # twice (recoverable: delete the copy in the year it left), where the
    # other order left no copy of it at all.
    AtomicWrite.write_json(new_path, updated)
    File.delete(path) if File.expand_path(new_path) != File.expand_path(path)
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

  def grapheme_length(text)
    text.scan(/\X/).length
  end

  # Same word-boundary trimming as perex_for, but budgeted in graphemes --
  # what Bluesky actually counts (an emoji or "ř" is one grapheme, not
  # one-plus bytes or codepoints).
  def perex_by_graphemes(blocks, max_graphemes)
    limit = [max_graphemes, PEREX_LENGTH].min
    plain = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip
    return plain if grapheme_length(plain) <= limit
    return '' if limit <= 0

    "#{plain.scan(/\X/).first(limit).join.sub(/\s+\S*\z/, '')}…"
  end

  # The Bluesky counterpart of compose_toot: same never-truncate rule for
  # title/url/hashtags, 300-grapheme budget. Links and hashtags become
  # clickable via facets, which BlueskyPoster builds from this text.
  def compose_bluesky_post(title:, slug:, year:, blocks:, tags:)
    url = post_url(slug, year)
    hashtags = hashtags_for(tags)
    fixed = [title, url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
    budget = BLUESKY_LENGTH - grapheme_length(fixed) - 2

    [title, perex_by_graphemes(blocks, budget), url, hashtags].reject { |p| p.to_s.strip.empty? }.join("\n\n")
  end

  # Sends the announcement to whichever network the site configured and
  # returns the post fields to store ('mastodon_url', or 'bluesky_url' +
  # 'bluesky_uri'), or nil when nothing was sent. The caller decides
  # WHETHER to announce (recency window, prompts); this decides only how.
  def announce(post, year:)
    title = post['title']
    slug = post['slug']
    blocks = post['content']
    tags = post['tags'] || []

    case SiteConfig.comment_network
    when :mastodon
      url = MastodonPoster.publish(compose_toot(title: title, slug: slug, year: year,
                                                blocks: blocks, tags: tags))
      url ? { 'mastodon_url' => url } : nil
    when :bluesky
      result = BlueskyPoster.publish(compose_bluesky_post(title: title, slug: slug, year: year,
                                                          blocks: blocks, tags: tags))
      result ? { 'bluesky_url' => result[:url], 'bluesky_uri' => result[:uri] } : nil
    end
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
