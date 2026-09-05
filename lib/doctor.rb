# frozen_string_literal: true

require 'json'
require 'yaml'
# Time.parse, for the queue's dates and the scheduler's heartbeat. Named
# here rather than inherited: it used to arrive through a require that had
# to be removed (see below), and without it the queue read as empty --
# silently, because the rescue that guards a malformed date swallowed the
# NoMethodError just as happily.
require 'time'
require_relative 'site_config'
require_relative 'icons'
require_relative 'i18n'
require_relative 'media_dimensions'
require_relative 'exif_location'
require_relative 'embed'
require_relative 'social_icons'
require_relative 'share_targets'
require_relative 'deploy_backend'
require_relative 'slug'
require_relative 'account_id'
require_relative 'forge_address'
require_relative 'path_glob'
require_relative 'file_size'
# For the one thing doctor cannot answer from config alone: whether a
# menu entry points at an address this archive produces. Sharing the
# set with check rather than building a second one is the point --
# two diagnostics disagreeing about what the build makes is worse than
# one of them staying quiet.
require_relative 'checker'
# NOT require_relative 'publishing': it pulls in the posters, which read
# SiteConfig at LOAD time -- and this is the one command that has to run
# on a config nothing else can load. Requiring it put the raw Psych
# backtrace back on an unreadable site.yml, which is the failure doctor
# exists to explain. The two paths it needs are rebuilt from ROOT here
# instead; they are one File.join each, and this file already owns ROOT.

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
    %w[footer note_heading] => 'Found something here?',
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
    findings.concat(check_extra_css(data, root))
    findings.concat(check_nav(data, root))
    findings.concat(check_chrome_shapes(data))
    findings.concat(check_sidebar(data))
    findings.concat(check_widgets(data))
    findings.concat(check_publishing(data))
    findings.concat(check_scheduler)
    findings.concat(check_deploy_pending)
    findings.concat(check_media_location(root))
    findings.concat(check_tag_icons(data))
    findings.concat(check_social_icons(data))
    findings.concat(check_share(data))
    findings.concat(check_trash(root))
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

  # What the site cannot render without. Deliberately NOT the whole chrome:
  # the templates guard everything whose emptiness is a legitimate answer,
  # and a check that calls a supported state an error is worse than no check
  # -- it teaches its reader to ignore the red.
  #
  # about.html and footer.copyright used to sit here and were exactly that:
  # templates/partials/footer.html.erb drops the copyright line when the
  # value is empty and aside.html.erb does the same with the about card, yet
  # a site that had chosen either was answered with "footer.copyright is
  # missing from config/site.yml" and exit 1. Neither goes unwatched: both
  # are still flagged by check_placeholders -- the copyright through the
  # PLACEHOLDERS hash, about.html through the substring check beside it --
  # so an install that merely has not filled them in yet is still told,
  # as something worth a look rather than as a fault.
  REQUIRED = [
    %w[site title], %w[site short_name], %w[site description], %w[site author],
    %w[banner src]
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

    # site.locale is a SECOND language switch, independent of site.lang,
    # and only ./setup.sh ever kept the two in step. A site localized by
    # hand -- or one whose language was changed in the file afterwards --
    # announces og:locale on every page to everything that reads one, and
    # nothing anywhere said so. A warning, not an error: en_GB under lang
    # en is a deliberate and correct thing to write.
    locale = dig(data, 'site', 'locale').to_s
    lang = dig(data, 'site', 'lang').to_s
    if !locale.empty? && !lang.empty? &&
       locale.split(/[_-]/).first.to_s.downcase != lang.downcase
      findings << warn(t('locale_mismatch', locale: locale, lang: lang), t('locale_mismatch_fix'))
    end

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

    available = PathGlob.under(ROOT, 'locales', '*.yml').map { |f| File.basename(f, '.yml') }.sort
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

  # The value of comments.approval, read the way SiteConfig reads it, so
  # the two cannot drift apart into disagreeing about the same file.
  def approval_value(data)
    dig(data, 'comments', 'approval').to_s.strip.downcase
  end

  # Is moderation actually switched on? Only the modes the engine accepts
  # count: a value it will refuse is a config that publishes nothing at
  # all, not one that moderates.
  def moderated?(data)
    %w[fav favourite favorite].include?(approval_value(data))
  end

  # Did the author MEAN to moderate? Anything other than absent/off, even
  # a value the engine refuses. Used where a green line would contradict
  # a finding check_comments is about to make.
  def moderation_wanted?(data)
    value = approval_value(data)
    !(value.empty? || value == 'off' || value == 'false')
  end

  def check_network(data)
    mastodon = dig(data, 'mastodon', 'instance')
    bluesky = dig(data, 'bluesky', 'handle')
    # Whether the credentials that network needs are actually in env.sh.
    # Under moderation this is not "announcements are on hold": without
    # them PostStats cannot ask which replies were favourited, so no
    # comment can ever be published -- which is why check_comments has to
    # be told, and why the missing-credential line below is an error
    # rather than advice when moderation is on.
    credentials = if mastodon
                    !ENV['MASTODON_ACCESS_TOKEN'].to_s.empty?
                  elsif bluesky
                    !ENV['BLUESKY_APP_PASSWORD'].to_s.empty?
                  else
                    false
                  end
    moderated = moderated?(data)

    findings = []
    if mastodon && bluesky
      # Two networks used to return early, which meant the one command
      # whose whole purpose is to report everything at once reported this
      # and stopped -- a broken comments.approval underneath waited for a
      # second run. The per-network credential lines stay out of the way
      # here (nobody can say which of the two they belong to while the
      # config names both), but check_comments below runs either way.
      findings << error(t('both_networks'), t('both_networks_fix'))
    elsif mastodon
      findings << error(t('mastodon_instance_shape', value: mastodon)) if mastodon.to_s.include?('/')
      if ENV['MASTODON_ACCESS_TOKEN'].to_s.empty?
        findings << if moderated
                      error(t('mastodon_token_missing'), t('mastodon_token_missing_fix'))
                    else
                      warn(t('mastodon_token_missing'), t('mastodon_token_missing_fix'))
                    end
      else
        findings << ok(t('mastodon_ok', instance: mastodon))
      end
      length = dig(data, 'mastodon', 'toot_length')
      findings << error(t('toot_length', value: length.inspect)) if length && !(length.is_a?(Integer) && length.positive?)
      # Same guard as its sibling, because the same kind of mistake is
      # silent in the same way: this number is subtracted from the budget
      # every announcement is composed against, so a string or a negative
      # there cuts every perex short (or lets a toot overflow) with
      # nothing on screen to say why.
      reserved = dig(data, 'mastodon', 'link_length')
      if reserved && !(reserved.is_a?(Integer) && !reserved.negative?)
        findings << error(t('link_length', value: reserved.inspect))
      end
    elsif bluesky
      if ENV['BLUESKY_APP_PASSWORD'].to_s.empty?
        findings << if moderated
                      error(t('bluesky_password_missing'), t('bluesky_password_missing_fix'))
                    else
                      warn(t('bluesky_password_missing'), t('bluesky_password_missing_fix'))
                    end
      else
        findings << ok(t('bluesky_ok', handle: bluesky))
      end
    # "No comments network configured" is a fine thing to say about a site
    # that wanted none. On a site asking for moderation it is a tick
    # printed next to the error saying moderation has nothing to moderate
    # -- and sorted by severity the two land twenty lines apart, so the
    # reader gets the diagnosis and then a green line denying it.
    elsif !moderation_wanted?(data)
      # "No network configured" is the truth about a site that wanted none,
      # and a lie about a site whose owner filled in an instance and a token
      # under a header they left commented out: the section is absent, so
      # every check here agrees the site is fine, and the tick confirms the
      # one belief that is wrong. A credential in env.sh is the evidence
      # that somebody meant to have a network -- nobody issues an access
      # token for a site that announces nothing -- so with one of those in
      # hand, silence stops being an answer.
      stranded = { 'MASTODON_ACCESS_TOKEN' => 'mastodon:', 'BLUESKY_APP_PASSWORD' => 'bluesky:' }
                 .reject { |var, _| ENV[var].to_s.empty? }
      findings << if stranded.empty?
                    ok(t('no_network'))
                  else
                    warn(t('credentials_no_network', vars: stranded.keys.join(', ')),
                         t('credentials_no_network_fix', sections: stranded.values.join(' / ')))
                  end
    end
    findings.concat(check_comments(data, mastodon || bluesky, credentials: credentials))
    findings
  end

  # Moderation has three ways to be configured into silence, and all three
  # end the same way -- a site whose comments simply stop appearing, with
  # nothing on the page to say why. Each gets named here instead.
  #
  # credentials defaults to true so a caller that only has the config in
  # hand still gets every finding the config alone can support.
  def check_comments(data, network, credentials: true)
    approval = approval_value(data)

    # A comments: section that exists and holds nothing moderation reads.
    # `approval` is the only key anything in this engine looks for under
    # it, so anything else there is a misspelling of it -- and a misspelled
    # key does not fail: it reads as absent, moderation quietly does not
    # happen, and every reply is published. That is the one wrong answer
    # this whole feature exists to prevent, arrived at by a typo, and until
    # now doctor handed such a site a clean bill of health. Reported before
    # the empty check below, which would otherwise swallow it.
    if approval.empty?
      section = dig(data, 'comments')
      if section.is_a?(Hash) && section.any?
        return [error(t('approval_key_unknown', keys: section.keys.join(', ')),
                      t('approval_key_unknown_fix'))]
      end
    end

    return [] if approval.empty? || approval == 'off' || approval == 'false'

    # `approval: on` reaches here as "true" -- YAML, not the author. The
    # value in a plain "unknown value X" message would be one they never
    # typed, so that case gets named for what it is.
    return [error(t('approval_boolean'), t('approval_boolean_fix'))] if approval == 'true'

    unless %w[fav favourite favorite].include?(approval)
      # .inspect, not the bare value: "fav" copied out of a web page
      # arrives with a non-breaking space on the end, and interpolated
      # raw it was reported as an unknown `fav` -- a message naming as
      # wrong something that looks exactly right. The quotes are what
      # makes the invisible character visible, so SiteConfig's phrasing
      # of the same complaint wins here too.
      return [error(t('approval_unknown', value: approval.inspect), t('approval_unknown_fix'))]
    end

    # Nothing announces the posts, so no thread exists to approve out of.
    return [error(t('approval_no_network'), t('approval_no_network_fix'))] unless network

    findings = []
    # Only claim the comments are moderated when they can be. With the
    # token empty nothing is ever fetched, comments.json stays empty and
    # the site shows no comments at all -- reported above as the error it
    # is, so the one sentence that must not appear beside it is the green
    # "comments are moderated".
    findings << ok(t('approval_ok')) if credentials
    # The comments now arrive by cron. Without it the site keeps whatever
    # comments.json it last uploaded, forever -- but said unconditionally
    # it was a standing yellow line no site could ever clear, on the sites
    # running the cron exactly as documented as much as on the ones that
    # never set it up. So it is asked the way check_scheduler asks its own
    # question: by looking for evidence the thing has run.
    findings << warn(t('approval_needs_cron'), t('approval_needs_cron_fix')) unless sidebar_ran_recently?
    findings
  end

  # How long the sidebar refresh may be silent before its absence is worth
  # mentioning. The documented cron is every half hour; a whole day is
  # comfortably longer than any sane schedule and still short enough that
  # a stopped cron is caught while an approved comment is still news.
  SIDEBAR_STALE_AFTER = 24 * 3600

  # scripts/refresh-sidebar.sh leaves no heartbeat of its own, but while
  # moderation is on it rewrites public.nosync/comments.json on every
  # single run (scripts/refresh_sidebar.rb) -- so that file's mtime is the
  # heartbeat, and .stats_full_refresh_at backs it up for the runs that do
  # the weekly full pass. Absent or stale, the site really is not getting
  # its approved comments and the warning is earned.
  def sidebar_ran_recently?
    stamps = [File.join(ROOT, 'public.nosync', 'comments.json'),
              File.join(ROOT, '.stats_full_refresh_at')].filter_map do |path|
      File.mtime(path) if File.exist?(path)
    rescue SystemCallError
      nil
    end
    return false if stamps.empty?

    (Time.now - stamps.max) <= SIDEBAR_STALE_AFTER
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

  # Both ways site.extra_css can fail are silent ones: style-src is 'self',
  # so a stylesheet from another origin is dropped by the browser without a
  # word, and a local path with a typo in it 404s just as quietly. Either
  # way the page loads and merely looks undressed, which reads as "the
  # skin doesn't work" rather than "this line is wrong".
  def check_extra_css(data, root)
    entries = dig(data, 'site', 'extra_css')
    entries = [entries] if entries.is_a?(String)
    return [] unless entries.is_a?(Array) && entries.any?

    findings = []
    entries.each do |raw|
      href = raw.to_s.strip
      next if href.empty?

      if !href.start_with?('/') || href.start_with?('//')
        findings << error(t('extra_css_remote', value: href), t('extra_css_remote_fix'))
        next
      end

      # Only /assets/ can be checked against the tree -- anything else is
      # generated by the build or dropped in by hand, and a missing-file
      # claim about it would be a guess.
      next unless href.start_with?('/assets/')

      path = File.join(root, href.sub(%r{\A/}, ''))
      findings << error(t('extra_css_missing', value: href), t('extra_css_missing_fix')) unless File.exist?(path)
    end
    findings << ok(t('extra_css_ok', count: entries.size)) if findings.empty?
    findings
  end

  # A menu item pointing at nothing is as quiet as any other config
  # mistake: the build renders the link, the deploy ships it, and the
  # reader finds the 404. It happens most easily to the entries that were
  # RIGHT once -- a post that got renamed, a tag whose last post was
  # unpublished, a page deleted after the menu was written.
  #
  # Only for a site that has a `nav:` list at all, and the archive is read
  # only then: a site using the derived menu pays nothing for this.
  #
  # The set of addresses is Checker's, not a second copy of it. A doctor
  # that disagreed with check about what the build produces would be worse
  # than one that said nothing -- and this is exactly the kind of list
  # (tags, posts, pages, redirect stubs) that drifts if it is written
  # twice. An `url:` off the site is left alone: pointing at somebody
  # else's page is a legitimate menu item, and whether it answers is
  # `check --online`'s question, not this one.
  def check_nav(data, root)
    entries = data['nav']
    return [] unless entries.is_a?(Array) && entries.any?

    posts = Checker.load_posts(root)
    known = Checker.known_paths(posts)
    # Asked of Checker, because the build only writes a tag page for a tag
    # some post in the STREAM carries: counting a draft's tag as known let
    # doctor tick a menu whose items 404 on every page of the site.
    tags = Checker.stream_tags(posts)

    findings = []
    entries.each do |entry|
      next unless entry.is_a?(Hash)

      label = entry['label'].to_s.strip
      slug = entry['tag'].to_s.strip
      if !slug.empty?
        # Compared through Slug.slugify, because that is what the build
        # names a tag page with. A menu written with the tag's DISPLAY
        # name -- `tag: "Foto Praha"` for a page built at
        # /tag/foto-praha/ -- was told no post carried it and sent its
        # owner looking for a post that had been retagged; the posts were
        # there all along and the entry was simply in the wrong form.
        # Still an error either way: the build addresses the tag exactly
        # as written, so the item does 404 from every page.
        unless tags.include?(slug) || posts.empty?
          folded = Slug.slugify(slug)
          findings << if tags.include?(folded)
                        error(t('nav_tag_display_form', label: label, tag: slug, slug: folded),
                              t('nav_tag_display_form_fix', slug: folded))
                      else
                        error(t('nav_tag_missing', label: label, tag: slug), t('nav_tag_missing_fix'))
                      end
        end
        next
      end

      url = entry['url'].to_s.strip
      next if url.empty?

      # `about` rather than `/about/`. The browser reads it against the
      # page the menu is standing on, so the item points somewhere
      # different from every page -- and from the front page it may even
      # work, which is exactly why it survives being looked at.
      if relative_nav_url?(url)
        fixed = "/#{url.delete_prefix('/')}/"
        findings << error(t('nav_url_relative', label: label, url: url), t('nav_url_relative_fix', url: fixed))
        next
      end

      next unless url.start_with?('/')
      next if url.start_with?('//', '/type/')
      # /assets/ is not automatically sound: it is a real file on disk, and
      # a menu item naming one that is not there 404s on every page of the
      # site while doctor called the menu fine.
      if url.start_with?('/assets/')
        next if nav_asset_present?(root, url)

        findings << error(t('nav_url_missing', label: label, url: url), t('nav_asset_missing_fix'))
        next
      end
      # Nothing to judge against on an archive with no posts in it yet.
      next if posts.empty?
      # A menu address is a URL, not a path: `/o-mne/#kontakt` is an anchor
      # on a page that exists and `/search/?q=foto` is a query the search
      # page reads. Judged raw, both were reported as addresses the site
      # does not answer at, the install failed, and the fix text sent the
      # owner looking for a post that had been "renamed or deleted" -- a
      # post that was never renamed. check has split these off before
      # comparing since it was written; the /assets/ branch above does it
      # too. This is the one place that did not.
      path = url.split('#').first.to_s.split('?').first.to_s
      # A bare "#kontakt" or "?q=x" is a same-page address: there is
      # nothing left to look up and nothing wrong with it.
      next if path.empty?
      next if known.include?(path) || known.include?("#{path}/")

      findings << error(t('nav_url_missing', label: label, url: url), t('nav_url_missing_fix'))
    end
    findings << ok(t('nav_ok', count: entries.size)) if findings.empty? && !posts.empty?
    findings
  end

  # A menu item's address is a URL, and the raw string is not a path: a
  # #fragment, a ?query and percent escapes all belong in one and none of
  # them belong on disk. And the file the address serves may be one the
  # BUILD generates (colors.css; the banner seeded out of defaults/), so
  # what the site actually answers -- public.nosync -- counts as present
  # too. Judged raw, doctor flagged five working menu items on one config
  # and failed the install for them.
  def nav_asset_present?(root, url)
    path = url.split('#').first.to_s.split('?').first.to_s.delete_prefix('/')
    return false if path.empty?

    [path, Checker.percent_decoded(path)].uniq.any? do |form|
      File.exist?(File.join(root, form)) || File.exist?(File.join(root, 'public.nosync', form))
    end
  end

  # An address that is neither on this site nor anywhere else -- it only
  # means something relative to wherever it is written, which for a menu
  # is every page at a different depth.
  def relative_nav_url?(url)
    return false if url.start_with?('/', '#')
    return false if url.include?('://')

    !url.start_with?('mailto:', 'tel:')
  end

  # Where the toots widget would ask, given the config as written -- the
  # same fallback the fetcher uses (lib/mastodon_fetcher.rb), so doctor and
  # the fetcher cannot disagree about whether a site has an instance.
  def instance_for_toots(data, conf)
    (conf['instance'] || dig(data, 'mastodon', 'instance')).to_s.strip
  end

  # And who the Bluesky card would ask about. The fetcher takes
  # widgets.bluesky.handle and falls back to bluesky.handle, because a site
  # that announces to Bluesky has already said its handle once -- so a
  # flat WIDGET_REQUIRED entry would have cried wolf on every site that
  # fills it in the second way. Without either, the card is drawn on every
  # page, never fetched and never filled, and doctor said the widgets were
  # all in order.
  def handle_for_bluesky(data, conf)
    (conf['handle'] || dig(data, 'bluesky', 'handle')).to_s.strip
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

  # Everything the config says that the engine cannot use -- read from
  # SiteConfig::Chrome, the same function the build warns from, so the two
  # cannot name a different set of keys. Before this, doctor knew about
  # three list keys and nothing else: a widget name with a typo in it took
  # the sidebar off every page of the site while this said the config was
  # healthy, and an `about:` written as a list ended the build in a
  # TypeError out of an ERB template.
  COMPLAINT_TEXT = {
    not_a_list: %w[list_shape list_shape_fix],
    not_a_map: %w[map_shape map_shape_fix],
    unknown_widget: %w[widget_unknown widget_unknown_fix],
    widget_shape: %w[widget_shape widget_shape_fix],
    nav_item: %w[nav_item_shape nav_item_shape_fix],
    not_text: %w[text_shape text_shape_fix]
  }.freeze

  def check_chrome_shapes(data)
    SiteConfig::Chrome.complaints(data).map do |kind, what|
      text_key, fix_key = COMPLAINT_TEXT.fetch(kind, %w[list_shape list_shape_fix])
      error(t(text_key, key: what, name: what, index: what), t(fix_key))
    end
  end

  # A column reserved on every page with nothing to put in it. Since 1.4 the
  # build stops drawing it, so this is the sentence that says why the site
  # changed shape after an upgrade -- and names the switch that says it on
  # purpose.
  def check_sidebar(data)
    return [] unless SiteConfig::Chrome.map(data, 'layout').fetch('sidebar', true)

    cards = SiteConfig::Chrome.widgets(data).size
    cards += 1 unless SiteConfig::Chrome.map(data, 'about')['html'].to_s.strip.empty?
    return [warn(t('sidebar_empty'), t('sidebar_empty_fix'))] if cards.zero?

    [ok(t('sidebar_ok', count: cards))]
  end

  def check_widgets(data)
    widgets = data['widgets']
    return [] unless widgets.is_a?(Hash)

    findings = []
    widgets.each do |name, conf|
      # Both of these are named by check_chrome_shapes, from the same list
      # the build warns from; naming them twice would only make the report
      # longer, not truer.
      next unless conf.is_a?(Hash) && SiteConfig::Chrome::CARDS.include?(name)

      required = WIDGET_REQUIRED[name]
      if required && conf[required].to_s.empty?
        findings << error(t('widget_incomplete', name: name, key: required))
      elsif name == 'toots' && !AccountId.plausible?(conf['account_id'])
        # The id, not the @handle -- the single most common way this
        # widget is filled in wrong, and it fails silently. What counts
        # as an id (Mastodon numbers, GoToSocial ULIDs, Pleroma flakes)
        # lives in lib/account_id.rb, shared with the style wizard.
        findings << error(t('widget_account_id', value: conf['account_id'].inspect), t('widget_account_id_fix'))
      end

      # Asked separately rather than as another branch above: WHO and WHERE
      # are two different mistakes and a config can make both at once. As an
      # elsif this hid the @handle error behind the missing instance, which
      # is a report that fixes one thing and then surprises you with the
      # next -- and the reason a test caught it here is that it had one.
      if name == 'bluesky' && handle_for_bluesky(data, conf).empty?
        findings << error(t('widget_incomplete', name: name, key: 'handle'))
      end

      if name == 'toots' && instance_for_toots(data, conf).empty?
        # The account id alone does not say WHERE to ask. The fetcher takes
        # widgets.toots.instance and falls back to mastodon.instance, so a
        # site with neither has a widget that can never fill itself -- and
        # the only symptom is an empty card, which looks exactly like an
        # author who has not posted lately.
        findings << error(t('widget_toots_instance'), t('widget_toots_instance_fix'))
      end

      # The commits widget's own two settings, checked by the same rules the
      # fetcher uses (lib/forge_address.rb) rather than by a second copy of
      # them. Each mistake here ends as an empty card, and an empty card is
      # indistinguishable from an author who has not pushed lately.
      if name == 'commits'
        if ForgeAddress.username(conf['username']).nil?
          findings << error(t('widget_username', value: conf['username'].inspect), t('widget_username_fix'))
        end
        instance = conf['instance'].to_s.strip
        unless instance.empty?
          if ForgeAddress.base(instance).nil?
            findings << error(t('widget_instance', value: conf['instance'].inspect), t('widget_instance_fix'))
          elsif ForgeAddress.path_under_host?(instance)
            # A forge two directories deep is unusual, not impossible, so
            # this is a look rather than a refusal.
            findings << warn(t('widget_instance_repo', value: conf['instance'].inspect), t('widget_instance_repo_fix'))
          end
        end
      end

      findings << warn(t('widget_heading', name: name)) if conf['heading'].to_s.empty?
      limit = conf['limit']
      findings << error(t('widget_limit', name: name, value: limit.inspect)) if limit && !(limit.is_a?(Integer) && limit.positive?)
    end
    drawable = SiteConfig::Chrome.widgets(data).size
    findings << ok(t('widgets_ok', count: drawable)) if findings.empty? && drawable.positive?
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

  # Is anything actually running the queue? A scheduled post that never
  # publishes looks, from inside, exactly like a scheduled post whose time
  # has not come -- so the engine could not tell, and neither could the
  # author: a post sits past its date and nothing anywhere says why. The
  # cron writes a heartbeat on every tick; this reads it.
  #
  # Only ever speaks when there IS a queue. A site that schedules nothing
  # needs no scheduler, and telling it otherwise would be noise on every
  # single run.
  SCHEDULER_STALE_AFTER = 2 * 3600

  # The site owes a deploy: something published and the upload that should
  # have followed did not happen. The marker is written by every path that
  # can leave that debt -- the manual publish and the cron alike -- but the
  # only thing that ever READ it was the scheduled run, which is optional.
  # On an install without that cron the message said "the next scheduled
  # run will retry it" about a run that does not exist, and nothing else
  # mentioned the debt again.
  def check_deploy_pending
    marker = File.join(ROOT, '.deploy-pending')
    return [] unless File.exist?(marker)

    since = begin
      Time.parse(File.read(marker).strip)
    rescue StandardError
      File.mtime(marker)
    end
    [error(t('deploy_pending', ago: humanize_age(Time.now - since)), t('deploy_pending_fix'))]
  end

  def check_scheduler
    queue = scheduled_posts
    return [] if queue.empty?

    last = scheduler_last_run
    overdue = queue.count { |date| date <= Time.now }

    if last.nil?
      # Nothing has ever run it here. With posts already waiting, that is
      # the difference between a blog that publishes itself and one that
      # does not -- said as an error when something is already late.
      note = t('scheduler_never', count: queue.size)
      return [overdue.positive? ? error(note, t('scheduler_fix')) : warn(note, t('scheduler_fix'))]
    end

    age = Time.now - last
    if age <= SCHEDULER_STALE_AFTER
      # A live runner and a post still sitting past its date is the worst
      # of the three states, and it used to be the only one that read as
      # ✅: something IS running the queue, so the heartbeat is fresh --
      # and the post is not going out, tick after tick, because every
      # attempt fails. "The queue has 1 post waiting and something ran it
      # 0 minutes ago" was true and told nobody anything.
      return [error(t('scheduler_overdue', count: overdue, ago: humanize_age(age)),
                    t('scheduler_overdue_fix'))] if overdue.positive?

      return [ok(t('scheduler_ok', count: queue.size, ago: humanize_age(age)))]
    end

    stale = t('scheduler_stale', ago: humanize_age(age), count: queue.size)
    [overdue.positive? ? error(stale, t('scheduler_fix')) : warn(stale, t('scheduler_fix'))]
  end

  # Dates of everything waiting in the queue, read the way the cron reads
  # it: a scheduled post is a draft carrying the flag, not a state of its
  # own.
  # Same two paths Publishing owns, rebuilt from ROOT rather than required
  # (see the note at the top of this file).
  def content_dir
    File.join(ROOT, 'content.nosync', 'posts')
  end

  def scheduler_last_run
    path = File.join(ROOT, '.last-scheduled-run')
    return nil unless File.exist?(path)

    Time.parse(File.read(path).strip)
  rescue StandardError
    begin
      File.mtime(path)
    rescue StandardError
      nil
    end
  end

  def scheduled_posts
    PathGlob.under(content_dir, '*', '*.json').filter_map do |path|
      post = JSON.parse(File.read(path, encoding: 'utf-8'))
      next unless post.is_a?(Hash) && post['state'] == 'draft' && post['scheduled']

      Time.parse(post['date'].to_s)
    rescue JSON::ParserError, ArgumentError, TypeError, SystemCallError
      # A post that cannot be read or dated is not a scheduling problem
      # and doctor has other checks for it -- but the rescue stays narrow
      # on purpose: a broad one here once hid a missing require, and the
      # queue silently read as empty.
      next
    end
  end

  def humanize_age(seconds)
    hours = (seconds / 3600).floor
    return t('age_minutes', count: (seconds / 60).floor) if hours < 1
    return t('age_hours', count: hours) if hours < 48

    t('age_days', count: (hours / 24).floor)
  end

  # --- media ---------------------------------------------------------

  # Where a photo was taken, in photos already published. New ones are
  # cleaned on the way into the archive (lib/exif_location.rb), but an
  # archive that existed before that has whatever its phone wrote, and
  # nothing about upgrading an engine should silently rewrite pictures
  # somebody already put on the web. So: counted here, cleaned only when
  # asked -- `./blog.sh doctor --strip-location`.
  #
  # Cheap enough to run every time: only the first pages of each file are
  # read, and 2962 photos took just over a second on the archive this was
  # written against.
  def check_media_location(root)
    found = located_media(root)
    return [] if found.nil?
    return [ok(t('media_location_clean'))] if found.empty?

    [warn(t('media_location', count: found.size), t('media_location_fix'))]
  end

  # nil when there is nothing to look at -- a fresh install has nothing to
  # say about it, and a green line claiming otherwise is noise.
  #
  # THE SOURCES, not the build. public.nosync is made from these two trees on
  # every build, so cleaning it achieves nothing: the next rebuild copies the
  # coordinates straight back out of the source, and in between doctor
  # reported the site clean. (Scanning it also counted every built photo
  # twice, once in each tree.) Cleaning the sources is what lasts -- the
  # build then carries it into public.nosync, which is what emit_copy's
  # modification-time check exists for.
  #
  # assets/ belongs here as much as media.nosync does: it is the documented
  # place a photo goes when it is part of the site rather than of a post --
  # the bio picture in the sidebar of every page comes from there.
  def located_media(root)
    dirs = [File.join(root, 'media.nosync'), File.join(root, 'assets')]
           .select { |d| File.directory?(d) }
    return nil if dirs.empty?

    dirs.flat_map do |dir|
      # By the first two bytes, not by the name. Every other half of this
      # feature is content-based -- ExifLocation.jpeg? tests the marker,
      # PostWriter strips whatever the bytes say is a JPEG, and
      # MediaDimensions::SYNONYMS lists .jpe and .jfif as spellings the
      # engine keeps on purpose -- so a photograph filed under one of
      # those was invisible to BOTH this report and its fixer, and doctor
      # said "no photo carries where it was taken" about an archive that
      # had some. Two bytes per file to ask; present? still reads its
      # 256 kB only for the files that really are JPEGs.
      PathGlob.under(dir, '**', '*').select do |path|
        File.file?(path) && ExifLocation.jpeg?(path) && ExifLocation.present?(path)
      end
    end
  rescue StandardError
    nil
  end

  # --- deploy --------------------------------------------------------

  # The icons tags may carry. Three ways to get this wrong, and all three
  # are silent: a name the engine does not have draws nothing, an entry
  # without a tag belongs to nobody, and an SVG written to another scale
  # sits crooked in a badge the size of two lines of text.
  def check_tag_icons(data)
    entries = SiteConfig::Chrome.list(data, 'tag_icons')
    return [] if entries.empty?

    # Sixty-odd names on one line is a wall, and this message exists to be
    # read at the moment somebody typed a name that is nearly right --
    # `bicycle` for `bike`. Eight to a row, indented under the sentence.
    known = Icons::NAMES.each_slice(8).map { |row| row.join(', ') }.join(",\n     ")
    findings = entries.filter_map do |entry|
      next warn(I18n.t('doctor.tag_icon_shape')) unless entry.is_a?(Hash)
      next warn(I18n.t('doctor.tag_icon_no_tag')) if entry['tag'].to_s.strip.empty?

      tag = entry['tag'].to_s
      if entry['icon_svg']
        svg = entry['icon_svg'].to_s
        # Icons.own_svg?, not a test of doctor's own -- the build refuses
        # exactly what this line calls undrawable, and the two used to
        # disagree in both directions at once.
        next warn(I18n.t('doctor.tag_icon_not_svg', tag: tag)) unless Icons.own_svg?(svg)
        next warn(I18n.t('doctor.tag_icon_scale', tag: tag)) unless svg.match?(/viewBox\s*=\s*["\']0 0 24 24/)
        # Said out loud rather than silently swallowed. The strip runs at
        # render whatever doctor thinks, so the page is safe either way --
        # but an icon that arrives carrying a handler is an icon somebody
        # copied from somewhere, and its owner is the one person who can
        # decide whether to keep using that source.
        next warn(I18n.t('doctor.tag_icon_stripped', tag: tag)) if Embed.without_scripts(svg) != svg
      elsif !Icons.find(entry['icon'])
        next warn(I18n.t('doctor.tag_icon_unknown', tag: tag, icon: entry['icon'].to_s,
                                                    known: known))
      end
      nil
    end
    return findings unless findings.empty?

    [ok(I18n.t('doctor.tag_icons_ok', count: entries.length))]
  end

  # A footer icon the engine does not have draws NOTHING -- social_icon
  # answers '' and the link goes out with an empty space where the icon
  # belongs. The tag icons have been checked since they existed; these
  # never were, and a typo in `icon:` is silent on the page and silent
  # here.
  def check_social_icons(data)
    SiteConfig::Chrome.list(data, 'social').filter_map { |entry| social_icon_finding(entry) }
  end

  # The footer's icons, given the same three questions the tag icons have
  # been asked since they existed. They are the identical field four lines
  # of code apart, and this one was answering none of them: junk in
  # `icon_svg` printed as words in the footer of every page, an entry with
  # no icon at all published an empty unclickable anchor, and an entry that
  # was not a mapping walked past here and took the BUILD down instead --
  # which is precisely the traceback docs/install.md promises doctor names
  # first.
  def social_icon_finding(entry)
    return warn(I18n.t('doctor.social_shape')) unless entry.is_a?(Hash)

    name = entry['name'].to_s
    if entry['icon_svg']
      svg = entry['icon_svg'].to_s
      return warn(I18n.t('doctor.social_icon_not_svg', name: name)) unless Icons.own_svg?(svg)
      return warn(I18n.t('doctor.social_icon_scale', name: name)) unless svg.match?(/viewBox\s*=\s*["']0 0 24 24/)
      return warn(I18n.t('doctor.social_icon_stripped', name: name)) if Embed.without_scripts(svg) != svg

      return nil
    end

    icon = entry['icon'].to_s
    return warn(I18n.t('doctor.social_icon_missing', name: name)) if icon.empty?
    return nil if SocialIcons::NAMES.include?(icon) || Icons.find(icon)

    # ⚠️ Both sets, because both are now accepted. Listing only the brand
    # marks told somebody who asked for `globe` -- which the engine draws
    # -- to go and write their own SVG for it.
    warn(I18n.t('doctor.social_icon_unknown', name: name, icon: icon,
                                              known: (SocialIcons::NAMES + Icons::NAMES)
                                                     .each_slice(8).map { |row| row.join(', ') }
                                                     .join(",\n     ")))
  end

  # A share list naming something the engine cannot draw is dropped in
  # silence -- the same hole check_social_icons was written to close, one
  # key over.
  def check_share(data)
    SiteConfig::Chrome.list(data, 'share').filter_map do |name|
      value = name.to_s.strip.downcase
      next if value.empty? || ShareTargets::NAMES.include?(value)

      warn(I18n.t('doctor.share_unknown', name: name.to_s,
                                          known: ShareTargets::NAMES.join(', ')))
    end
  end

  # What is in the trash, said out loud once in a while. Not an error: a
  # trash with posts in it is a trash doing its job, and `restore` is the
  # reason it exists. But nothing on the site ever mentions it, so it grew
  # for years on the installation this engine was built around and the only
  # way to see that was `du` on the server. A note here is how somebody
  # remembers the command exists.
  def check_trash(root)
    dir = File.join(root, 'trash')
    return [] unless Dir.exist?(dir)

    # By directory rather than by post.json: `check --repair` sets a stray
    # media file aside in here, without a post beside it, and doctor said
    # nothing at all about a trash holding only those.
    held = Dir.children(dir).sort.flat_map do |name|
      path = File.join(dir, name)
      next [] unless File.directory?(path)
      next [path] unless name.match?(/\A\d{4}\z/)

      Dir.children(path).map { |slug| File.join(path, slug) }.select { |d| File.directory?(d) }
    end
    return [] if held.empty?

    bytes = PathGlob.under(dir, '**', '*').sum { |f| File.file?(f) ? File.size(f) : 0 }
    [warn(I18n.t('doctor.trash_holds', count: held.length, size: FileSize.human(bytes)))]
  end

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
    # A backend can be fully configured and still refuse to run: an
    # unmatched quote in its extra switches aborts every deploy. doctor
    # exists so that the state of an install is known before the deploy
    # that needs it, so it must not tick a line that will stop on sight.
    backend = DeployBackend::BACKENDS[name]
    trouble = backend.respond_to?(:problem) ? backend.problem : nil
    return [error(trouble, I18n.t('cli.deploy_args_fix'))] if trouble

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

    # The commits widget identifies itself by instance + username rather
    # than by a feed_url, so the loop above never saw it -- the one widget
    # 1.4 added was the one --online did not reach. Its address is built the
    # way the fetcher builds it (lib/commits_fetcher.rb), not by a second
    # copy of the rule, and only for a forge: GitHub is the default and
    # answers whether or not the username exists, so asking it proves
    # nothing a config check has not already proven.
    commits = dig(data, 'widgets', 'commits')
    if commits.is_a?(Hash)
      instance = commits['instance'].to_s.strip
      user = ForgeAddress.username(commits['username'])
      base = instance.empty? ? nil : ForgeAddress.base(instance)
      if base && user
        urls[t('widget_label', name: 'commits')] =
          "#{base}/api/v1/users/#{user}/activities/feeds?only-performed-by=true&limit=1"
      end
    end

    urls.each do |label, url|
      FeedHttp.get(url)
      findings << ok(t('online_ok', label: label))
    rescue StandardError => e
      findings << warn(t('online_failed', label: label, url: url, message: e.message.to_s.lines.first.to_s.strip))
    end

    findings.concat(check_online_network(data))
    findings.concat(check_online_thread_readable(data))
    findings.concat(check_online_approval(data))
    findings
  end

  # Whether the credentials can actually see which replies the author
  # favourited -- the one moderation failure that looks like success from
  # every other angle (see PostStats.approval_probe).
  def check_online_approval(data)
    approval = dig(data, 'comments', 'approval').to_s.strip.downcase
    return [] unless %w[fav favourite favorite].include?(approval)

    # The one require of lib/post_stats.rb used to sit inside
    # check_online_thread_readable, behind its early returns -- so on a
    # site where that check bows out, this one died on an uninitialized
    # constant instead of answering the question it exists for. It is
    # required here as well, where it is used.
    require_relative 'post_stats'

    # The newest announcement the token can actually be tested against: a
    # Mastodon entry on the configured instance (a foreign one is refused
    # by approval_probe, and testing there is meaningless anyway), or any
    # Bluesky entry. Falling back to the plain newest only when there is
    # no same-host candidate, so the message is still about a real post.
    entries = PostStats.entries
    testable = entries.reject { |e| e[:kind] == :mastodon && PostStats.foreign_host?(PostStats.parse_toot_url(e[:key])&.dig(:instance)) }
    entry = (testable.max_by { |e| e[:date].to_s } || entries.max_by { |e| e[:date].to_s })
    return [warn(t('approval_probe_nothing'))] unless entry

    case PostStats.approval_probe(entry)
    when :ok then [ok(t('approval_probe_ok'))]
    else [error(t('approval_probe_blind'), t('approval_probe_blind_fix'))]
    end
  rescue StandardError => e
    [warn(t('approval_probe_failed', message: e.message.to_s.lines.first.to_s.strip))]
  end

  # Can a VISITOR's browser read the thread? With moderation off that is
  # the whole mechanism: the page fetches /context itself, with no token,
  # because there is no way to put one in a browser. Mastodon answers such
  # a request; GoToSocial refuses it outright (every one of its four
  # require* flags is on, with nothing to configure), and a Mastodon in
  # secure mode does the same -- so the comments section stays empty and
  # the page says nothing about why.
  #
  # Asked as a CAPABILITY, never by the name of the software: "is this
  # server one that lets anonymous readers in" is the question, and
  # nodeinfo does not answer it.
  def check_online_thread_readable(data)
    return [] unless dig(data, 'mastodon', 'instance')
    return [] if SiteConfig.comments_approval # moderated: a cron reads it WITH a token

    sample = newest_announced_post
    return [] unless sample

    require_relative 'post_stats'
    parsed = PostStats.parse_toot_url(sample)
    return [] unless parsed

    require 'net/http'
    # The same scheme the announcement itself carries, because that is the
    # address a reader's browser would go to.
    scheme = sample.to_s.start_with?('http://') ? 'http' : 'https'
    uri = URI("#{scheme}://#{parsed[:instance]}/api/v1/statuses/#{parsed[:id]}/context")
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = FeedHttp::USER_AGENT
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                          open_timeout: 10, read_timeout: 15) { |h| h.request(req) }

    case res
    when Net::HTTPSuccess
      [ok(t('thread_public', instance: parsed[:instance]))]
    when Net::HTTPUnauthorized, Net::HTTPForbidden
      [error(t('thread_closed', instance: parsed[:instance]), t('thread_closed_fix'))]
    else
      [warn(t('thread_unchecked', instance: parsed[:instance], code: res.code))]
    end
  rescue StandardError => e
    [warn(t('thread_unchecked', instance: dig(data, 'mastodon', 'instance'),
                                code: e.message.to_s.lines.first.to_s.strip))]
  end

  # The most recent published post that carries an announcement address --
  # the one a reader is most likely to be looking at.
  def newest_announced_post
    PathGlob.under(content_dir, '*', '*.json').sort.reverse_each do |file|
      post = begin
        JSON.parse(File.read(file, encoding: 'utf-8'))
      rescue StandardError
        next
      end
      next unless post.is_a?(Hash) && post['state'].to_s != 'draft'
      next if post['mastodon_url'].to_s.empty?

      return post['mastodon_url']
    end
    nil
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
