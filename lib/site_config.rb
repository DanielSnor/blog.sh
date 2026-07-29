# frozen_string_literal: true

require 'yaml'

# lib/site_config.rb -- loads config/site.yml.
#
# This is where everything that used to be hardcoded into templates and
# scripts lives: the site name, "About" text, footer links, social networks,
# sidebar widget settings. Deliberately not in env.sh -- that file isn't
# synced and isn't in git, so a local build would render a different site
# than production and changes would have no history. env.sh keeps only
# secrets (API tokens).
module SiteConfig
  PATH = File.join(File.expand_path('..', __dir__), 'config', 'site.yml')

  module_function

  def data
    @data ||= begin
      unless File.exist?(PATH)
        abort("❌ Missing #{PATH} -- nothing can be generated without a site config. Copy config/site.yml.example to config/site.yml and fill it in.")
      end

      YAML.load_file(PATH) || {}
    end
  end

  # Required value: a missing key is a configuration error, not something
  # that should silently flow into the page as an empty string.
  def fetch(*keys)
    value = keys.reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    return value unless value.nil?

    abort("❌ Missing #{keys.join('.')} in #{PATH}")
  end

  # Optional value with a default fallback.
  def get(*keys, default: nil)
    value = keys.reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    value.nil? ? default : value
  end

  # The comments/announcement network: :mastodon, :bluesky, or nil when
  # neither is configured. Deliberately exclusive -- a post's comments
  # live on exactly one network, so configuring both sections at once is
  # a config error, not a feature: two half-threads of discussion under
  # every post would serve nobody.
  def comment_network
    mastodon = get('mastodon', 'instance')
    bluesky = get('bluesky', 'handle')
    if mastodon && bluesky
      abort('❌ Both mastodon: and bluesky: are configured in config/site.yml -- pick one. ' \
            'Comments and the announcement post live on exactly one network.')
    end
    return :mastodon if mastodon
    return :bluesky if bluesky

    nil
  end
end
