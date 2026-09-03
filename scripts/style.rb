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
require_relative '../lib/social_icons'
require_relative '../lib/icons'
require_relative '../lib/site_config'
require_relative '../lib/account_id'

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
require_relative '../lib/slug'
# For the menu section: what tags and pages exist, and which addresses
# the build answers at. Shared with check and doctor rather than read
# again here, so that all three agree about what a menu item can point
# at.
require_relative '../lib/checker'
require_relative '../lib/post_address'
require_relative '../lib/forge_address'
require_relative '../lib/incoming_path'

# A script that ASKS has to flush before it blocks. stdout is block
# buffered whenever it is not a terminal, so `cmd | tee log`, `cmd > log`
# and every wrapper that captures output leaves the question sitting in
# the buffer while the process waits for an answer to it. Reproduced on
# the import wizard: at the confirmation gate the log was 0 bytes -- and
# that gate is deliberately built so the answer IS a number from the
# preview, which was in the buffer too. All 1499 bytes arrived when the
# process finally exited.
$stdout.sync = true


def t(key, **vars)
  I18n.t("style.#{key}", **vars)
end

COLOR_KEYS = %w[bg text meta_text accent nav_bg border pill_bg].freeze
HEX = /\A#(\h{3}|\h{6})\z/.freeze

# The icons the build already knows how to draw. Anything else needs
# icon_svg, which is markup and belongs in the file rather than a prompt.
# Read from the engine's own list rather than written out again: this was
# a second copy kept in step by hand, and an icon the engine can draw but
# the wizard never offers is one nobody finds.
# Both sets, in the order a footer asks for them: the network marks
# first, then the general drawings -- which the build accepts here since
# 1.7, and which is how a link to somebody's other site gets `globe`
# instead of a hand-written SVG.
ICONS = (SocialIcons::NAMES + Icons::NAMES).freeze

# current.dig blows up the moment a key holds something other than a
# mapping -- a hand-edited config with `widgets:` as a list, say -- and
# this is a tool people open BECAUSE their config is wrong.
def at(*keys)
  node = current
  keys.each do |key|
    return nil unless node.is_a?(Hash)

    node = node[key]
  end
  node
end

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
  value = at(*keys)
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
      # ...and every value in it has to be a colour. palettes.yml invites
      # hand-editing in its own header, and the natural way to write one --
      # `bg: #fafafa`, unquoted -- makes YAML read the '#' as a comment, so
      # every key parsed as nil. The palette was offered, chosen,
      # confirmed with a green tick, and changed nothing: the write loop
      # skips empty values on purpose (what is absent stays absent), and
      # the person was told it had been applied.
      #
      # The same rule the by-hand path enforces on every typed value, and
      # the one doctor checks the config against -- three parts of the
      # engine were answering "what is a valid colour?" differently.
      ok = data.is_a?(Hash) && %w[light dark].all? do |m|
        data[m].is_a?(Hash) && data[m].any? &&
          data[m].values.all? { |v| v.to_s.match?(HEX) }
      end
      palette_warnings << Tui.paint(t('palette_malformed', name: slug), :yellow) unless ok
      ok
    end
  rescue StandardError => e
    palette_warnings << Tui.paint(t('palettes_unreadable', message: e.message), :red)
    {}
  end
end

# Collected rather than printed, and handed to the menu that follows.
# Printing them here kept the promise the comment above makes -- "named
# once" -- for about a millisecond: the very next thing the section does is
# draw a menu, which paints from the top of the viewport and erases below,
# so the one line telling you why your palette is not on the list was gone
# before you could read it. Same defect as the menu section's state rows,
# same fix: the words go INTO the frame.
def palette_warnings
  @palette_warnings ||= []
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
      COLOR_KEYS.all? { |k| at('colors', mode, k) == data.dig(mode, k) }
    end
  end&.first
end

def section_palette
  now = current_palette
  options = palettes.map { |slug, data| [slug, palette_name(slug, data)] }
  options << ['custom', t('palette_custom')]
  index = options.index { |o| o.first == now } || 0

  # palettes is read by the line above, so any complaint about a malformed
  # entry exists by now and travels into the frame with the intro.
  chosen = Wizard.choose(t('q_palette'), options, current_index: index,
                         note: palette_warnings + [Tui.paint(t('palette_intro'), :dim)])
  return section_colors_by_hand if chosen == 'custom'

  data = palettes[chosen]
  return unless data

  %w[light dark].each do |mode|
    # Only the colours the palette actually names. A palette may leave keys
    # out -- docs/install.md says so in as many words, and the engine falls
    # back to its own blue for whatever is missing -- but writing them out
    # as empty values does not leave them out, it sets them to nothing:
    # `text:` with no value after it, twelve times, and then doctor
    # refusing the config it was just handed. What is absent has to stay
    # absent.
    COLOR_KEYS.each do |key|
      value = data[mode][key]
      next if value.to_s.strip.empty?

      site.set(['colors', mode, key], value)
    end
  end
  # Into the frame (Wizard.say): the preview question follows immediately
  # and repaints the screen, and what it asks about is exactly these rows.
  Wizard.say(t('palette_set', name: palette_name(chosen, data)), :green)
  # Shown rather than described: the seven values are the whole palette,
  # and a reader who wants to tweak one now knows which line to open.
  %w[light dark].each do |mode|
    Wizard.say("   #{mode}: #{COLOR_KEYS.map { |k| data[mode][k] }.join('  ')}", :dim)
  end
  Wizard.say('')
  offer_palette_preview(data, palette_name(chosen, data))
end

# For somebody who knows exactly what they want, or who is matching a
# palette from somewhere else. Fourteen prompts is a lot, which is why
# it is behind a menu entry rather than the default path.
def section_colors_by_hand
  candidate = { 'light' => {}, 'dark' => {} }
  %w[light dark].each do |mode|
    Wizard.say(t("colors_#{mode}"), :bold)
    Wizard.say('')
    COLOR_KEYS.each do |key|
      value = Wizard.ask_valid("colors.#{mode}.#{key}", at('colors', mode, key),
                               hint: t("color_#{key}")) do |answer|
        t('e_hex') unless answer.match?(HEX)
      end
      site.set(['colors', mode, key], value) if value
      candidate[mode][key] = value || at('colors', mode, key)
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
  # Declining is an ending too. Every other way out of this method closes on
  # a blank line and this one closed on the question, so the palette section
  # was the one section whose last line depended on the answer.
  # escape: false, and this is the only question in the engine that needs
  # it. Every other confirm with a default is about a SETTING, where Esc
  # meaning "leave it alone" is both the wizard's promise and the safe
  # answer. This one builds a page and, on a deployed site, PUTS IT ON THE
  # WEB -- so answering the cancel key with the convenient default
  # published something on the keystroke people press to get out.
  unless Wizard.confirm(t('q_palette_preview'), default: true, escape: false)
    puts
    return
  end

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
    # Wizard.say down to the end of this method and the next: the section
    # returns to the section menu, whose repaint used to erase the one
    # line saying where the preview went.
    Wizard.say(t(open_in_browser(result[:local]) ? 'pv_opened' : 'pv_written', path: shown), :green)
  end
  Wizard.say('')
rescue StandardError => e
  Wizard.say("⚠️  #{t('pv_failed', message: e.message.to_s.lines.first.to_s.strip)}", :yellow)
  Wizard.say('')
end

# The address the uploaded preview will answer on -- only when there is
# both a configured deploy target and a base URL to build it from.
def preview_site_url
  require_relative '../lib/deploy_backend'
  return nil unless DeployBackend.pick.configured?

  base = (ENV['SITE_BASE_URL'] || at('site', 'base_url')).to_s.chomp('/')
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
      Wizard.say("⏳  #{t('pv_upload_busy', path: relative(local_fallback))}", :cyan)
    else
      Wizard.say("⚠️  #{t('pv_upload_failed', path: relative(local_fallback))}", :yellow)
    end
    open_in_browser(local_fallback)
    return
  end

  # ⚠️ The address goes AFTER the picture, and that order is the point.
  # The record is trimmed from the top, so anything said before a 15-row
  # QR code is the first thing to go -- and on a 24-row terminal the
  # address, which exists precisely for the case where the code cannot be
  # read, was gone while the code itself survived in useless thirds.
  # Last said is last trimmed.
  if Tui.interactive? && (qr = QrCode.render(url))
    # remember_block, not a row at a time: kept whole or dropped whole.
    # Into the record and NOT through Wizard.say, because say wraps to the
    # terminal width and a wrapped QR code is a picture of nothing.
    # Printed straight to the screen it lasted until the menu repainted
    # over it -- which is immediately -- so what the person was meant to
    # photograph was gone before they reached for the phone.
    Wizard.remember_block([''] + qr.to_s.lines.map(&:chomp) +
                          [Tui.paint(I18n.t('cli.qr_hint'), :dim)])
  end
  # The page really is temporary -- the build removes anything it did not
  # produce itself (prune_public), and the deploy then takes it off the
  # site as an orphan. That is the build doing its job, not a defect; what
  # was missing was anybody saying so. Somebody photographed the QR code
  # one evening and found it dead the next morning. Said here rather than
  # under the picture, because a piped run gets no picture and still
  # deserves to know.
  Wizard.say(t('pv_temporary'), :dim)
  # ⚠️ The address goes LAST of everything. The record is trimmed from the
  # top, so the final row is the one that survives the smallest window --
  # and of the three things this method has to say, the address is the one
  # without which the other two are of no use. A reader who cannot scan
  # the code and cannot read the warning can still type this.
  Wizard.say(t('pv_online', url: url), :cyan)
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
  src = at('banner', 'src') || '/assets/images/header.png'
  # Into the frame, not onto the screen. Wizard.ask repaints from the top
  # of the viewport, so a `puts` here was erased by the very question it
  # was there to inform -- and this line names the file currently in place,
  # which is the one thing you need in front of you when deciding whether
  # to replace it. Left as a `puts` until now because the row would then
  # have been truncated instead of erased; hints and notes wrap now.
  Wizard.remember(Tui.paint(t('banner_current', path: src), :dim))

  answer = Wizard.ask(t('q_banner_file'), '', hint: t('h_banner_file'))
  unless answer.to_s.empty?
    path = resolve_source(answer)
    if File.file?(path)
      # Remembered, NOT copied. The copy used to happen the moment the path
      # was typed, so answering "no" to the review at the end printed
      # "Nothing written" over an image that was already gone -- and the
      # banner is a per-install file outside git, with no backup anywhere.
      # Everything else in these wizards writes only after the confirmation;
      # this is the one thing that touches a file, so it waits with them.
      @pending_banner = path
      src = ask_banner_src(src, path)
      # Same reason as the line above: two more questions follow in this
      # section, and each of them repaints over whatever was printed here.
      # The one that says the file was not found matters most -- it is the
      # answer to "why did nothing happen?", and it was the row most
      # reliably erased.
      #
      # Answering with the file already in place promises no copy, because
      # there will not be one -- the measurement is the whole point of that
      # answer, and it has just been taken.
      Wizard.remember(Tui.paint(in_place?(path, src) ? "✅ #{t('file_in_place', path: src)}"
                                                     : t('banner_pending', path: src), :green))
    else
      # Said, not remembered. `remember` puts a row in the frame, which a
      # piped run never paints at all and a terminal cuts at its width --
      # so the one sentence that answers "why did nothing happen?" was
      # invisible in a script and half-visible on screen, with a green
      # "✅ Measured: 1880x600" (the OLD banner, still installed) directly
      # underneath it, reading like success.
      Wizard.say(Tui.paint("⚠️  #{t('banner_not_found', path: path)}", :yellow))
    end
  end

  # Measured from whatever will be in place after the write: the new file if
  # one was given, the installed one otherwise. Measuring the target before
  # the copy would have recorded the OLD image's dimensions for the new one.
  measure_banner(src, @pending_banner)

  alt = Wizard.ask(t('q_banner_alt'), at('banner', 'alt'), hint: t('h_banner_alt'),
                   suggested: template?('banner', 'alt'))
  site.set(%w[banner alt], alt) if alt

  # Enter keeps whatever the site already does -- which for an unset key is
  # ON, the engine's own default (BANNER_SHOW_TITLE/_CLAIM in
  # build_blog.rb). Asking with a bare [y/N] meant a run through the banner
  # section turned both overlays off for anyone who pressed Enter.
  show_title = Wizard.confirm(t('q_show_title'), default: at('banner', 'show_title') != false)
  site.set(%w[banner show_title], show_title)
  show_claim = Wizard.confirm(t('q_show_claim'), default: at('banner', 'show_claim') != false)
  site.set(%w[banner show_claim], show_claim)

  # Only where it can be seen. The claim's text is site.description unless
  # this overrides it -- and it exists because site.description has to stay
  # plain text (it is reused in meta, RSS and listing descriptions), so it
  # cannot carry a line break. This field can, since the banner overlay is
  # the only thing that reads it.
  ask_banner_claim if show_claim

  puts
end

def ask_banner_claim
  now = at('banner', 'claim')
  answer = Wizard.ask(t('q_banner_claim'), now, hint: t('h_banner_claim')).to_s
  return if answer.strip.empty? || answer == now.to_s

  site.set(%w[banner claim], answer)
end

# Where the banner is copied TO. The name is configuration (banner.src),
# not a convention -- but the wizard could only ever copy onto whatever
# the config already said, so a site that wanted its own filename had to
# edit site.yml by hand and then run this again.
#
# Only asked when the chosen file is named differently from the configured
# one; answering with the current path keeps it, which is what somebody
# replacing an image in place wants and is therefore the default. The
# answer is normalised to a path under assets/images/, because that is
# where install_pending_banner writes and where .gitignore keeps
# per-install artwork out of the engine's repository.
def ask_banner_src(current_src, source)
  suggested = "/assets/images/#{File.basename(source)}"
  return current_src if suggested == current_src

  answer = Wizard.ask(t('q_banner_src'), current_src,
                      hint: t('h_banner_src', suggested: suggested)).to_s.strip
  return current_src if answer.empty? || answer == current_src

  name = File.basename(answer)
  chosen = "/assets/images/#{name}"
  site.set(%w[banner src], chosen)
  chosen
end

# incoming/ is where anything meant for the site is dropped -- it is the
# one directory a separate upload account can write to, and the post
# editor has taken photos from it all along. Answering a prompt with a
# bare filename looks there; an answer with a directory in it is a path on
# this machine and is used as given, which is what working from a Mac
# wants.
INCOMING_DIR = File.join(ROOT, 'incoming')

def resolve_source(answer)
  IncomingPath.resolve(answer, INCOMING_DIR)
end

# Queued, not copied: everything in these wizards happens after the diff is
# confirmed, and a file moved before that would be gone if the answer was
# "no".
def queue_file(source, href)
  @pending_files ||= []
  @pending_files << [source, href]
  href
end

# Where the pending banner would land: whatever this run chose, else
# whatever the config already says. Asked in two places now -- the review
# lists the copy as a change, and the install carries it out.
def pending_banner_target
  site.intended[%w[banner src]] || at('banner', 'src') || '/assets/images/header.png'
end

# An answer that names the file already installed -- what you type to
# re-measure artwork you replaced by hand or dropped in from Finder --
# resolves to the target itself. There is nothing to copy, and FileUtils
# answers a copy onto itself with "same file" and a backtrace.
def in_place?(source, href)
  target = File.join(ROOT, href.to_s.sub(%r{\A/}, ''))
  File.file?(target) && File.identical?(source, target)
end

# The changes these wizards make that are not lines in a file, in the shape
# review_and_write lists changes in: the banner picture, and every
# stylesheet and font file the other sections queued. Without them a run
# whose only change is a file -- an image replaced by one of the same name
# and the same dimensions moves nothing in site.yml, and putting back a
# skin.css the config already names moves nothing either -- ended on
# "nothing changed", and the copies, which wait for a confirmed write, were
# dropped with it: the wizard said the file would be installed, then said
# nothing had changed, and left it sitting in incoming/.
#
# A copy that would land where it came from is left out: it is not a
# change, and listing it would promise something the install then does not
# do.
def pending_review
  copies = Array(@pending_files).dup
  copies.unshift([@pending_banner, pending_banner_target, :banner]) if @pending_banner
  copies.filter_map do |source, href, banner|
    next if in_place?(source, href)

    Tui.paint(t(banner ? 'review_banner' : 'review_file',
                name: File.basename(source), path: href), :green)
  end
end

# Runs after review_and_write reports :written -- never before it.
def install_pending_files
  require 'fileutils'
  queue_file(@pending_banner, pending_banner_target) if @pending_banner
  return if @pending_files.nil? || @pending_files.empty?

  left = []
  @pending_files.each do |source, href|
    if in_place?(source, href)
      # Said out loud rather than skipped in silence: the answer was
      # accepted, and the reason nothing was copied is that nothing had to
      # be. Never dropped from incoming/ either -- the source IS the
      # installed file.
      puts Tui.paint(t('file_in_place', path: href), :green)
      next
    end
    target = File.join(ROOT, href.sub(%r{\A/}, ''))
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
    # Where it went, every time. A file that disappears out of incoming/
    # without saying where is worse than one that was never moved.
    puts Tui.paint(t('file_copied', path: href), :green)
    left << File.basename(source) unless drop_from_incoming(source)
  end
  return if left.empty?

  puts Tui.paint(t('incoming_not_cleaned', files: left.join(', ')), :yellow)
end

# Only files that came from incoming/ are cleared, and only after the copy
# succeeded -- a path somewhere else on the machine is the author's own
# file and is never touched. Deleting needs write permission on the
# DIRECTORY, which an upload account's incoming/ may not give us; that is
# said out loud rather than swallowed.
def drop_from_incoming(source)
  return true unless File.expand_path(source).start_with?("#{File.expand_path(INCOMING_DIR)}/")

  File.delete(source)
  true
rescue SystemCallError
  false
end

def measure_banner(src, source_file = nil)
  target = source_file || File.join(ROOT, src.sub(%r{\A/}, ''))
  # Wizard.say throughout: two more questions follow in the banner
  # section and each repaints the screen, so the measurement -- or the
  # warning saying why there is none -- was erased before it was read.
  unless File.file?(target)
    Wizard.say("⚠️  #{t('banner_missing', path: src)}", :yellow)
    Wizard.say('')
    return
  end

  dims = begin
    MediaDimensions.image(target)
  rescue StandardError
    nil
  end
  unless dims
    Wizard.say("⚠️  #{t('banner_unmeasurable')}", :yellow)
    Wizard.say('')
    return
  end

  site.set(%w[banner src], src)
  site.set(%w[banner width], dims[0])
  site.set(%w[banner height], dims[1])
  Wizard.say(t('banner_measured', width: dims[0], height: dims[1]), :green)
  Wizard.say('')
end

# --- words -----------------------------------------------------------

# Which regions of the page exist at all, and the stylesheet that dresses
# what is left. Both belong to the same moment -- the one where the
# engine's own look is not the look you want -- so they are one section
# rather than two entries in the menu.
#
# Every switch is asked with the site's current answer as the default, and
# an unset key means the engine's own: sidebar and the repeated bottom menu
# on, the lead image off. Pressing Enter through the section therefore
# changes nothing, which is the rule the menu section had to learn the
# hard way.
def section_layout
  sidebar = Wizard.confirm(t('q_layout_sidebar'), default: at('layout', 'sidebar') != false)
  site.set(%w[layout sidebar], sidebar)

  hero = Wizard.confirm(t('q_layout_hero'), default: at('layout', 'hero') == true)
  site.set(%w[layout hero], hero)

  puts
  section_extra_css
end

# The skin. A list, in load order, of stylesheets the browser gets after
# the engine's own -- which is what lets a site look like something else
# without editing a template and losing the edit to the next git pull.
def section_extra_css
  entries = at('site', 'extra_css')
  entries = [] unless entries.is_a?(Array)
  entries = entries.map(&:to_s)
  touched = false

  loop do
    # Into the menu as `note:` rows, the way section_nav carries its state:
    # printed, the menu's own repaint erased the list at the moment of
    # choosing what to do with it.
    state = [Tui.paint(t('css_current'), :bold)]
    if entries.empty?
      state << Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index { |e, i| state << "   #{i + 1}) #{e}#{css_exists?(e) ? '' : "  #{t('css_missing_mark')}"}" }
    end

    options = [['add', t('list_add')]]
    options << ['remove', t('list_remove')] unless entries.empty?
    options << ['keep', t('list_keep')]
    case Wizard.choose(t('q_css_action'), options, current_index: options.size - 1, note: state)
    when 'add'
      entry = ask_css_entry
      next unless entry

      entries << entry if entry
      touched = true
    when 'remove'
      entries = remove_from(entries) { |e| e }
      touched = true
    else
      break
    end
  end

  site.set_list(%w[site extra_css], entries) if touched
  puts
end

def css_exists?(href)
  File.file?(File.join(ROOT, href.to_s.sub(%r{\A/}, ''))) || queued?(href)
end

# A file waiting for the confirmation is not a missing file. Without this
# the list warned about the very thing it had just accepted, one line
# after saying where it would go.
def queued?(href)
  Array(@pending_files).any? { |_, target| target == href }
end

# Two things are worth saying before the answer is taken, because both
# fail silently on the finished page: a stylesheet on another host is
# discarded by the browser (every page carries style-src 'self'), and a
# path that is not there simply never arrives.
def ask_css_entry
  answer = Wizard.ask(t('q_css_file'), '', hint: t('h_css_file')).to_s.strip
  return nil if answer.empty?

  if answer.include?('://')
    # The list menu repaints right after this returns; the reason the
    # entry was refused has to ride in with it.
    Wizard.say("   #{t('css_remote')}", :yellow)
    Wizard.say('')
    return nil
  end

  # Already in assets/css/ -- the answer names a file the site has, and
  # nothing needs installing.
  href = answer.start_with?('/') ? answer : "/assets/css/#{File.basename(answer)}"
  return href if css_exists?(href)

  source = resolve_source(answer)
  unless source && File.file?(source)
    return nil unless Wizard.confirm(t('q_css_anyway'),
                                     note: t('css_not_found', path: href))

    return href
  end

  href = "/assets/css/#{File.basename(source)}"
  Wizard.say("   #{t('file_will_go', path: href)}", :green)
  queue_file(source, href)
end

def section_about
  heading = Wizard.ask(t('q_about_heading'), at('about', 'heading'), hint: t('h_about_heading'),
                       suggested: template?('about', 'heading'))
  site.set(%w[about heading], heading) if heading

  html = Wizard.ask_text(t('q_about_html'), at('about', 'html'),
                         hint: t('h_about_html'), comment: t('c_about_html'))
  site.set_text(%w[about html], html) if html && html != at('about', 'html')
  puts
end

def section_footer
  %w[links_heading note_heading social_heading copyright].each do |key|
    value = Wizard.ask(t("q_footer_#{key}"), at('footer', key), hint: t("h_footer_#{key}"),
                       suggested: template?('footer', key))
    site.set(['footer', key], value) if value
  end

  note = Wizard.ask_text(t('q_footer_note'), at('footer', 'note_html'),
                         hint: t('h_footer_note'), comment: t('c_footer_note'))
  site.set_text(%w[footer note_html], note) if note && note != at('footer', 'note_html')

  links = edit_list(at('footer', 'links'), %w[title url]) do |item|
    "#{item['title']} -> #{item['url']}"
  end
  site.set_list(%w[footer links], links) if links
  puts
end

def section_social
  entries = SiteConfig::Chrome.list(current, 'social')
  entries = [] unless entries.is_a?(Array)

  loop do
    # `note:` for the reason section_nav's state rows ride there -- see
    # section_extra_css.
    state = [Tui.paint(t('social_current'), :bold)]
    if entries.empty?
      state << Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index { |e, i| state << "   #{i + 1}) #{e['name']} (#{e['icon']}) #{e['url']}#{e['rel'] ? "  rel=#{e['rel']}" : ''}" }
    end
    action = Wizard.choose(t('q_social_action'), [
                             ['add', t('list_add')],
                             ['remove', t('list_remove')],
                             ['keep', t('list_keep')]
                           ], current_index: 2, note: state)
    case action
    when 'add'
      # The same guard the other three list sections have (nav, extra CSS,
      # font faces). Without it, backing out of "add one" -- pressing Enter
      # past the name, which is this wizard's documented way to say never
      # mind -- pushed nil into the list, and the next repaint of the rows
      # dereferenced it: a Ruby backtrace, and every answer given anywhere
      # in the session thrown away, because nothing is written until the
      # review at the end.
      entry = ask_social_entry
      next unless entry

      entries << entry
    when 'remove' then entries = remove_from(entries) { |e| "#{e['name']} #{e['url']}" }
    else break
    end
  end

  site.set_list(%w[social], entries)
  puts
end

# --- the menu bar ----------------------------------------------------

# `nav:` has three states and they are not "list, empty list, and a
# default": the ABSENCE of the key means the derived menu (All + one item
# per content type the site actually has), a list means those items and
# nothing else, and an empty list means no menu bar at all. That makes
# this the one section where doing nothing has to write nothing --
# section_social ends with an unconditional set_list, which here would
# turn a derived menu off for anyone who walked in to look.
#
# Its second job is to stop the mistake doctor now reports: a menu item
# is written once and then outlives what it points at. So a tag or an
# address that the archive does not produce is questioned HERE, while the
# person is still the one who can say whether it is a typo or a post they
# have not written yet.
def section_nav
  # The same question the build asks (SiteConfig::Chrome.written?), not a
  # different one: since 1.4 a `nav:` key with nothing under it means "no
  # menu", so describing that config as "the engine derives the menu" told
  # the author the opposite of what their own site was doing.
  derived = !SiteConfig::Chrome.written?(current, 'nav')
  entries = SiteConfig::Chrome.list(current, 'nav')
  touched = false

  loop do
    # Which of the three states the site is in travels INTO the menu rather
    # than being printed above it -- see Wizard.choose. Printed first, it
    # was painted over, and a derived menu then looked no different from
    # one switched off at the moment of choosing between them.
    state = if derived
              [Tui.paint(t('nav_derived'), :dim)]
            elsif entries.empty?
              [Tui.paint(t('nav_is_off'), :dim)]
            else
              [Tui.paint(t('nav_current'), :bold)] +
                entries.each_with_index.map { |e, i| "   #{i + 1}) #{nav_summary(e)}" }
            end

    options = [['add', t('list_add')]]
    options << ['remove', t('list_remove')] unless entries.empty?
    options << ['off', t('nav_turn_off')] if derived || entries.any?
    options << ['keep', t('list_keep')]
    action = Wizard.choose(t('q_nav_action'), options,
                           current_index: options.size - 1, note: state)

    case action
    when 'add'
      # Said before the first item and not after it: adding one entry to a
      # derived menu does not add one entry, it replaces the whole menu.
      # Through the frame context (Wizard.say), because the label question
      # that follows repaints the screen -- printed, the one sentence
      # explaining the destructive part of this choice was never readable.
      Wizard.say(t('nav_replaces_derived'), :yellow) if derived && entries.empty?
      entry = ask_nav_entry
      next unless entry

      entries << entry
      derived = false
      touched = true
    when 'remove'
      entries = remove_from(entries) { |e| nav_summary(e) }
      derived = false
      touched = true
    when 'off'
      entries = []
      derived = false
      touched = true
      Wizard.say(t('nav_off_note'), :green)
      Wizard.say('')
    else
      break
    end
  end

  site.set_list(%w[nav], entries) if touched
  puts
end

def nav_summary(entry)
  target = entry['tag'].to_s.empty? ? entry['url'].to_s : "/tag/#{entry['tag']}/"
  "#{entry['label']} -> #{target}"
end

def ask_nav_entry
  label = Wizard.ask(t('q_nav_label'), '')
  return nil if label.to_s.strip.empty?

  kinds = [['home', t('nav_kind_home')], ['tag', t('nav_kind_tag')]]
  kinds << ['page', t('nav_kind_page')] if nav_pages.any?
  kinds << ['url', t('nav_kind_url')]

  case Wizard.choose(t('q_nav_kind'), kinds, current_index: 0)
  when 'home' then { 'label' => label.strip, 'url' => '/' }
  when 'tag' then ask_nav_tag(label.strip)
  when 'page'
    path = Wizard.choose(t('q_nav_page'), nav_pages.map { |p| [p, p] }, current_index: 0)
    { 'label' => label.strip, 'url' => path }
  else ask_nav_url(label.strip)
  end
end

def ask_nav_tag(label)
  hint = nav_tag_sample.empty? ? t('h_nav_tag_empty') : t('h_nav_tag', list: nav_tag_sample)
  answer = Wizard.ask(t('q_nav_tag'), '', hint: hint)
  slug = Slug.slugify(answer.to_s)
  return nil if slug.empty?
  # An archive with nothing in it has nothing to disagree with, and a
  # brand-new site writing its menu first should not be told that every
  # tag it names is missing.
  return nil if nav_posts.any? && !nav_tags.include?(slug) && !nav_confirm_unknown(t('nav_tag_unknown', tag: slug))

  { 'label' => label, 'tag' => slug }
end

def ask_nav_url(label)
  url = Wizard.ask(t('q_nav_url'), '', hint: t('h_nav_url')).to_s.strip
  return nil if url.empty?

  # `about` is not an address, it is an address relative to whatever page
  # it is written on -- and a menu is written on all of them. Offered as a
  # correction rather than a warning, because there is exactly one thing
  # the person meant.
  if relative_nav_url?(url)
    fixed = "/#{url}/"
    url = fixed if Wizard.confirm(t('q_nav_use_absolute', url: fixed),
                                  note: t('nav_url_relative', url: url))
  end

  # Only addresses on this site are judged. Somebody else's page is a
  # perfectly good menu item, and whether it answers is not a question
  # this archive can be asked.
  if url.start_with?('/') && !url.start_with?('//') && nav_posts.any? &&
     !nav_known.include?(url) && !nav_known.include?("#{url}/") &&
     !nav_confirm_unknown(t('nav_url_unknown', url: url))
    return nil
  end

  { 'label' => label, 'url' => url }
end

def relative_nav_url?(url)
  return false if url.start_with?('/', '#')
  return false if url.include?('://')

  !url.start_with?('mailto:', 'tel:')
end

def nav_confirm_unknown(message)
  Wizard.confirm(t('q_nav_anyway'), note: message)
end

# The archive, read once and only if somebody actually adds an item -- a
# site with hundreds of posts should not pay for opening this section to
# look at it. Checker's, rather than a second reading of the same files:
# it already knows every address the build answers at, and doctor judges
# the finished menu by exactly that set.
def nav_posts
  @nav_posts ||= Checker.load_posts(ROOT)
end

def nav_tag_slugs
  @nav_tag_slugs ||= nav_posts.flat_map { |p| Array(p['tags']).map { |tag| Slug.slugify(tag.to_s) } }.reject(&:empty?)
end

def nav_tags
  @nav_tags ||= nav_tag_slugs.to_set
end

def nav_known
  @nav_known ||= Checker.known_paths(nav_posts)
end

def nav_pages
  # Asked of PostAddress, because "page: No" is true to Ruby and false to
  # the build: the menu offered an address the site does not answer at.
  @nav_pages ||= nav_posts.select { |p| PostAddress.page?(p) }.map { |p| "/#{p['slug']}/" }.sort
end

# The tags worth putting in a menu are the ones with posts behind them, so
# the hint is the busiest few rather than an alphabetical wall.
def nav_tag_sample
  @nav_tag_sample ||= nav_tag_slugs.tally.sort_by { |slug, count| [-count, slug] }.first(8).map(&:first).join(', ')
end

def ask_social_entry
  name = Wizard.ask(t('q_social_name'), '')
  url = Wizard.ask(t('q_social_url'), '', hint: t('h_social_url'))
  # Answering nothing means "never mind", not "add an icon with no name
  # that links nowhere" -- which is what it used to write into the footer
  # of every page on the site.
  return nil if name.to_s.strip.empty? || url.to_s.strip.empty?

  icon = Wizard.choose(t('q_social_icon'), ICONS.map { |i| [i, i] }, current_index: 0)
  entry = { 'name' => name, 'url' => url, 'icon' => icon }
  # rel="me" is what earns the verification tick on a Mastodon profile,
  # and it is the single least discoverable thing in the whole config --
  # so it is offered rather than documented, and only where it can work.
  # The hint carries the other half nobody guesses: the profile has to
  # link back, or nothing turns green.
  if icon == 'mastodon'
    entry['rel'] = 'me' if Wizard.confirm(t('q_social_rel'), note: t('h_social_rel'))
  end
  entry
end

# --- sidebar ---------------------------------------------------------

WIDGETS = {
  'toots' => %w[account_id limit],
  'pixelfed' => %w[feed_url limit],
  # `instance` is what 1.4 added: the same card reads Gitea and Forgejo,
  # and without a question here the only way to set it was editing
  # site.yml by hand -- while the wizard went on asking for a "GitHub
  # username" on a site pointed at Codeberg.
  'commits' => %w[username instance limit],
  'bluesky' => %w[limit],
  'rss' => %w[feed_url limit]
}.freeze

def section_widgets
  loop do
    # Refreshed on every pass: `current` alone is the file as it was when
    # the run started, so a widget configured a moment ago -- in this very
    # loop -- was missing from its own state line. Minus what this run has
    # switched off, which no merge of pending SETS can know about.
    refresh_current
    active = SiteConfig::Chrome.map(current, 'widgets').keys - removed_widgets.to_a
    state = [Tui.paint(t('widgets_current', list: active.empty? ? t('list_empty') : active.join(', ')), :dim)]
    options = WIDGETS.keys.map { |name| [name, t("widget_#{name}")] }
    # Adding one was the only thing on offer; a widget switched on by
    # mistake -- or one whose account no longer exists -- could only be
    # got rid of by editing site.yml by hand.
    options << ['remove', t('q_widget_remove')] if active.any?
    options << ['keep', t('list_keep')]
    chosen = Wizard.choose(t('q_widget'), options, current_index: options.size - 1, note: state)
    break if chosen == 'keep'

    chosen == 'remove' ? remove_widget(active) : configure_widget(chosen)
  end
  puts
end

def remove_widget(active)
  # A hand-written widget key the wizard has no name for is still one
  # somebody may want gone -- it goes in the list under its own key
  # rather than aborting the run on a missing translation.
  options = active.map { |name| [name, WIDGETS.key?(name) ? t("widget_#{name}") : name] }
  options << ['keep', t('list_keep')]
  name = Wizard.choose(t('q_widget_which_remove'), options, current_index: options.size - 1)
  return if name == 'keep'

  site.deactivate(['widgets', name])
  removed_widgets << name
  # Commented out, not deleted: the heading and the account id stay in the
  # file, so switching the widget back on later is one answer rather than
  # a re-typing.
  Wizard.say(t('widget_removed', name: name), :green)
  Wizard.say('')
end

def removed_widgets
  @removed_widgets ||= []
end

def configure_widget(name)
  # Setting one up again is the undo for having removed it.
  removed_widgets.delete(name)
  heading = Wizard.ask(t('q_widget_heading'),
                       at('widgets', name, 'heading') || inactive_default(name, 'heading') || t("widget_heading_#{name}"))
  site.set(['widgets', name, 'heading'], heading) if heading

  WIDGETS[name].each do |key|
    value = Wizard.ask_valid(t("q_widget_#{key}"),
                             at('widgets', name, key) || inactive_default(name, key) || default_for(key),
                             hint: t("h_widget_#{key}")) do |answer|
      if key == 'limit'
        t('e_limit') unless answer.to_s.match?(/\A[1-9]\d*\z/)
      elsif key == 'account_id'
        # The mistake this whole prompt exists to catch: the @handle goes
        # in, nothing comes out, and nothing anywhere says why. What an
        # id may look like (Mastodon numbers, GoToSocial ULIDs) lives in
        # lib/account_id.rb, shared with doctor.
        t('e_account_id') unless AccountId.plausible?(answer)
      elsif key == 'feed_url'
        t('e_feed_url') unless answer.to_s.match?(%r{\Ahttps?://})
      elsif key == 'instance'
        # Empty means GitHub, which is the answer most people want and the
        # behaviour without the key. Anything else is checked the way
        # doctor checks it, so a typo is caught here rather than becoming
        # an empty card nobody can tell from "has not pushed lately".
        next if answer.to_s.strip.empty?

        if ForgeAddress.base(answer).nil?
          t('e_widget_instance')
        elsif ForgeAddress.path_under_host?(answer)
          t('e_widget_instance_repo')
        end
      end
    end
    next unless value

    # An empty instance is not a value, it is the default: writing
    # `instance: ""` would leave doctor complaining about a key the person
    # deliberately left blank.
    next if key == 'instance' && value.to_s.strip.empty?

    site.set(['widgets', name, key], key == 'limit' ? value.to_i : value)
  end
  # Into the frame: the widget menu repaints as soon as this returns, and
  # the sentence names the cron job without which the widget stays empty.
  Wizard.say(t('widget_set', name: name), :green)
  Wizard.say('')
end

def default_for(key)
  key == 'limit' ? 3 : nil
end

# The answer a removal left commented in the config -- the other half of
# the promise "switching it back on is one answer". The template's own
# placeholder is not an answer somebody gave: offered as a default, an
# Enter-through would write account_id "000000000000000000" into a live
# widget, so anything equal to the example's value at the same path is
# treated as no answer at all.
def inactive_default(name, key)
  value = site.inactive_value(['widgets', name, key.to_s])
  return nil if value.nil?

  value == example_config.inactive_value(['widgets', name, key.to_s]) ? nil : value
end

def example_config
  @example_config ||= ConfigWriter::YamlFile.new(SITE_YML_EXAMPLE)
end

# --- fonts and analytics ---------------------------------------------

def section_fonts
  Wizard.say(t('fonts_intro'), :dim)
  Wizard.say('')
  {
    'banner_title' => t('q_font_title'), 'banner_title_size' => t('q_font_title_size'),
    'banner_claim' => t('q_font_claim'), 'banner_claim_size' => t('q_font_claim_size')
  }.each do |key, label|
    value = Wizard.ask(label, at('fonts', key), hint: t("h_font_#{key}"))
    site.set(['fonts', key], value) if value
  end
  puts
  section_font_faces
end

# Self-hosted faces. Declaring one here is what makes its name usable in
# the stacks above -- naming a family the browser has never been given
# silently falls back, and the banner then looks like the setting simply
# did not work.
def section_font_faces
  entries = at('fonts', 'faces')
  entries = [] unless entries.is_a?(Array)
  entries = entries.select { |e| e.is_a?(Hash) }
  touched = false

  loop do
    # `note:` -- see section_extra_css.
    state = [Tui.paint(t('faces_current'), :bold)]
    if entries.empty?
      state << Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index do |e, i|
        mark = font_file_exists?(e['file']) ? '' : "  #{t('faces_missing_mark')}"
        state << "   #{i + 1}) #{e['family']} -- #{e['file']}#{mark}"
      end
    end

    options = [['add', t('list_add')]]
    options << ['remove', t('list_remove')] unless entries.empty?
    options << ['keep', t('list_keep')]
    case Wizard.choose(t('q_faces_action'), options, current_index: options.size - 1, note: state)
    when 'add'
      entry = ask_font_face
      next unless entry

      entries << entry
      touched = true
    when 'remove'
      entries = remove_from(entries) { |e| "#{e['family']} -- #{e['file']}" }
      touched = true
    else
      break
    end
  end

  site.set_list(%w[fonts faces], entries) if touched
  puts
end

def font_file_exists?(file)
  return false if file.to_s.strip.empty?

  name = File.basename(file.to_s)
  File.file?(File.join(ROOT, 'assets', 'fonts', name)) || queued?("/assets/fonts/#{name}")
end

# Only the file NAME is stored -- the engine looks in assets/fonts/ and a
# path there would resolve to nothing. weight and style are optional and
# left out when empty rather than written as blanks, which is what the
# reader of the config would have to interpret otherwise.
def ask_font_face
  family = Wizard.ask(t('q_face_family'), '', hint: t('h_face_family')).to_s.strip
  return nil if family.empty?

  answer = Wizard.ask(t('q_face_file'), '', hint: t('h_face_file')).to_s.strip
  file = File.basename(answer)
  return nil if file.empty?

  unless font_file_exists?(file)
    source = resolve_source(answer)
    if source && File.file?(source)
      href = "/assets/fonts/#{file}"
      Wizard.say("   #{t('file_will_go', path: href)}", :green)
      queue_file(source, href)
    else
      return nil unless Wizard.confirm(t('q_faces_anyway'),
                                       note: t('faces_not_found', file: file))
    end
  end

  entry = { 'family' => family, 'file' => file }
  weight = Wizard.ask(t('q_face_weight'), '', hint: t('h_face_weight')).to_s.strip
  entry['weight'] = weight unless weight.empty?
  style = Wizard.ask(t('q_face_style'), '', hint: t('h_face_style')).to_s.strip
  entry['style'] = style unless style.empty?
  entry
end

def section_analytics
  src = Wizard.ask(t('q_analytics_src'), at('analytics', 'src'), hint: t('h_analytics_src'))
  if src.to_s.empty?
    Wizard.say(t('analytics_skipped'), :dim)
    Wizard.say('')
    return
  end

  site.set(%w[analytics src], src)
  id = Wizard.ask(t('q_analytics_id'), at('analytics', 'website_id'), hint: t('h_analytics_id'))
  site.set(%w[analytics website_id], id) if id
  puts
end

# --- list editing ----------------------------------------------------

def edit_list(entries, fields)
  entries = [] unless entries.is_a?(Array)
  loop do
    # `note:` -- see section_extra_css.
    state = [Tui.paint(t('list_current'), :bold)]
    if entries.empty?
      state << Tui.paint("   #{t('list_empty')}", :dim)
    else
      entries.each_with_index { |e, i| state << "   #{i + 1}) #{yield(e)}" }
    end
    action = Wizard.choose(t('q_list_action'), [
                             ['add', t('list_add')],
                             ['remove', t('list_remove')],
                             ['keep', t('list_keep')]
                           ], current_index: 2, note: state)
    case action
    when 'add'
      entry = {}
      fields.each { |f| entry[f] = Wizard.ask(t("q_list_#{f}"), '') }
      # Answering nothing to every field means "never mind", not "add an
      # empty row" -- a footer link with no title and no address rendered
      # as a bare <li></li> on every page. Pressing Enter past the
      # questions is the wizard's documented way to back out.
      entries << entry unless entry.values.all? { |v| v.to_s.strip.empty? }
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
  # Esc gives nil, and nil is not an index: rejecting "the entry whose
  # position equals nil" matched nothing, so the list came back one item
  # shorter -- the FIRST one, which on a default site is the Mastodon link
  # carrying rel="me". Backing out of a question must leave the answer
  # exactly as it was.
  return entries if index.nil?

  entries.reject.with_index { |_, i| i == index }
end

# --- the menu --------------------------------------------------------

# In the order the page reads, top to bottom: the whole page first
# (palette), then the header (image, fonts, menu bar), the sidebar (bio, widgets),
# the footer (texts and links, then the icon row that lives in it), and
# last the one thing with no place on the page at all.
SECTIONS = [
  ['palette', 'section_palette'],
  ['banner', 'section_banner'],
  ['fonts', 'section_fonts'],
  ['layout', 'section_layout'],
  ['nav', 'section_nav'],
  ['about', 'section_about'],
  ['widgets', 'section_widgets'],
  ['footer', 'section_footer'],
  ['social', 'section_social'],
  ['analytics', 'section_analytics']
].freeze

def run
  puts SiteHeader.render(tool: './style.sh')
  puts
  # Into the frame context: the section menu is the next thing on screen
  # and repaints from the top, so a printed intro was gone before it had
  # said what Enter and Esc mean here.
  Wizard.say(t('intro'))
  Wizard.say('')
  Wizard.say(t('intro_skip'), :dim)
  Wizard.say('')

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

  # The blank line the review stands on. The section menu ends in the keys
  # row and closes it without a blank -- Tui.menu prints one newline, no
  # more, on the rule that whoever wants the blank writes it. Nobody did, so
  # the run's whole verdict arrived glued to the bottom edge of the menu:
  # "…· Esc dokončit" and under it, touching, "Nic se nezměnilo".
  puts
  outcome = Wizard.review_and_write([[relative(SITE_YML), site]], also: pending_review)
  # A refused or rolled-back write is exit 1 (a cancel at the diff stays 0
  # -- that is the user's choice, not a fault).
  exit 1 if outcome == :failed
  return unless outcome == :written

  install_pending_files
  offer_rebuild
end

# The in-memory config the prompts read from is the file plus everything
# set so far, so a section revisited in the same run sees its own edits.
def refresh_current
  merged = current
  site.intended.each do |path, value|
    node = merged
    # The same tolerance `at` has, for the same reason: this is a tool
    # people open BECAUSE their config is wrong, and a `widgets:` written
    # as a list ended the run here with the answers already given.
    path[0..-2].each do |k|
      node[k] = {} unless node[k].is_a?(Hash)
      node = node[k]
    end
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
  unless Wizard.confirm(t('q_rebuild'))
    puts
    return
  end

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
  # This is the last line ./style.sh ever prints, on all four ways out of
  # it, and every command reachable from the wizard ends on exactly one
  # blank line. This one ended on none -- down a pipe it did not even end on
  # a newline: the run stopped mid-row, on the rebuild question itself.
  puts
end

Wizard.guard { run }
