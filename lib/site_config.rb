# frozen_string_literal: true

require 'yaml'

# Every entry point requires this file, so the two process-wide
# prerequisites live here, next to the timezone handling below.
#
# Ruby 2.7 is the real floor (filter_map) -- checked up front so an old
# interpreter fails as one sentence naming the fix, not as a NoMethodError
# in the middle of writing the first post. macOS in particular still ships
# Ruby 2.6 as /usr/bin/ruby on every current version.
if (RUBY_VERSION.split('.').map(&:to_i) <=> [2, 7]).negative?
  abort("❌ Ruby #{RUBY_VERSION} is too old -- blog.sh needs Ruby 2.7 or newer. " \
        'macOS: brew install ruby (and put it before /usr/bin in PATH). Debian/Ubuntu: apt install ruby-full.')
end

# Posts, config and locales are UTF-8 regardless of what the OS calls its
# default -- on Windows Encoding.default_external is the ANSI codepage
# (CP1250 on a Czech system), so a File.write without an explicit encoding
# would store mojibake that every UTF-8 read then trips over.
Encoding.default_external = Encoding::UTF_8

# lib/site_config.rb -- loads config/site.yml.
#
# This is where everything that used to be hardcoded into templates and
# scripts lives: the site name, "About" text, footer links, social networks,
# sidebar widget settings, the timezone every timestamp is written in.
# Deliberately not in env.sh -- that file isn't synced and isn't in git, so
# a local build would render a different site than production and changes
# would have no history. env.sh keeps only secrets (API tokens).
module SiteConfig
  PATH = File.join(File.expand_path('..', __dir__), 'config', 'site.yml')

  module_function

  def data
    @data ||= begin
      unless File.exist?(PATH)
        abort("❌ Missing #{PATH} -- nothing can be generated without a site config. Copy config/site.yml.example to config/site.yml and fill it in.")
      end

      load_yaml(PATH)
    end
  end

  # Psych 4 (Ruby 3.1+) gave YAML.load_file safe_load semantics, where
  # anchors/aliases (`<<: *defaults`) raise -- a config that merely uses a
  # YAML feature shouldn't blow up, so allow them; older Psych doesn't know
  # the keyword and allows them anyway.
  def load_yaml(path)
    YAML.load_file(path, aliases: true) || {}
  rescue ArgumentError
    YAML.load_file(path) || {}
  end

  # Called once at startup by every entry point (each script under scripts/
  # and build/), before anything reads the clock -- a Time built earlier
  # would keep the machine's offset. Entry points call it unconditionally,
  # including the few whose time handling is offset-independent today
  # (comparing two absolute instants, or epoch floats), so that adding a
  # Time.now to one of them later can't quietly reintroduce the bug this
  # exists to fix.
  #
  # A site with no timezone: key keeps using the machine's own zone, which
  # is what every install did before this existed.
  def use_site_timezone!
    apply_timezone(get('site', 'timezone'))
  end

  # Shape of an IANA zone name ("Europe/Prague", "America/Argentina/
  # Buenos_Aires", "Etc/GMT+2", "UTC") -- checked before the name is joined
  # onto a path, so a value like "../../something" can't be smuggled past
  # the existence check in apply_timezone.
  ZONE_NAME_RE = %r{\A[A-Za-z][A-Za-z0-9+_-]*(/[A-Za-z0-9+_-]+)*\z}

  # Points the process at a timezone by setting TZ, which is all Ruby needs
  # -- it reads the system zoneinfo database from there, DST transitions
  # included. No gem, no timezone table of our own.
  #
  # An unknown zone name is a hard error rather than a warning: Ruby
  # silently falls back to UTC for one, so a typo like "Europe/Praha"
  # would quietly timestamp and publish everything two hours off, and the
  # only symptom would be dates that look slightly wrong months later.
  def apply_timezone(zone)
    zone = zone.to_s.strip
    return if zone.empty?

    unless zone.match?(ZONE_NAME_RE) &&
           (zone == 'UTC' || File.exist?(File.join('/usr/share/zoneinfo', zone)))
      abort("❌ Unknown site.timezone #{zone.inspect} in #{PATH} -- expected an IANA zone name like \"Europe/Prague\" or \"America/New_York\" (see /usr/share/zoneinfo), or \"UTC\".")
    end

    ENV['TZ'] = zone
  end

  # Required value: a missing key is a configuration error, not something
  # that should silently flow into the page as an empty string.
  def fetch(*keys)
    value = keys.reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    return value unless value.nil?

    abort("❌ Missing #{keys.join('.')} in #{PATH}")
  end

  # Optional value with a default fallback. Tolerates a missing config
  # file outright (returns the default), so code paths that merely *want*
  # a value -- `./blog.sh help`, the i18n locale pick -- work on a fresh
  # clone. Anything that *requires* the config still aborts, via fetch or
  # an explicit SiteConfig.data call.
  def get(*keys, default: nil)
    return default unless File.exist?(PATH)

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
