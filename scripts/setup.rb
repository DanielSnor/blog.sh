#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/setup.rb -- the core setup wizard, run via ./setup.sh.
#
# What it is for: the documented way to configure this engine is to copy
# two files and edit them, and config/site.yml.example is 277 lines of
# YAML. That is a fair ask of someone who edits YAML for a living and a
# wall for everybody else -- indentation that must be spaces, values that
# need quoting for reasons the file can't show you, a numeric Mastodon
# account id you have to go and look up, image dimensions you have to
# read off the file yourself.
#
# So the wizard's value is NOT that it types YAML for you. It is that
# everything it asks about, it can check: a timezone against the machine's
# own database, a URL's shape, a Mastodon instance and token against the
# instance itself (and it reads the numeric account id back out so you
# never have to find it), a deploy target by looking at it. A question
# whose answer is verified the moment it is given is worth ten pages of
# documentation about how to answer it.
#
# Three rules it holds to:
#
#   Nothing is written until the end. Every answer is collected in
#   memory, shown back as a diff, and confirmed once. Ctrl-C at any point
#   leaves the install exactly as it was found -- which matters most on
#   the re-run, over a config somebody already has a site running on.
#
#   Every question can be skipped. The shipped example is a working site
#   on purpose ("you can leave editing it for later" -- docs/install.md),
#   and a wizard that demanded fifteen answers before letting go would be
#   worse than the two cp commands it replaces. Enter keeps what is there.
#
#   It never invents. The writing goes through ConfigWriter, which
#   substitutes values into the documented template and leaves every
#   comment where it was -- see lib/config_writer.rb for why that is the
#   whole design and not an implementation detail.

require 'yaml'
require_relative '../lib/yaml_compat'
require_relative '../lib/site_config'

ROOT = File.expand_path('..', __dir__)
SITE_YML = File.join(ROOT, 'config', 'site.yml')
SITE_YML_EXAMPLE = File.join(ROOT, 'config', 'site.yml.example')
ENV_SH = File.join(ROOT, 'env.sh')
ENV_SH_EXAMPLE = File.join(ROOT, 'env.sh.example')

# Same dance as scripts/doctor.rb, and for the same reason: the wizard
# has to run ON a config that may be missing or broken, so the language
# comes out of the raw file rather than through SiteConfig, which would
# abort on the very thing the user came here to fix.
existing = begin
  loaded = File.exist?(SITE_YML) ? YamlCompat.load_file(SITE_YML) : nil
  loaded.is_a?(Hash) ? loaded : {}
rescue StandardError
  {}
end

require_relative '../lib/i18n'
I18n.force_lang(existing.dig('site', 'lang').to_s.empty? ? 'en' : existing.dig('site', 'lang').to_s)

require_relative '../lib/tui'
require_relative '../lib/config_writer'
require_relative '../lib/wizard'
require_relative '../lib/version'
require_relative '../lib/site_header'

def t(key, **vars)
  I18n.t("setup.#{key}", **vars)
end

# The prompt loop, the menu and the review-and-write moment live in
# lib/wizard.rb, shared with ./style.sh -- see the reasoning there.
def ask(label, current, hint: nil, suggested: false)
  Wizard.ask(label, current, hint: hint, suggested: suggested)
end

def ask_valid(label, current, hint: nil, suggested: false, &check)
  Wizard.ask_valid(label, current, hint: hint, suggested: suggested, &check)
end

def choose(label, options, current_index: 0)
  Wizard.choose(label, options, current_index: current_index)
end

def confirm(prompt)
  Wizard.confirm(prompt)
end

# --- detection -------------------------------------------------------

# The machine's own zone, so the timezone question arrives already
# answered on the overwhelmingly common setup. Time.now.zone gives an
# abbreviation ("CEST"), which is not what site.timezone takes -- the
# IANA name is what /etc/localtime points at.
def detect_timezone
  from_env = ENV['TZ'].to_s
  return from_env if valid_timezone?(from_env)

  link = File.readlink('/etc/localtime')
  zone = link[%r{zoneinfo/(.+)\z}, 1]
  valid_timezone?(zone) ? zone : nil
rescue StandardError
  nil
end

def valid_timezone?(zone)
  zone = zone.to_s
  return false if zone.empty?
  return false unless zone.match?(SiteConfig::ZONE_NAME_RE)

  zone == 'UTC' || File.exist?(File.join('/usr/share/zoneinfo', zone))
end

# A machine set to UTC is almost always a server, and its zone is a fact
# about the datacenter, not about the person answering -- offered as a
# default it gets accepted, and every post is then timestamped hours off.
# The language just chosen for the wizard is the better witness there;
# English narrows nothing down, so it falls back to the detection.
ZONE_FOR_LANG = { 'cs' => 'Europe/Prague', 'de' => 'Europe/Berlin' }.freeze

def suggest_timezone
  detected = detect_timezone
  return detected unless detected.nil? || detected == 'UTC' || detected.start_with?('Etc/')

  ZONE_FOR_LANG[I18n.lang] || detected
end

LOCALE_FOR = { 'en' => 'en_US', 'cs' => 'cs_CZ', 'de' => 'de_DE' }.freeze

def available_languages
  Dir.glob(File.join(ROOT, 'locales', '*.yml')).map { |f| File.basename(f, '.yml') }.sort
end

# --- network checks --------------------------------------------------

# Best effort, always: a wizard that refuses to continue because a host
# is down right now would be unusable on a train. Every one of these
# reports what it found and moves on.
def verify_mastodon(instance, token)
  require 'net/http'
  require 'json'
  uri = URI("https://#{instance}/api/v1/accounts/verify_credentials")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['User-Agent'] = BlogSh.user_agent
  res = Tui.spinner(t('checking_token')) do
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 12) { |h| h.request(req) }
  end

  case res
  when Net::HTTPSuccess
    account = JSON.parse(res.body)
    { id: account['id'], handle: account['acct'] }
  when Net::HTTPUnauthorized
    # Distinguished from every other failure below, because the two
    # deserve opposite advice: a 401 is a standing verdict on the token
    # itself, while anything else may be the network having a bad minute.
    { error: t('token_rejected'), rejected: true }
  else
    { error: t('token_unchecked', code: res.code) }
  end
rescue StandardError => e
  { error: t('token_unchecked', code: e.message.to_s.lines.first.to_s.strip) }
end

# --- the interview ---------------------------------------------------

def run
  # Whether this is a first run decides more than the greeting: it is
  # what tells the template's placeholders apart from answers somebody
  # actually gave.
  @fresh = !File.exist?(SITE_YML)

  puts SiteHeader.render(tool: './setup.sh')
  puts
  puts t('intro')
  puts
  puts Tui.paint(t('intro_skip'), :dim)
  puts Tui.paint(t('intro_expert'), :dim)
  puts

  site = ConfigWriter::YamlFile.new(SITE_YML, template: SITE_YML_EXAMPLE)
  env = ConfigWriter::EnvFile.new(ENV_SH, template: ENV_SH_EXAMPLE)
  current = current_values

  # Address and deploy back to back on purpose: "where the site lives"
  # and "where the build goes" are one theme, and the comments network is
  # an optional integration -- it goes last, like in the config file.
  ask_language(site, current)
  ask_identity(site, current)
  ask_page_size(site, current)
  ask_address(site, env, current)
  ask_deploy(env, current)
  tell_about_scheduler
  ask_network(site, env, current)

  review_and_write(site, env)
end

# Read once, up front: every prompt's default comes from here, and on a
# first run these are the template's own values, since that is what the
# site would say if left alone.
def current_values
  data = begin
    path = File.exist?(SITE_YML) ? SITE_YML : SITE_YML_EXAMPLE
    YamlCompat.load_file(path) || {}
  rescue StandardError
    {}
  end
  data.is_a?(Hash) ? data : {}
end

# The template's own values, so a prompt can tell a placeholder from an
# answer: on a fresh run every default is the template's, and on a re-run
# whatever still matches it ("Your Name...", example.com) is exactly what
# nobody has answered yet. Those defaults are shown as suggestions, not
# as facts somebody chose.
def template_values
  @template_values ||= begin
    data = YamlCompat.load_file(SITE_YML_EXAMPLE)
    data.is_a?(Hash) ? data : {}
  rescue StandardError
    {}
  end
end

def template?(current, *keys)
  value = current.dig(*keys)
  !value.nil? && value == template_values.dig(*keys)
end

# First, and in a menu rather than a prompt, because the answer decides
# what language the REST of the wizard speaks -- and a question about
# language is the one question that cannot be asked in the language the
# user has not chosen yet. The options name themselves.
LANGUAGE_NAMES = { 'en' => 'English', 'cs' => 'Čeština', 'de' => 'Deutsch' }.freeze

def ask_language(site, current)
  langs = available_languages
  return if langs.size < 2

  now = current.dig('site', 'lang').to_s
  options = langs.map { |code| [code, LANGUAGE_NAMES.fetch(code, code)] }
  # A missing site.lang means English everywhere else in the engine; here
  # langs.index('') was nil and the fallback to 0 offered whatever sorts
  # first -- Czech. Esc and an unusable piped answer both keep the OFFERED
  # option, so two "leave it alone" keystrokes switched the install's
  # language and rebuilt the public site in it.
  index = langs.index(now) || langs.index('en') || 0
  chosen = choose('Language / Jazyk / Sprache', options, current_index: index)

  I18n.force_lang(chosen)
  site.set(%w[site lang], chosen)
  locale = LOCALE_FOR[chosen]
  site.set(%w[site locale], locale) if locale
end

def ask_identity(site, current)
  puts Tui.paint(t('section_identity'), :bold)
  puts

  title = ask(t('q_title'), current.dig('site', 'title'), hint: t('h_title'),
              suggested: template?(current, 'site', 'title'))
  site.set(%w[site title], title)

  short = ask(t('q_short_name'), current.dig('site', 'short_name'), hint: t('h_short_name'),
              suggested: template?(current, 'site', 'short_name'))
  site.set(%w[site short_name], short)

  desc = ask(t('q_description'), current.dig('site', 'description'), hint: t('h_description'),
             suggested: template?(current, 'site', 'description'))
  site.set(%w[site description], desc)

  author = ask(t('q_author'), current.dig('site', 'author'), hint: t('h_author'),
               suggested: template?(current, 'site', 'author'))
  site.set(%w[site author], author)

  # On a first run the "current" value is the template's Europe/Prague,
  # which is a placeholder rather than an answer -- so the suggestion
  # (the machine's zone, unless that is a server's UTC) wins there. On a
  # re-run the config's value is a real decision somebody made, and
  # detection must not quietly overrule it.
  config_zone = current.dig('site', 'timezone')
  zone = @fresh ? (suggest_timezone || config_zone) : (config_zone || suggest_timezone)
  zone = ask_valid(t('q_timezone'), zone, hint: t('h_timezone'),
                   suggested: @fresh || config_zone.to_s.empty?) do |answer|
    valid_timezone?(answer) ? nil : t('e_timezone', zone: answer)
  end
  site.set(%w[site timezone], zone) if zone
end

# The address is the one setting that lives in both files, and the
# example ships env.sh's copy ACTIVE and pointing at example.com -- so a
# user who carefully sets site.base_url and leaves env.sh alone gets a
# site that still calls itself example.com everywhere. Setting both to
# the same value is the only answer that cannot surprise anyone; the
# override stays available for whoever actually wants it.
# Asked on a FIRST RUN only, and that is the whole point of it being
# here: pagination is anchored to the oldest post, so old listing pages
# never change -- and that immutability rests on the page size staying
# what it was. Change it after the first deploy and every boundary moves,
# every listing page in the archive is rewritten, and an address somebody
# saved points at different posts.
#
# On a re-run the question is therefore not asked at all. Somebody who
# really means it can still edit the key by hand, where the comment in
# config/site.yml.example says the same thing at more length.
def ask_page_size(site, current)
  return unless @fresh

  value = ask_valid(t('q_page_size'), current.dig('site', 'page_size') || 10,
                    hint: t('h_page_size')) do |answer|
    t('e_page_size') unless answer.to_s.match?(/\A[1-9]\d*\z/)
  end
  site.set(%w[site page_size], value.to_i) if value
end

# Nothing to write here -- a cron entry lives in the machine's crontab,
# not in this repository, and installing one on somebody's behalf is a
# change to their system rather than to their site.
#
# It is said all the same, because the failure it prevents is silent:
# ./blog.sh schedule accepts a date, the post waits, and without this job
# nothing ever publishes it. Doctor cannot warn about it on a fresh
# install either -- it stays quiet while the queue is empty, so the first
# hint would otherwise be a post that did not go out.
def tell_about_scheduler
  puts Tui.paint(t('section_scheduler'), :bold)
  puts
  puts t('section_scheduler_intro')
  puts
  puts Tui.paint("  */15 * * * * #{File.join(ROOT, 'scripts', 'publish-scheduled.sh')}", :green)
  puts
  puts Tui.paint(t('scheduler_note'), :dim)
  puts
end

def ask_address(site, env, current)
  puts Tui.paint(t('section_address'), :bold)
  puts

  url = ask_valid(t('q_base_url'), current.dig('site', 'base_url'), hint: t('h_base_url'),
                  suggested: template?(current, 'site', 'base_url')) do |answer|
    if !answer.match?(%r{\Ahttps?://[^/\s]+})
      t('e_base_url')
    elsif answer.end_with?('/')
      t('e_base_url_slash')
    end
  end
  return if url.to_s.empty?

  site.set(%w[site base_url], url)
  env.set('SITE_BASE_URL', url)
end

def ask_network(site, env, current)
  puts Tui.paint(t('section_network'), :bold)
  puts
  # The one place the wizard explains a concept before asking: that the
  # comments ARE a social network's replies is the engine's central
  # arrangement, and nothing on a fresh install has shown it yet.
  puts t('section_network_intro')
  puts

  now = if current['mastodon'] then 'mastodon'
        elsif current['bluesky'] then 'bluesky'
        else 'none'
        end
  options = [
    ['mastodon', t('network_mastodon')],
    ['bluesky', t('network_bluesky')],
    ['none', t('network_none')]
  ]
  chosen = choose(t('q_network'), options, current_index: options.index { |o| o.first == now } || 2)

  case chosen
  when 'mastodon' then ask_mastodon(site, env, current)
  when 'bluesky' then ask_bluesky(site, env, current)
  else
    # Turning the network off has to remove the other section too, or
    # the build would still find one and announce to it.
    site.deactivate(%w[mastodon])
    site.deactivate(%w[bluesky])
    puts t('network_off')
    puts
  end
end

def ask_mastodon(site, env, current)
  site.deactivate(%w[bluesky])

  instance = ask_valid(t('q_instance'), current.dig('mastodon', 'instance'), hint: t('h_instance')) do |answer|
    t('e_instance') if answer.include?('/') || answer.include?(' ')
  end
  site.set(%w[mastodon instance], instance)

  puts t('token_where', instance: instance)
  token = Tui.password(t('q_token'))
  # Tui.password closes the prompt row itself in a terminal -- it has to,
  # nothing was echoed to close it. Down a pipe it takes the same silent
  # route and does NOT, so the `puts` below stopped being the blank line it
  # is here and became the row's line break instead: piped, "Bez tokenu."
  # arrived hard against the question, and in a terminal a blank line above
  # it. One shape or the other, not one per stream.
  puts unless Tui.interactive?
  puts
  if token.empty?
    puts Tui.paint(t('token_skipped'), :dim)
    puts
    return
  end

  env.set('MASTODON_ACCESS_TOKEN', token)
  result = verify_mastodon(instance, token)
  if result[:error]
    puts Tui.paint("⚠️  #{result[:error]}", :yellow)
    puts Tui.paint(result[:rejected] ? t('token_kept_rejected') : t('token_kept_anyway'), :dim)
  else
    puts Tui.paint(t('token_ok', handle: "@#{result[:handle]}@#{instance}"), :green)
    # The numeric account id is the toots widget's one required value and
    # the single most common thing people fill in wrong (the @handle goes
    # in, nothing comes out, nothing says why). We are holding it: offer
    # the widget here rather than make anyone go and look it up.
    ask_toots_widget(site, current, result[:id])
  end
  puts
end

def ask_toots_widget(site, current, account_id)
  return if account_id.to_s.empty?

  puts
  return unless confirm(t('q_toots_widget', id: account_id))

  site.set(%w[widgets toots account_id], account_id.to_s)
  site.set(%w[widgets toots heading], current.dig('widgets', 'toots', 'heading') || t('toots_heading'))
  site.set(%w[widgets toots limit], current.dig('widgets', 'toots', 'limit') || 3)
  puts Tui.paint(t('toots_added'), :green)
end

def ask_bluesky(site, env, current)
  site.deactivate(%w[mastodon])

  handle = ask_valid(t('q_handle'), current.dig('bluesky', 'handle'), hint: t('h_handle')) do |answer|
    t('e_handle') if answer.start_with?('@') || answer.include?('/')
  end
  site.set(%w[bluesky handle], handle)

  password = Tui.password(t('q_app_password'))
  puts unless Tui.interactive? # see the note by the Mastodon token above
  puts
  if password.empty?
    puts Tui.paint(t('password_skipped'), :dim)
  else
    env.set('BLUESKY_APP_PASSWORD', password)
  end
  puts
end

# Six backends, each with its own one or two values. The menu leads with
# "not yet" because that is a real and common answer -- a site being
# written locally before it has anywhere to go -- and because an
# unconfigured deploy is a documented, harmless state (it says so and
# exits 0).
BACKENDS = [
  ['none', 'backend_none', []],
  ['surfer', 'backend_surfer', %w[SURFER_URL SURFER_TOKEN SURFER_REMOTE_DIR]],
  ['local', 'backend_local', %w[DEPLOY_TARGET_DIR]],
  ['rsync', 'backend_rsync', %w[RSYNC_TARGET]],
  ['git', 'backend_git', %w[GIT_PAGES_REMOTE GIT_PAGES_BRANCH]],
  ['rclone', 'backend_rclone', %w[RCLONE_TARGET]],
  ['sftp', 'backend_sftp', %w[SFTP_TARGET SFTP_REMOTE_DIR]]
].freeze

SECRET_VALUES = %w[SURFER_TOKEN].freeze

def ask_deploy(env, _current)
  puts Tui.paint(t('section_deploy'), :bold)
  puts
  puts t('section_deploy_intro')
  puts

  now = ENV['DEPLOY_BACKEND'].to_s
  now = 'surfer' unless now.empty? || BACKENDS.any? { |b| b.first == now }
  options = BACKENDS.map { |(name, key, _)| [name, t(key)] }
  index = BACKENDS.index { |b| b.first == now } || 0
  chosen = choose(t('q_backend'), options, current_index: index)

  if chosen == 'none'
    # An explicit "nowhere" must also STICK on a site that already
    # deploys somewhere -- leaving DEPLOY_BACKEND set meant the user's
    # choice to stop deploying changed nothing and ./blog.sh rebuild
    # kept shipping to the old target. The backend's values (tokens,
    # URLs) stay, commented out by unset's convention, so choosing the
    # backend again later finds them.
    env.unset('DEPLOY_BACKEND')
    puts t('backend_skipped')
    puts
    return
  end

  env.set('DEPLOY_BACKEND', chosen)
  values = BACKENDS.find { |b| b.first == chosen }.last
  values.each do |name|
    if SECRET_VALUES.include?(name)
      # Same courtesy the Mastodon token gets: say where a secret comes
      # from before asking for it.
      puts t('surfer_token_where') if name == 'SURFER_TOKEN'
      value = Tui.password(t("q_#{name.downcase}"))
      puts unless Tui.interactive? # see the note by the Mastodon token above
      puts
    else
      value = ask(t("q_#{name.downcase}"), ENV[name].to_s, hint: t("h_#{name.downcase}"))
    end
    env.set(name, value) unless value.to_s.empty?
  end

  check_local_target(env) if chosen == 'local'
end

# The one target that can be checked without the network, and worth
# checking: a typo'd path deploys a whole site into a directory nobody
# serves, and looks like a success.
def check_local_target(env)
  dir = env.value('DEPLOY_TARGET_DIR')
  return if dir.to_s.empty?

  if File.directory?(dir)
    puts Tui.paint(t('target_ok', dir: dir), :green)
  else
    puts Tui.paint("⚠️  #{t('target_missing', dir: dir)}", :yellow)
  end
  puts
end

# --- writing ---------------------------------------------------------

def review_and_write(site, env)
  outcome = Wizard.review_and_write([[relative(SITE_YML), site], [relative(ENV_SH), env]])
  return unless outcome == :written

  # env.sh was read by the SHELL that started this process, so everything
  # just written to it is invisible here until it is copied across --
  # without this the closing check would report the deploy backend the
  # user replaced thirty seconds ago.
  env.values.each { |name, value| ENV[name] = value }

  puts Tui.paint(t('env_permissions', path: relative(ENV_SH)), :dim) if env.changed?
  puts
  puts t('next_steps')
  puts
  run_doctor
end

def relative(path)
  path.sub("#{ROOT}/", '')
end

# Closing with doctor rather than a congratulation: the wizard covers the
# core, and doctor is what knows about everything else -- the example
# text still in about.html, the banner nobody has drawn yet. It is also
# the command they will want later, so this is where they meet it.
def run_doctor
  require_relative '../lib/doctor'
  findings = Doctor.run
  problems = findings.reject { |f| f.level == :ok }
  if problems.empty?
    puts Tui.paint(t('doctor_clean'), :green)
    # Doctor is the last thing ./setup.sh says, on either of its two ways
    # out, so this is where the run's single trailing blank line belongs --
    # the convention every command here follows. Both ways out ended flush
    # against the shell prompt instead.
    puts
    return
  end

  puts Tui.paint(t('doctor_rest'), :bold)
  puts
  problems.each do |finding|
    mark = finding.error? ? Tui.paint('❌', :red) : Tui.paint('⚠️ ', :yellow)
    puts "#{mark} #{finding.text}"
    puts Tui.paint("   #{finding.fix}", :dim) if finding.fix
  end
  puts
  puts Tui.paint(t('doctor_hint'), :dim)
  puts
end

Wizard.guard { run }
