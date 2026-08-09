# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative 'site_config'
require_relative 'i18n'
require_relative 'media_dimensions'
require_relative 'deploy_backend'

# lib/doctor.rb -- reads whatever configuration is on disk and says, in
# whole sentences, what is wrong with it.
#
# The failure this exists for is not "the engine has a bug". It is "I
# edited the YAML, it broke, and the message tells me about a line number
# in a file I didn't know existed". Every abort in the engine is correct
# where it stands -- the build cannot proceed on a config with two
# comment networks -- but each one only reports the FIRST thing wrong,
# from wherever the code happened to notice, and says nothing about the
# five other things waiting behind it. Doctor reports all of them at once,
# before anything is built or deployed.
#
# Two rules it lives by. It never aborts: a config so broken that YAML
# won't parse is the case it most needs to survive, so it reads the file
# itself rather than going through SiteConfig (whose fetch/apply_timezone
# abort by design, and rightly). And it is offline by default -- a
# diagnostic that hangs on a dead host is worse than no diagnostic --
# with network checks behind --online for when the question really is
# "does this token still work".
#
# Findings are data, not printing: the same checks back the setup wizard,
# which asks about one section at a time and wants the findings for that
# section only.
module Doctor
  ROOT = File.expand_path('..', __dir__)
  SITE_YML = File.join(ROOT, 'config', 'site.yml')
  ENV_SH = File.join(ROOT, 'env.sh')

  # Endless method definitions would read better here and are wrong here:
  # the engine's floor is Ruby 2.7 (see site_config.rb) and they arrived
  # in 3.0.
  Finding = Struct.new(:level, :text, :fix, keyword_init: true) do
    def error?
      level == :error
    end

    def warn?
      level == :warn
    end
  end

  # The values the shipped template carries so a fresh clone renders
  # before anything has been filled in. Live on a real site they mean the
  # opposite -- nobody got round to this one -- so they are worth naming
  # even though every one of them is technically valid config.
  #
  # mastodon.instance's "mastodon.social" is deliberately NOT here: it is
  # the template's placeholder AND the largest real instance, so flagging
  # it would cry wolf at the people most likely to be right.
  # The footer headings ("Links", "Find me on") are deliberately not
  # here either, for the same reason as mastodon.social: they are
  # placeholder AND perfectly good answers, so an English site keeping
  # them is more likely right than stale. The copyright line is not --
  # nobody's real copyright reads "All rights reserved" with no name.
  PLACEHOLDERS = {
    %w[site title] => 'Your Name - personal web/log',
    %w[site short_name] => 'YOURSITE',
    %w[site description] => 'Personal web/log of Your Name',
    %w[site author] => 'Your Name',
    %w[banner alt] => 'Your Site',
    %w[footer copyright] => 'All rights reserved &copy; 2026'
  }.freeze

  COLOR_KEYS = %w[bg text meta_text accent nav_bg border pill_bg].freeze
  HEX = /\A#(\h{3}|\h{6})\z/

  # Which env.sh values each deploy backend needs before it can ship
  # anything. DeployBackend's own `configured?` answers yes/no; this names
  # the variable, which is the part a person can act on.
  #
  # Kept here rather than on the backends because it is doctor's business
  # to be specific, not theirs -- but that does mean a backend which grows
  # a new required value needs a line here too.
  BACKEND_VALUES = {
    'surfer' => %w[SURFER_URL SURFER_TOKEN],
    'local' => %w[DEPLOY_TARGET_DIR],
    'rsync' => %w[RSYNC_TARGET],
    'git' => %w[GIT_PAGES_REMOTE],
    'rclone' => %w[RCLONE_TARGET],
    'sftp' => %w[SFTP_TARGET]
  }.freeze

  module_function

  def t(key, **vars)
    I18n.t("doctor.#{key}", **vars)
  end

  def ok(text)
    Finding.new(level: :ok, text: text)
  end

  def warn(text, fix = nil)
    Finding.new(level: :warn, text: text, fix: fix)
  end

  def error(text, fix = nil)
    Finding.new(level: :error, text: text, fix: fix)
  end

  # Runs everything and returns the findings in reading order: the files
  # first (nothing else can be judged without them), then identity,
  # network, appearance, deploy.
  def run(online: false, root: ROOT)
    findings = []
    findings.concat(check_env_sh(root))

    data, parse_findings = load_site_yml(root)
    findings.concat(parse_findings)
    return findings unless data

    findings.concat(check_identity(data))
    findings.concat(check_placeholders(data))
    findings.concat(check_locale(data))
    findings.concat(check_timezone(data))
    findings.concat(check_network(data))
    findings.concat(check_banner(data, root))
    findings.concat(check_colors(data))
    findings.concat(check_fonts(data, root))
    findings.concat(check_widgets(data))
    findings.concat(check_publishing(data))
    findings.concat(check_deploy)
    findings.concat(check_online(data)) if online
    findings
  end

  def dig(data, *keys)
    keys.reduce(data) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
  end

  # --- files ---------------------------------------------------------

  # A missing env.sh is not an error: the whole point of the documented
  # "an unedited copy is enough to try things out locally" is that the
  # engine runs without one. A world-readable one holding a live token is
  # a different matter.
  def check_env_sh(root)
    path = File.join(root, 'env.sh')
    return [warn(t('env_missing'), t('env_missing_fix'))] unless File.exist?(path)

    mode = File.stat(path).mode & 0o777
    return [ok(t('env_ok'))] if mode == 0o600

    [warn(t('env_mode', mode: format('%o', mode)), t('env_mode_fix'))]
  end

  # The parse error is the one message that has to carry a line number:
  # "did not find expected key at line 42 column 3" is the whole answer to
  # the most common way a hand-edited config breaks, and Psych already
  # says it.
  def load_site_yml(root)
    path = File.join(root, 'config', 'site.yml')
    return [nil, [error(t('site_yml_missing'), t('site_yml_missing_fix'))]] unless File.exist?(path)

    begin
      data = YAML.load_file(path, aliases: true)
    rescue ArgumentError
      data = begin
        YAML.load_file(path)
      rescue Psych::SyntaxError => e
        return [nil, [error(t('site_yml_syntax', message: e.problem.to_s), t('site_yml_syntax_fix', line: e.line, column: e.column))]]
      rescue SystemCallError => e
        return [nil, [error(t('site_yml_unreadable', message: e.message), t('site_yml_unreadable_fix'))]]
      end
    rescue Psych::SyntaxError => e
      return [nil, [error(t('site_yml_syntax', message: e.problem.to_s), t('site_yml_syntax_fix', line: e.line, column: e.column))]]
    rescue SystemCallError => e
      # A file that exists but cannot be OPENED -- wrong permissions after
      # a root-run wizard is the usual story. The one command whose whole
      # job is diagnosis must say that, not die with Psych's backtrace.
      return [nil, [error(t('site_yml_unreadable', message: e.message), t('site_yml_unreadable_fix'))]]
    end

    return [nil, [error(t('site_yml_empty'), t('site_yml_missing_fix'))]] unless data.is_a?(Hash)

    [data, [ok(t('site_yml_ok'))]]
  end

  # --- identity ------------------------------------------------------

  REQUIRED = [
    %w[site title], %w[site short_name], %w[site description], %w[site author],
    %w[banner src], %w[about html], %w[footer copyright]
  ].freeze

  def check_identity(data)
    # .to_s.strip: a key present but EMPTY ('title: ""') builds an empty
    # <title> on every page -- "present" is not "filled in".
    missing = REQUIRED.reject { |path| !dig(data, *path).to_s.strip.empty? }
    findings = missing.map { |path| error(t('key_missing', key: path.join('.'))) }

    base = ENV['SITE_BASE_URL'].to_s.empty? ? dig(data, 'site', 'base_url').to_s : ENV['SITE_BASE_URL'].to_s
    if base.empty?
      findings << error(t('base_url_missing'), t('base_url_missing_fix'))
    elsif base == 'https://example.com'
      findings << warn(t('base_url_placeholder'), t('base_url_placeholder_fix'))
    elsif !base.match?(%r{\Ahttps?://[^/\s]+})
      findings << error(t('base_url_shape', value: base), t('base_url_shape_fix'))
    elsif base.end_with?('/')
      findings << warn(t('base_url_slash', value: base), t('base_url_slash_fix'))
    end

    size = dig(data, 'site', 'page_size')
    findings << error(t('page_size', value: size.inspect)) if size && !(size.is_a?(Integer) && size.positive?)

    findings << ok(t('identity_ok')) if findings.empty?
    findings
  end

  def check_placeholders(data)
    stale = PLACEHOLDERS.select { |path, value| dig(data, *path) == value }.keys
    stale << %w[about html] if dig(data, 'about', 'html').to_s.include?('A short bio about yourself')
    # Substring, like about.html: the note is folded YAML, so the loaded
    # value differs from the template file's literal text by its wrapping.
    stale << %w[footer note_html] if dig(data, 'footer', 'note_html').to_s.include?('caught your eye')

    social = data['social']
    stale << %w[social] if social.is_a?(Array) && social.any? { |s| s.is_a?(Hash) && s['url'].to_s.include?('yourname') }

    links = dig(data, 'footer', 'links')
    stale << %w[footer links] if links.is_a?(Array) && links.any? { |l| l.is_a?(Hash) && l['url'] == 'https://example.com' }

    return [] if stale.empty?

    [warn(t('placeholders', keys: stale.map { |k| k.join('.') }.join(', ')), t('placeholders_fix'))]
  end

  def check_locale(data)
    lang = dig(data, 'site', 'lang') || 'en'
    path = File.join(ROOT, 'locales', "#{lang}.yml")
    return [] if File.exist?(path)

    available = Dir.glob(File.join(ROOT, 'locales', '*.yml')).map { |f| File.basename(f, '.yml') }.sort
    [error(t('lang_unknown', lang: lang), t('lang_unknown_fix', available: available.join(', ')))]
  end

  # A typo here is invisible until months later: Ruby silently falls back
  # to UTC for an unknown zone, so "Europe/Praha" timestamps and publishes
  # everything two hours off and nothing ever says so. SiteConfig aborts
  # on it; doctor is the place that finds it before the abort does.
  def check_timezone(data)
    zone = dig(data, 'site', 'timezone').to_s.strip
    return [] if zone.empty?

    valid = zone.match?(SiteConfig::ZONE_NAME_RE) &&
            (zone == 'UTC' || File.exist?(File.join('/usr/share/zoneinfo', zone)))
    return [ok(t('timezone_ok', zone: zone))] if valid

    [error(t('timezone_unknown', zone: zone), t('timezone_unknown_fix'))]
  end

  # --- network -------------------------------------------------------

  def check_network(data)
    mastodon = dig(data, 'mastodon', 'instance')
    bluesky = dig(data, 'bluesky', 'handle')

    if mastodon && bluesky
      return [error(t('both_networks'), t('both_networks_fix'))]
    end

    findings = []
    if mastodon
      findings << error(t('mastodon_instance_shape', value: mastodon)) if mastodon.to_s.include?('/')
      if ENV['MASTODON_ACCESS_TOKEN'].to_s.empty?
        findings << warn(t('mastodon_token_missing'), t('mastodon_token_missing_fix'))
      else
        findings << ok(t('mastodon_ok', instance: mastodon))
      end
      length = dig(data, 'mastodon', 'toot_length')
      findings << error(t('toot_length', value: length.inspect)) if length && !(length.is_a?(Integer) && length.positive?)
    elsif bluesky
      if ENV['BLUESKY_APP_PASSWORD'].to_s.empty?
        findings << warn(t('bluesky_password_missing'), t('bluesky_password_missing_fix'))
      else
        findings << ok(t('bluesky_ok', handle: bluesky))
      end
    else
      findings << ok(t('no_network'))
    end
    findings
  end

  # --- appearance ----------------------------------------------------

  # The declared width/height reserve space before the image loads, so
  # getting them wrong is a layout jump on every page -- and they are
  # copied by hand from whatever the file used to be, which is exactly the
  # kind of thing that goes stale the first time the banner is redrawn.
  def check_banner(data, root)
    src = dig(data, 'banner', 'src').to_s
    return [] if src.empty?

    path = File.join(root, src.sub(%r{\A/}, ''))
    unless File.exist?(path)
      seed = File.join(root, 'assets', 'images', 'defaults', File.basename(path))
      return [ok(t('banner_default'))] if File.exist?(seed)

      return [error(t('banner_missing', path: src), t('banner_missing_fix'))]
    end

    declared = [dig(data, 'banner', 'width'), dig(data, 'banner', 'height')]
    actual = begin
      MediaDimensions.image(path)
    rescue StandardError
      nil
    end
    return [ok(t('banner_ok'))] if actual.nil? || declared.any?(&:nil?)
    return [ok(t('banner_ok'))] if declared.map(&:to_i) == actual.map(&:to_i)

    [warn(t('banner_dimensions', declared: declared.join('x'), actual: actual.join('x')),
          t('banner_dimensions_fix', width: actual[0], height: actual[1]))]
  end

  def check_colors(data)
    colors = data['colors']
    return [] unless colors.is_a?(Hash)

    findings = []
    %w[light dark].each do |mode|
      set = colors[mode]
      next unless set.is_a?(Hash)

      missing = COLOR_KEYS.reject { |k| set.key?(k) }
      findings << warn(t('colors_missing', mode: mode, keys: missing.join(', ')), t('colors_missing_fix')) if missing.any?
      set.each do |key, value|
        next if value.to_s.match?(HEX)

        findings << error(t('colors_hex', mode: mode, key: key, value: value.inspect), t('colors_hex_fix'))
      end
    end
    findings << ok(t('colors_ok')) if findings.empty?
    findings
  end

  # A font file named here but absent from assets/fonts/ renders the site
  # in the fallback, which looks exactly like the config not working. The
  # build already says so; doctor says it without needing a build.
  def check_fonts(data, root)
    faces = dig(data, 'fonts', 'faces')
    return [] unless faces.is_a?(Array)

    missing = faces.filter_map do |face|
      next unless face.is_a?(Hash)

      file = File.basename(face['file'].to_s)
      file unless file.empty? || File.exist?(File.join(root, 'assets', 'fonts', file))
    end
    return [ok(t('fonts_ok'))] if missing.empty?

    [error(t('fonts_missing', files: missing.join(', ')), t('fonts_missing_fix'))]
  end

  # Each widget needs the one value that identifies what it should show.
  # Without it the refresh writes an empty file and the sidebar silently
  # shows nothing -- a failure with no symptom anywhere else.
  WIDGET_REQUIRED = {
    'toots' => 'account_id',
    'pixelfed' => 'feed_url',
    'commits' => 'username',
    'rss' => 'feed_url'
  }.freeze

  def check_widgets(data)
    widgets = data['widgets']
    return [] unless widgets.is_a?(Hash)

    findings = []
    widgets.each do |name, conf|
      unless conf.is_a?(Hash)
        findings << error(t('widget_shape', name: name))
        next
      end

      required = WIDGET_REQUIRED[name]
      if required && conf[required].to_s.empty?
        findings << error(t('widget_incomplete', name: name, key: required))
      elsif name == 'toots' && !conf['account_id'].to_s.match?(/\A\d+\z/)
        # The numeric id, not the @handle -- the single most common way
        # this widget is filled in wrong, and it fails silently.
        findings << error(t('widget_account_id', value: conf['account_id'].inspect), t('widget_account_id_fix'))
      end

      findings << warn(t('widget_heading', name: name)) if conf['heading'].to_s.empty?
      limit = conf['limit']
      findings << error(t('widget_limit', name: name, value: limit.inspect)) if limit && !(limit.is_a?(Integer) && limit.positive?)
    end
    findings << ok(t('widgets_ok', count: widgets.size)) if findings.empty? && widgets.any?
    findings
  end

  def check_publishing(data)
    slots = dig(data, 'publishing', 'slots')
    return [] unless slots

    unless slots.is_a?(Array)
      return [error(t('slots_shape'))]
    end

    bad = slots.reject { |s| s.to_s.match?(/\A(mon|tue|wed|thu|fri|sat|sun|daily)\s+([01]?\d|2[0-3]):[0-5]\d\z/i) }
    return [ok(t('slots_ok', count: slots.size))] if bad.empty?

    [error(t('slots_bad', values: bad.map(&:inspect).join(', ')), t('slots_bad_fix'))]
  end

  # --- deploy --------------------------------------------------------

  def check_deploy
    name = ENV['DEPLOY_BACKEND'].to_s

    # An unset DEPLOY_BACKEND means Surfer -- that is the compatibility
    # default from before backends existed, and it is right. But an
    # install with no backend named AND no Surfer values set has not
    # half-configured Surfer, it has not chosen at all, and saying
    # "the surfer backend is missing SURFER_URL" to somebody who just
    # answered "nowhere yet" is an answer to a question they didn't ask.
    if name.empty? && BACKEND_VALUES['surfer'].all? { |v| ENV[v].to_s.empty? }
      return [warn(t('backend_unset'), t('backend_unset_fix'))]
    end

    name = 'surfer' if name.empty?

    unless DeployBackend::BACKENDS.key?(name)
      return [error(t('backend_unknown', name: name), t('backend_unknown_fix', known: DeployBackend::BACKENDS.keys.join(', ')))]
    end

    missing = BACKEND_VALUES.fetch(name, []).select { |v| ENV[v].to_s.empty? }
    return [ok(t('backend_ok', name: name))] if missing.empty?

    # Not an error: an unconfigured backend is the documented state of a
    # local-only install, where deploy skips out loud and exits 0.
    [warn(t('backend_incomplete', name: name, values: missing.join(', ')), t('backend_incomplete_fix'))]
  end

  # --- online --------------------------------------------------------

  # Everything that needs the network, and nothing that doesn't. Failures
  # here are warnings, never errors: a host being down right now says
  # nothing about whether the config is right.
  def check_online(data)
    require_relative 'feed_http'
    findings = []

    urls = {}
    widgets = data['widgets']
    if widgets.is_a?(Hash)
      widgets.each do |name, conf|
        next unless conf.is_a?(Hash)

        url = conf['feed_url']
        urls[t('widget_label', name: name)] = url if url
      end
    end
    src = dig(data, 'analytics', 'src')
    urls[t('analytics_label')] = src if src

    urls.each do |label, url|
      FeedHttp.get(url)
      findings << ok(t('online_ok', label: label))
    rescue StandardError => e
      findings << warn(t('online_failed', label: label, url: url, message: e.message.to_s.lines.first.to_s.strip))
    end

    findings.concat(check_online_network(data))
    findings
  end

  def check_online_network(data)
    return check_online_bluesky(data) if dig(data, 'bluesky', 'handle')

    instance = dig(data, 'mastodon', 'instance')
    token = ENV['MASTODON_ACCESS_TOKEN'].to_s
    return [] if instance.nil? || token.empty?

    require 'net/http'
    uri = URI("https://#{instance}/api/v1/accounts/verify_credentials")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['User-Agent'] = FeedHttp::USER_AGENT
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |h| h.request(req) }

    case res
    when Net::HTTPSuccess
      handle = (JSON.parse(res.body)['acct'] rescue nil)
      [ok(t('token_ok', handle: handle ? "@#{handle}@#{instance}" : instance))]
    when Net::HTTPUnauthorized
      # The one online finding that IS an error: a revoked token is a
      # standing failure, not a transient one, and it is the exact
      # condition that silently stops every announcement.
      [error(t('token_invalid', instance: instance), t('token_invalid_fix'))]
    else
      [warn(t('token_unchecked', instance: instance, code: res.code))]
    end
  rescue StandardError => e
    [warn(t('token_unchecked', instance: instance, code: e.message.to_s.lines.first.to_s.strip))]
  end

  # The Bluesky half of the same check. Without it, --online said
  # "Announcing as <handle>" on the strength of the config alone -- under
  # a heading that promises the tokens were checked too -- so a revoked
  # app password read as healthy right up until an announcement silently
  # stopped going out. The session endpoint is what the poster itself
  # calls, so this fails exactly when announcing would.
  def check_online_bluesky(data)
    handle = dig(data, 'bluesky', 'handle')
    password = ENV['BLUESKY_APP_PASSWORD'].to_s
    return [] if handle.nil? || password.empty?

    require 'net/http'
    pds = (dig(data, 'bluesky', 'pds') || 'https://bsky.social').to_s.chomp('/')
    uri = URI("#{pds}/xrpc/com.atproto.server.createSession")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['User-Agent'] = FeedHttp::USER_AGENT
    req.body = JSON.generate('identifier' => handle, 'password' => password)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                          open_timeout: 10, read_timeout: 15) { |h| h.request(req) }

    case res
    when Net::HTTPSuccess then [ok(t('token_ok', handle: "@#{handle}"))]
    when Net::HTTPUnauthorized, Net::HTTPBadRequest
      [error(t('token_invalid', instance: handle), t('token_invalid_bluesky_fix'))]
    else
      [warn(t('token_unchecked', instance: handle, code: res.code))]
    end
  rescue StandardError => e
    [warn(t('token_unchecked', instance: handle, code: e.message.to_s.lines.first.to_s.strip))]
  end
end
