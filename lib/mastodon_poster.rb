require 'net/http'
require 'json'
require 'uri'
require 'digest'
require_relative 'site_config'
require_relative 'i18n'

# Posts a status to Mastodon on behalf of the blog, so each post can carry a
# "reply here to comment" toot. Entirely optional: without a `mastodon:`
# section in config/site.yml (or without MASTODON_ACCESS_TOKEN in the
# environment), publish/delete just return nil/false -- authoring a post
# never depends on Mastodon being configured or reachable. Requires
# MASTODON_ACCESS_TOKEN in the environment when it is configured (create one
# under Preferences -> Development -> New application on the target
# instance, scope write:statuses).
module MastodonPoster
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20

  INSTANCE = SiteConfig.get('mastodon', 'instance')

  def self.configured?
    !INSTANCE.nil?
  end

  # `idempotency_key` identifies the post being announced, not the run.
  # Mastodon keeps such a key for a while and answers a repeat with the
  # status it already created instead of making a second one -- which is
  # the whole defence against a toot that was accepted while the reply
  # was lost. Without it, the engine stored nothing, and the command that
  # exists for exactly that situation sent another toot.
  def self.publish(status_text, idempotency_key: nil)
    return nil unless configured?

    token = ENV['MASTODON_ACCESS_TOKEN']
    if token.to_s.empty?
      warn I18n.t('poster.no_mastodon_token_post')
      return nil
    end

    uri = URI("https://#{INSTANCE}/api/v1/statuses")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{token}"
    # Hashed rather than passed through: the key travels in a header, and
    # a slug is the author's text -- it can carry anything.
    req['Idempotency-Key'] = Digest::SHA256.hexdigest(idempotency_key.to_s) if idempotency_key
    req.set_form_data('status' => status_text, 'visibility' => 'public')

    # Timeouts, because an instance that stops answering must not hold the
    # CLI -- or the publishing cron, which runs every fifteen minutes --
    # for as long as the network feels like waiting. Same numbers as the
    # Bluesky poster, deliberately: two halves of one behaviour.
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
    unless res.is_a?(Net::HTTPSuccess)
      warn I18n.t('poster.mastodon_api_error', code: res.code, body: res.body)
      return nil
    end

    JSON.parse(res.body)['url']
  rescue StandardError => e
    warn I18n.t('poster.mastodon_post_failed', error: e.message)
    nil
  end

  # Takes the ID from the end of the stored status URL (.../@user/12345) --
  # only the URL is stored, not the ID, since publish originally had no need
  # for deletion.
  def self.delete(status_url)
    return false unless configured?

    token = ENV['MASTODON_ACCESS_TOKEN']
    if token.to_s.empty?
      warn I18n.t('poster.no_mastodon_token_delete')
      return false
    end

    status_id = status_url.to_s.split('/').last
    if status_id.to_s.empty?
      warn I18n.t('poster.mastodon_id_unreadable', url: status_url)
      return false
    end

    uri = URI("https://#{INSTANCE}/api/v1/statuses/#{status_id}")
    req = Net::HTTP::Delete.new(uri)
    req['Authorization'] = "Bearer #{token}"

    # Timeouts, because an instance that stops answering must not hold the
    # CLI -- or the publishing cron, which runs every fifteen minutes --
    # for as long as the network feels like waiting. Same numbers as the
    # Bluesky poster, deliberately: two halves of one behaviour.
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
    unless res.is_a?(Net::HTTPSuccess)
      warn I18n.t('poster.mastodon_api_error_delete', code: res.code, body: res.body)
      return false
    end

    true
  rescue StandardError => e
    warn I18n.t('poster.mastodon_delete_failed', error: e.message)
    false
  end
end
