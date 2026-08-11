#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/style.rb -- the appearance wizard, run via ./style.sh.
#
# Split from ./setup.sh by LIFECYCLE, not by which file a setting lives
# in (both write config/site.yml). Setup asks the handful of things you
# answer once and never revisit -- the timezone, the address, which
# network carries the comments. This is everything you will come back
# and fiddle with: the palette, the header image, your own bio, the
# footer, the sidebar. So setup is one pass from top to bottom and this
# is a menu you dip into, section by section, as many times as you like.
#
# The palette section is the reason this exists at all. Choosing between
# fourteen hex values is exactly as blind in a wizard as it is in YAML --
# what makes it useful is that the engine ships whole palettes, so the
# common answer is one keystroke, and that a change can be looked at
# before it is kept.

require 'yaml'
require_relative '../lib/yaml_compat'
require 'rbconfig'
# For $CHILD_STATUS -- whether the build or the deploy left because the lock
# was held decides the words, and $? does not read as either.
require 'English'
require_relative '../lib/run_lock'
require_relative '../lib/site_config'

ROOT = File.expand_path('..', __dir__)
SITE_YML = File.join(ROOT, 'config', 'site.yml')
SITE_YML_EXAMPLE = File.join(ROOT, 'config', 'site.yml.example')
PALETTES_YML = File.join(ROOT, 'config', 'palettes.yml')

# Same dance as setup.rb and doctor.rb: the language comes out of the raw
# file, because asking SiteConfig would abort on a config this wizard may
# well have been started to repair.
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
require_relative '../lib/media_dimensions'
require_relative '../lib/version'
require_relative '../lib/site_header'
require_relative '../lib/qr_code'

def t(key, **vars)
  I18n.t("style.#{key}", **vars)
end

COLOR_KEYS = %w[bg text meta_text accent nav_bg border pill_bg].freeze
HEX = /\A#(\h{3}|\h{6})\z/.freeze

# The icons the build already knows how to draw. Anything else needs
# icon_svg, which is markup and belongs in the file rather than a prompt.
ICONS = %w[mastodon pixelfed linkedin github bluesky instagram threads facebook x youtube rss email].freeze

def current
  @current ||= begin
    path = File.exist?(SITE_YML) ? SITE_YML : SITE_YML_EXAMPLE
    data = YamlCompat.load_file(path) || {}
    data.is_a?(Hash) ? data : {}
  rescue StandardError
    {}
  end
end

def site
  @site ||= ConfigWriter::YamlFile.new(SITE_YML, template: SITE_YML_EXAMPLE)
end

# Same arrangement as setup.rb: a value still equal to the template's
# ("Your Site", the example bio) is a placeholder, not an answer, and
# the prompt shows it as a suggestion. These are exactly the leftovers
# doctor keeps pointing at, and this wizard is where they get fixed.
def template_values
  @template_values ||= begin
    data = YamlCompat.load_file(SITE_YML_EXAMPLE)
    data.is_a?(Hash) ? data : {}
  rescue StandardError
    {}
  end
end

def template?(*keys)
  value = current.dig(*keys)
  !value.nil? && value == template_values.dig(*keys)
end

# --- palettes --------------------------------------------------------

def palettes
  @palettes ||= begin
    loaded = YAML.load_file(PALETTES_YML) || {}
    loaded = {} unless loaded.is_a?(Hash)
    # config/palettes.yml is documented as user-editable, and the natural
    # half-finished states -- only `light:` written so far, or a value
    # that is not a mapping at all -- used to crash the wizard with a
    # bare backtrace the moment the menu opened or the entry was chosen.
    # A malformed palette is named once and left out; the rest still work.
    loaded.select do |slug, data|
      ok = data.is_a?(Hash) && %w[light dark].all? { |m| data[m].is_a?(Hash) }
      puts Tui.paint(t('palette_malformed', name: slug), :yellow) unless ok
      ok
    end
  rescue StandardError => e
    puts Tui.paint(t('palettes_unreadable', message: e.message), :red)
    {}
  end
end

# A shipped palette's name is translated; one somebody added to
# config/palettes.yml falls back to the label in the file, so adding a
# palette never means editing three locales.
def palette_name(slug, data)
  I18n.lookup("style.palette.#{slug}") || data['label'] || slug
end

# Which palette the config is currently on, if any -- so the menu can
# open on it and so re-running does not look like a fresh choice.
def current_palette
  palettes.find do |_, data|
    %w[light dark].all? do |mode|
      COLOR_KEYS.all? { |k| current.dig('colors', mode, k) == data.dig(mode, k) }
    end
  end&.first
end

def section_palette
  now = current_palette
  options = palettes.map { |slug, data| [slug, palette_name(slug, data)] }
  options << ['custom', t('palette_custom')]
  index = options.index { |o| o.first == now } || 0

  puts Tui.paint(t('palette_intro'), :dim)
  puts
  chosen = Wizard.choose(t('q_palette'), options, current_index: index)
  return section_colors_by_hand if chosen == 'custom'

  data = palettes[chosen]
  return unless data

  %w[light dark].each do |mode|
    COLOR_KEYS.each { |key| site.set(['colors', mode, key], data[mode][key]) }
  end
  puts Tui.paint(t('palette_set', name: palette_name(chosen, data)), :green)
  # Shown rather than described: the seven values are the whole palette,
  # and a reader who wants to tweak one now knows which line to open.
  %w[light dark].each do |mode|
    puts Tui.paint("   #{mode}: #{COLOR_KEYS.map { |k| data[mode][k] }.join('  ')}", :dim)
  end
  puts
  offer_palette_preview(data, palette_name(chosen, data))
end

# For somebody who knows exactly what they want, or who is matching a
# palette from somewhere else. Fourteen prompts is a lot, which is why
# it is behind a menu entry rather than the default path.
def section_colors_by_hand
  candidate = { 'light' => {}, 'dark' => {} }
  %w[light dark].each do |mode|
    puts Tui.paint(t("colors_#{mode}"), :bold)
    puts
    COLOR_KEYS.each do |key|
      value = Wizard.ask_valid("colors.#{mode}.#{key}", current.dig('colors', mode, key),
                               hint: t("color_#{key}")) do |answer|
        t('e_hex') unless answer.match?(HEX)
      end
      site.set(['colors', mode, key], value) if value
      candidate[mode][key] = value || current.dig('colors', mode, key)
    end
  end
  offer_palette_preview(candidate, t('pv_custom_name'))
end

# The preview comes BEFORE the write on purpose: it exists to answer "do
# I want this?", and once the diff is confirmed the answer costs a rerun.
# Fourteen hexes answer nothing; the site itself does -- see
# lib/palette_preview.rb for where the page comes from.
#
# On a deployed site the preview travels the same road a draft preview
# does: it is uploaded and answered with the full address (and a QR code)
# rather than a tmp/ path nobody on a server can open. Deploy runs
# WITHOUT --prune -- a preview must never delete anything.
def offer_palette_preview(colors, name)
  return unless Wizard.confirm(t('q_palette_preview'), default: true)

  require_relative '../lib/palette_preview'
  result = Tui.spinner(t('pv_building')) do
    PalettePreview.generate(
      root: ROOT, colors: colors, fonts: current['fonts'] || {},
      labels: { title: t('pv_title', name: name), light: t('colors_light'), dark: t('colors_dark'), hint: t('pv_hint') },
      sample: { title: t('pv_post_title'), paragraphs: [t('pv_post_p1'), t('pv_post_p2')],
                tags: t('pv_post_tags').split(',').map(&:strip) }
    )
  end

  url = preview_site_url
  if result[:site] && url
    show_preview_online(url, result[:local])
  else
    shown = relative(result[:local])
    puts Tui.paint(t(open_in_browser(result[:local]) ? 'pv_opened' : 'pv_written', path: shown), :green)
  end
  puts
rescue StandardError => e
  puts Tui.paint("⚠️  #{t('pv_failed', message: e.message.to_s.lines.first.to_s.strip)}", :yellow)
  puts
end

# The address the uploaded preview will answer on -- only when there is
# both a configured deploy target and a base URL to build it from.
def preview_site_url
  require_relative '../lib/deploy_backend'
  return nil unless DeployBackend.pick.configured?

  base = (ENV['SITE_BASE_URL'] || current.dig('site', 'base_url')).to_s.chomp('/')
  # The template's own placeholder is not this site's address: printing
  # (and QR-encoding) https://example.com/... pointed the user at a
  # domain they do not own while the upload went to the real target.
  return nil if base.empty? || base.include?('example.com')

  "#{base}/palette-preview.html"
end

def show_preview_online(url, local_fallback)
  puts t('pv_uploading')
  # --only: one file, unconditionally, and nothing else even considered
  # -- a preview upload must not sweep along whatever else happens to sit
  # undeployed in public.nosync, let alone prune.
  unless system('ruby', File.join(ROOT, 'scripts', 'deploy_web.rb'), '--only=palette-preview.html')
    # A held lock is not a failed upload, and saying so sends somebody
    # looking for a fault that isn't there -- the hourly sidebar refresh and
    # a confirmed palette arriving in the same minute is an ordinary
    # Tuesday. Same distinction Publishing.finish_later makes for the
    # publishing path; this one shells out to the deploy on its own.
    if RunLock.busy_exit?($CHILD_STATUS)
      puts Tui.paint("⏳  #{t('pv_upload_busy', path: relative(local_fallback))}", :cyan)
    else
      puts Tui.paint("⚠️  #{t('pv_upload_failed', path: relative(local_fallback))}", :yellow)
    end
    open_in_browser(local_fallback)
    return
  end

  puts Tui.paint(t('pv_online', url: url), :cyan)
  if Tui.interactive? && (qr = QrCode.render(url))
    puts
    puts qr
    puts Tui.paint(I18n.t('cli.qr_hint'), :dim)
  end
  open_in_browser(url)
end

# `open`/`xdg-open` take a plain path; no shell, so a space in the
# install path (a Mac's "Mobile Documents") stays one argument. A false
# or nil return -- headless server, no opener -- just means the path gets
# printed instead.
def open_in_browser(path)
  cmd = RbConfig::CONFIG['host_os'].include?('darwin') ? 'open' : 'xdg-open'
  !!system(cmd, path, out: File::NULL, err: File::NULL)
end

# --- banner ----------------------------------------------------------

# The one section that touches a file rather than a value. Copying the
# image in and MEASURING it is the point: banner.width/height exist to
# reserve layout space before the image loads, they are copied by hand
# today, and a wrong pair makes every page jump. Nobody should have to
# read the dimensions off their own file.
def section_banner
  src = current.dig('banner', 'src') || '/assets/images/header.png'
  puts Tui.paint(t('banner_current', path: src), :dim)
  puts

  answer = Wizard.ask(t('q_banner_file'), '', hint: t('h_banner_file'))
  unless answer.to_s.empty?
    path = File.expand_path(answer.strip.gsub(/\A['"]|['"]\z/, ''))
    if File.file?(path)
      # Remembered, NOT copied. The copy used to happen the moment the path
      # was typed, so answering "no" to the review at the end printed
      # "Nothing written" over an image that was already gone -- and the
      # banner is a per-install file outside git, with no backup anywhere.
      # Everything else in these wizards writes only after the confirmation;
      # this is the one thing that touches a file, so it waits with them.
      @pending_banner = path
      puts Tui.paint(t('banner_pending', path: src), :green)
      puts
    else
      puts Tui.paint("⚠️  #{t('banner_not_found', path: path)}", :yellow)
      puts
    end
  end

  # Measured from whatever will be in place after the write: the new file if
  # one was given, the installed one otherwise. Measuring the target before
  # the copy would have recorded the OLD image's dimensions for the new one.
  measure_banner(src, @pending_banner)

  alt = Wizard.ask(t('q_banner_alt'), current.dig('banner', 'alt'), hint: t('h_banner_alt'),
                   suggested: template?('banner', 'alt'))
  site.set(%w[banner alt], alt) if alt

  # Enter keeps whatever the site already does -- which for an unset key is
  # ON, the engine's own default (BANNER_SHOW_TITLE/_CLAIM in
  # build_blog.rb). Asking with a bare [y/N] meant a run through the banner
  # section turned both overlays off for anyone who pressed Enter.
  show_title = Wizard.confirm(t('q_show_title'), default: current.dig('banner', 'show_title') != false)
  site.set(%w[banner show_title], show_title)
  show_claim = Wizard.confirm(t('q_show_claim'), default: current.dig('banner', 'show_claim') != false)
  site.set(%w[banner show_claim], show_claim)
  puts
end

# Runs after review_and_write reports :written -- never before it.
def install_pending_banner
  return unless @pending_banner

  require 'fileutils'
  src = site.intended[%w[banner src]] || current.dig('banner', 'src') || '/assets/images/header.png'
  target = File.join(ROOT, src.sub(%r{\A/}, ''))
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.cp(@pending_banner, target)
  puts Tui.paint(t('banner_copied', path: src), :green)
end

def measure_banner(src, source_file = nil)
  target = source_file || File.join(ROOT, src.sub(%r{\A/}, ''))
  unless File.file?(target)
    puts Tui.paint("⚠️  #{t('banner_missing', path: src)}", :yellow)
    puts
    return
  end

  dims = begin
    MediaDimensions.image(target)
  rescue StandardError
    nil
  end
  unless dims
    puts Tui.paint("⚠️  #{t('banner_unmeasurable')}", :yellow)
    puts
    return
  end

  site.set(%w[banner src], src)
  site.set(%w[banner width], dims[0])
  site.set(%w[banner height], dims[1])
  puts Tui.paint(t('banner_measured', width: dims[0], height: dims[1]), :green)
  puts
end

# --- words -----------------------------------------------------------

def section_about
  heading = Wizard.ask(t('q_about_heading'), current.dig('about', 'heading'), hint: t('h_about_heading'),
                       suggested: template?('about', 'heading'))
  site.set(%w[about heading], heading) if heading

  html = Wizard.ask_text(t('q_about_html'), current.dig('about', 'html'),
                         hint: t('h_about_html'), comment: t('c_about_html'))
  site.set_text(%w[about html], html) if html && html != current.dig('about', 'html')
  puts
end

def section_footer
  %w[links_heading note_heading social_heading copyright].each do |key|
    value = Wizard.ask(t("q_footer_#{key}"), current.dig('footer', key), hint: t("h_footer_#{key}"),
                       suggested: template?('footer', key))
    site.set(['footer', key], value) if value
  end

  note = Wizard.ask_text(t('q_footer_note'), current.dig('footer', 'note_html'),
                         hint: t('h_footer_note'), comment: t('c_footer_note'))
  site.set_text(%w[footer note_html], note) if note && note != current.dig('footer', 'note_html')

  links = edit_list(current.dig('footer', 'links'), %w[title url]) do |item|
    "#{item['title']} -> #{item['url']}"
  end
  site.set_list(%w[footer links], links) if links
  puts
end

def section_social
  entries = current['social']
  entries = [] unless entries.is_a?(Array)

  loop do
    puts Tui.paint(t('social_current'), :bold)
    if entries.empty?
      puts Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index { |e, i| puts "   #{i + 1}) #{e['name']} (#{e['icon']}) #{e['url']}#{e['rel'] ? "  rel=#{e['rel']}" : ''}" }
    end
    puts
    action = Wizard.choose(t('q_social_action'), [
                             ['add', t('list_add')],
                             ['remove', t('list_remove')],
                             ['keep', t('list_keep')]
                           ], current_index: 2)
    case action
    when 'add' then entries << ask_social_entry
    when 'remove' then entries = remove_from(entries) { |e| "#{e['name']} #{e['url']}" }
    else break
    end
  end

  site.set_list(%w[social], entries)
  puts
end

def ask_social_entry
  name = Wizard.ask(t('q_social_name'), '')
  url = Wizard.ask(t('q_social_url'), '', hint: t('h_social_url'))
  icon = Wizard.choose(t('q_social_icon'), ICONS.map { |i| [i, i] }, current_index: 0)
  entry = { 'name' => name, 'url' => url, 'icon' => icon }
  # rel="me" is what earns the verification tick on a Mastodon profile,
  # and it is the single least discoverable thing in the whole config --
  # so it is offered rather than documented, and only where it can work.
  # The hint carries the other half nobody guesses: the profile has to
  # link back, or nothing turns green.
  if icon == 'mastodon'
    puts Tui.paint("   #{t('h_social_rel')}", :dim)
    entry['rel'] = 'me' if Wizard.confirm(t('q_social_rel'))
  end
  entry
end

# --- sidebar ---------------------------------------------------------

WIDGETS = {
  'toots' => %w[account_id limit],
  'pixelfed' => %w[feed_url limit],
  'commits' => %w[username limit],
  'bluesky' => %w[limit],
  'rss' => %w[feed_url limit]
}.freeze

def section_widgets
  loop do
    active = (current['widgets'] || {}).keys
    puts Tui.paint(t('widgets_current', list: active.empty? ? t('list_empty') : active.join(', ')), :dim)
    puts
    options = WIDGETS.keys.map { |name| [name, t("widget_#{name}")] } + [['keep', t('list_keep')]]
    chosen = Wizard.choose(t('q_widget'), options, current_index: options.size - 1)
    break if chosen == 'keep'

    configure_widget(chosen)
  end
  puts
end

def configure_widget(name)
  heading = Wizard.ask(t('q_widget_heading'), current.dig('widgets', name, 'heading') || t("widget_heading_#{name}"))
  site.set(['widgets', name, 'heading'], heading) if heading

  WIDGETS[name].each do |key|
    value = Wizard.ask_valid(t("q_widget_#{key}"), current.dig('widgets', name, key) || default_for(key),
                             hint: t("h_widget_#{key}")) do |answer|
      if key == 'limit'
        t('e_limit') unless answer.to_s.match?(/\A[1-9]\d*\z/)
      elsif key == 'account_id'
        # The mistake this whole prompt exists to catch: the @handle goes
        # in, nothing comes out, and nothing anywhere says why.
        t('e_account_id') unless answer.to_s.match?(/\A\d+\z/)
      elsif key == 'feed_url'
        t('e_feed_url') unless answer.to_s.match?(%r{\Ahttps?://})
      end
    end
    next unless value

    site.set(['widgets', name, key], key == 'limit' ? value.to_i : value)
  end
  puts Tui.paint(t('widget_set', name: name), :green)
  puts
end

def default_for(key)
  key == 'limit' ? 3 : nil
end

# --- fonts and analytics ---------------------------------------------

def section_fonts
  puts Tui.paint(t('fonts_intro'), :dim)
  puts
  {
    'banner_title' => t('q_font_title'), 'banner_title_size' => t('q_font_title_size'),
    'banner_claim' => t('q_font_claim'), 'banner_claim_size' => t('q_font_claim_size')
  }.each do |key, label|
    value = Wizard.ask(label, current.dig('fonts', key), hint: t("h_font_#{key}"))
    site.set(['fonts', key], value) if value
  end
  puts
end

def section_analytics
  src = Wizard.ask(t('q_analytics_src'), current.dig('analytics', 'src'), hint: t('h_analytics_src'))
  if src.to_s.empty?
    puts Tui.paint(t('analytics_skipped'), :dim)
    puts
    return
  end

  site.set(%w[analytics src], src)
  id = Wizard.ask(t('q_analytics_id'), current.dig('analytics', 'website_id'), hint: t('h_analytics_id'))
  site.set(%w[analytics website_id], id) if id
  puts
end

# --- list editing ----------------------------------------------------

def edit_list(entries, fields)
  entries = [] unless entries.is_a?(Array)
  loop do
    puts Tui.paint(t('list_current'), :bold)
    if entries.empty?
      puts Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index { |e, i| puts "   #{i + 1}) #{yield(e)}" }
    end
    puts
    action = Wizard.choose(t('q_list_action'), [
                             ['add', t('list_add')],
                             ['remove', t('list_remove')],
                             ['keep', t('list_keep')]
                           ], current_index: 2)
    case action
    when 'add'
      entry = {}
      fields.each { |f| entry[f] = Wizard.ask(t("q_list_#{f}"), '') }
      entries << entry
    when 'remove'
      entries = remove_from(entries) { |e| yield(e) }
    else
      return entries
    end
  end
end

def remove_from(entries)
  return entries if entries.empty?

  options = entries.each_with_index.map { |e, i| [i, yield(e)] }
  index = Wizard.choose(t('q_list_which'), options, current_index: 0)
  entries.reject.with_index { |_, i| i == index }
end

# --- the menu --------------------------------------------------------

# In the order the page reads, top to bottom: the whole page first
# (palette), then the header (image, fonts), the sidebar (bio, widgets),
# the footer (texts and links, then the icon row that lives in it), and
# last the one thing with no place on the page at all.
SECTIONS = [
  ['palette', 'section_palette'],
  ['banner', 'section_banner'],
  ['fonts', 'section_fonts'],
  ['about', 'section_about'],
  ['widgets', 'section_widgets'],
  ['footer', 'section_footer'],
  ['social', 'section_social'],
  ['analytics', 'section_analytics']
].freeze

def run
  puts SiteHeader.render(tool: './style.sh')
  puts
  puts t('intro')
  puts
  puts Tui.paint(t('intro_skip'), :dim)
  puts

  loop do
    options = SECTIONS.map { |(key, _)| [key, t("menu_#{key}")] }
    chosen = Wizard.choose_or_exit(t('q_section'), options)
    break unless chosen

    # Re-read after each section, so a value set in one is the "current"
    # value the next one offers -- otherwise a second visit to the same
    # section would offer what was on disk before this run started.
    send(SECTIONS.to_h[chosen])
    refresh_current
  end

  outcome = Wizard.review_and_write([[relative(SITE_YML), site]])
  return unless outcome == :written

  install_pending_banner
  offer_rebuild
end

# The in-memory config the prompts read from is the file plus everything
# set so far, so a section revisited in the same run sees its own edits.
def refresh_current
  merged = current
  site.intended.each do |path, value|
    node = merged
    path[0..-2].each { |k| node = (node[k] ||= {}) }
    node[path.last] = value
  end
  @current = merged
end

def relative(path)
  path.sub("#{ROOT}/", '')
end

# Appearance is the one thing you cannot judge from a diff, so the run
# ends by offering the look at it rather than describing what changed.
def offer_rebuild
  puts
  return unless Wizard.confirm(t('q_rebuild'))

  puts
  # No shell: ROOT is an installation path, and every path with a space in
  # it (a Mac's "Mobile Documents", say) turned this into two broken words
  # and reported "the build did not finish" on a perfectly good install.
  ok = system('ruby', 'build/build_blog.rb', chdir: ROOT)
  if ok
    puts
    puts Tui.paint(t('rebuilt'), :green)
  elsif RunLock.busy_exit?($CHILD_STATUS)
    puts Tui.paint("⏳  #{t('rebuild_busy')}", :cyan)
  else
    puts Tui.paint("⚠️  #{t('rebuild_failed')}", :yellow)
  end
end

Wizard.guard { run }
