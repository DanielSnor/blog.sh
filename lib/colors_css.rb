# frozen_string_literal: true

# lib/colors_css.rb -- generates assets/css/colors.css: the one stylesheet
# that actually differs between two sites built on this engine. Everything
# the CSS needs beyond the seven configured colors per mode is derived
# here, and the header fonts (plus @font-face blocks for a site's own
# font files) ride along in the same file -- one generated stylesheet
# instead of two is what keeps typography changes at two changed files
# rather than a re-render of every page in the archive.
#
# Extracted from build/build_blog.rb so ./style.sh can render its palette
# preview through the exact code the build will use -- a preview rendered
# by a copy would drift, and a drifted preview is worse than none. Inputs
# are explicit (the raw `colors:` and `fonts:` hashes in config/site.yml's
# shape) rather than read from SiteConfig, because the preview's whole
# point is asking about colors that are not in the config yet.
module ColorsCss
  # Only these 7-per-mode keys (config/site.yml's `colors.light.*`/
  # `colors.dark.*`) are real per-site choices -- everything else the CSS
  # references (--card-bg, --nav-text, --nav-border, --hover-invert,
  # --badge-hover-text, --search-bg) is derived from them in
  # color_properties below, not separately configurable. They never varied
  # independently across every palette this engine has actually shipped,
  # so exposing them as their own config keys would just be more to fill
  # in for no real choice. Defaults to blog.sh's own blue palette when
  # `colors:` is absent (or partial).
  DEFAULT_COLORS = {
    'light' => {
      'bg' => '#f5f8fa', 'text' => '#444a5a', 'meta_text' => '#657784',
      'accent' => '#1da1f2', 'nav_bg' => '#eaf5fd', 'border' => '#e1e8ed',
      'pill_bg' => '#d6ecfc'
    },
    'dark' => {
      'bg' => '#111111', 'text' => '#ffffff', 'meta_text' => '#6a7f8c',
      'accent' => '#4ab3f4', 'nav_bg' => '#192734', 'border' => '#263340',
      'pill_bg' => '#16324a'
    }
  }.freeze

  COLOR_KEYS = %w[bg text meta_text accent nav_bg border pill_bg].freeze

  # Header typography. Same idea as the palette: the two lines painted over
  # the banner -- the site's name and its claim -- are a per-site choice, so
  # they live in config/site.yml (`fonts.*`) and reach the stylesheet as
  # custom properties. A site that says nothing keeps what the engine has
  # always used.
  #
  # Family and size are separate keys per line, because a font swap is
  # usually also a size decision: a serif set at 45px does not fill the
  # banner the way the monospace default does, and having to accept the old
  # number with a new face would make the setting half-useful.
  #
  # The narrow-screen sizes are NOT config: site.css scales them from these
  # with calc(), so the responsive step survives whatever unit someone writes
  # (px, rem, clamp()) without a second pair of keys to keep in sync.
  DEFAULT_FONTS = {
    'banner_title' => '"JetBrains Mono", "SF Mono", Menlo, Consolas, monospace',
    'banner_claim' => '"JetBrains Mono", "SF Mono", Menlo, Consolas, monospace',
    'banner_title_size' => '45px',
    'banner_claim_size' => '20px'
  }.freeze

  # What a font file may be called on the way into a @font-face, and what CSS
  # calls the format. Anything else is refused by name rather than written
  # into the stylesheet and left to fail in the browser.
  FONT_FORMATS = { '.woff2' => 'woff2', '.woff' => 'woff', '.ttf' => 'truetype', '.otf' => 'opentype' }.freeze

  # A value from config lands inside a CSS declaration, so it must not be
  # able to end one. Everything here would either break the stylesheet or
  # smuggle in rules of its own -- a font stack needs none of it.
  # Comment markers belong here too: a font name carrying "/*" opens a
  # comment that swallows everything after it -- in the generated file
  # that was the entire light palette, silently, and the site came out in
  # the browser's own default colours with nothing said anywhere.
  CSS_VALUE_FORBIDDEN = %r{[;{}<>@\\\n\r]|/\*|\*/}

  module_function

  def generate(colors: nil, fonts: nil, fonts_dir: nil)
    colors = {} unless colors.is_a?(Hash)
    fonts = {} unless fonts.is_a?(Hash)
    <<~CSS
      /* Generated at build time from config/site.yml (`colors:` and `fonts:`)
         -- edit the config and rebuild, don't edit this file by hand. */
      #{font_face_css(fonts, fonts_dir)}:root {
        --banner-title-font: #{font_setting(fonts, 'banner_title')};
        --banner-claim-font: #{font_setting(fonts, 'banner_claim')};
        --banner-title-size: #{font_setting(fonts, 'banner_title_size')};
        --banner-claim-size: #{font_setting(fonts, 'banner_claim_size')};
      }

      :root,
      :root[data-theme="light"] {
      #{color_declarations(colors, 'light', '  ')}
      }

      /* WARNING: the dark values appear twice below and must stay identical.
         CSS can't share a declaration block across an @media boundary, so
         "follow the system" and "explicitly switched" can't be written
         together. (A single declaration would be possible via light-dark(),
         but that needs Safari 17.5+ / Chrome 123+, and colors would fall
         apart completely in older browsers.) */
      @media (prefers-color-scheme: dark) {
        :root:not([data-theme="light"]) {
      #{color_declarations(colors, 'dark', '    ')}
        }
      }

      :root[data-theme="dark"] {
      #{color_declarations(colors, 'dark', '  ')}
      }
    CSS
  end

  def color_for(colors, mode, key)
    # Shape-guarded like generate() itself: a `colors:` written as a list
    # must degrade to the default palette everywhere, not TypeError in
    # whichever caller asked first (theme-color did).
    per_mode = colors.is_a?(Hash) ? colors[mode] : nil
    raw = per_mode.is_a?(Hash) ? per_mode[key] : nil
    # Through the same CSS-value guard the fonts use: a colour is a hex or
    # rgb() or a name, none of which carry ';', '{', a comment marker or a
    # newline -- and one that does (a hand-edit typo, a value from an
    # imported palette) would otherwise be written verbatim into
    # colors.css and take the rest of the stylesheet down with it, silently.
    # A rejected value falls back to the shipped default, said out loud.
    safe_css_value(raw, "colors.#{mode}.#{key}") || DEFAULT_COLORS[mode][key]
  end

  def color_properties(colors, mode)
    text = color_for(colors, mode, 'text')
    meta_text = color_for(colors, mode, 'meta_text')
    nav_bg = color_for(colors, mode, 'nav_bg')
    {
      'bg' => color_for(colors, mode, 'bg'),
      # White in light mode (a card floating on a tinted page), but in dark
      # mode it's the same tinted surface as the nav bar, not white -- true
      # across every palette this engine has shipped (orange/bluebird/garden/
      # sunflower all set dark card-bg == dark nav-bg exactly).
      'card-bg' => mode == 'dark' ? nav_bg : '#ffffff',
      # The footer's own surface, and the one place a value is chosen per
      # mode rather than taken from the palette. In light mode the nav bar's
      # colour is what makes the footer read as a band -- which is what it
      # was given in 1.3. In dark mode that same value is ALSO the card
      # colour (the line above), so the band never appeared: the footer, the
      # cards and the bar were one surface divided by hairlines. The page
      # background is the only shipped colour darker than the cards, so the
      # footer sinks rather than rises -- which is what a footer does anyway.
      #
      # On `contrast` this changes nothing, and deliberately: that palette
      # sets bg and nav_bg to the same black and divides by lines, not by
      # planes. Measured across the seven shipped palettes: six gain a band,
      # sunflower gains a quiet one (its bg is #241708 against #3a2a14
      # cards), contrast keeps its lines.
      'footer-bg' => mode == 'dark' ? color_for(colors, mode, 'bg') : nav_bg,
      'text' => text,
      'meta-text' => meta_text,
      'accent' => color_for(colors, mode, 'accent'),
      'nav-bg' => nav_bg,
      'nav-text' => text,
      'border' => color_for(colors, mode, 'border'),
      'nav-border' => meta_text,
      'pill-bg' => color_for(colors, mode, 'pill_bg'),
      'search-bg' => mode == 'dark' ? '#eeeeee' : '#ffffff',
      'hover-invert' => mode == 'dark' ? '#ffffff' : meta_text,
      'badge-hover-text' => mode == 'dark' ? 'var(--accent)' : '#ffffff',
      # Independently optional (config/site.yml's colors.<mode>.banner_title/
      # banner_claim) since the banner overlay's title and claim can be shown
      # or colored independently -- see BANNER_SHOW_TITLE/_CLAIM in
      # build/build_blog.rb. Same default either falls back to as before this
      # pair existed: nav-bg in light mode (a readable tone against most
      # banner images without being pure white), white in dark mode.
      'banner-title-color' => color_for_optional(colors, mode, 'banner_title') || (mode == 'dark' ? '#ffffff' : nav_bg),
      'banner-claim-color' => color_for_optional(colors, mode, 'banner_claim') || (mode == 'dark' ? '#ffffff' : nav_bg)
    }
  end

  # The two overlay colors have no entry in DEFAULT_COLORS -- their absence
  # means "derive from the palette", not "use a shipped constant".
  def color_for_optional(colors, mode, key)
    per_mode = colors[mode]
    raw = per_mode.is_a?(Hash) ? per_mode[key] : nil
    safe_css_value(raw, "colors.#{mode}.#{key}")
  end

  def color_declarations(colors, mode, indent)
    color_properties(colors, mode).map { |name, value| "#{indent}--#{name}: #{value};" }.join("\n")
  end

  def font_setting(fonts, key)
    safe_css_value(fonts[key], "fonts.#{key}") || DEFAULT_FONTS[key]
  end

  # @font-face blocks for the files a site dropped into assets/fonts/ and
  # declared in `fonts.faces`. The engine's own bundled faces stay in
  # site.css: they ship with the engine, these belong to the installation.
  #
  # A declared file that isn't there is said out loud. Silence would mean a
  # site quietly rendering in its fallback font, which looks like the config
  # not working and gives nothing to go on.
  def font_face_css(fonts, fonts_dir)
    faces = fonts['faces']
    # A mapping instead of a list is the shape somebody writes when they
    # have one face: `faces:` then `family:` under it. Skipping it without
    # a word left them with a config that looks right and a site with no
    # custom font, and nothing to go on.
    if faces && !faces.is_a?(Array)
      warn_face("fonts.faces has to be a list of entries (each with family and file), not #{faces.class.to_s.downcase}")
      return ''
    end
    return '' unless faces.is_a?(Array) && faces.any?

    blocks = faces.filter_map { |face| font_face_block(face, fonts_dir) }
    blocks.empty? ? '' : "#{blocks.join("\n")}\n\n"
  end

  def font_face_block(face, fonts_dir)
    return warn_face('an entry under fonts.faces is not a family/file pair') unless face.is_a?(Hash)

    family = safe_css_value(face['family'].to_s.delete('"'), 'fonts.faces family')
    file = File.basename(face['file'].to_s)
    return warn_face("#{face.inspect} needs both `family` and `file`") if family.nil? || file.empty?

    format = FONT_FORMATS[File.extname(file).downcase]
    return warn_face("#{file} is not a web font format (#{FONT_FORMATS.keys.join(', ')})") unless format
    return warn_face("#{file} is declared in config/site.yml but not in assets/fonts/") unless fonts_dir && File.exist?(File.join(fonts_dir, file))

    weight = safe_css_value(face['weight'], 'fonts.faces weight') || '400 700'
    style = %w[normal italic oblique].include?(face['style'].to_s) ? face['style'] : 'normal'
    <<~FACE.chomp
      @font-face {
        font-family: "#{family}";
        font-style: #{style};
        font-weight: #{weight};
        font-display: swap;
        src: url("/assets/fonts/#{file}") format("#{format}");
      }
    FACE
  end

  def safe_css_value(value, what)
    text = value.to_s.strip
    return nil if text.empty?
    found = text[CSS_VALUE_FORBIDDEN]
    return text unless found

    # Named by what actually matched -- a hand-kept list drifted the
    # moment the pattern learnt about comment markers, and the sentence
    # then blamed characters the value demonstrably did not contain.
    shown = { "\n" => '\\n', "\r" => '\\r' }.fetch(found, found)
    warn "⚠️  config/site.yml: #{what} contains #{shown.inspect}, which can't go into CSS -- ignoring it."
    nil
  end

  def warn_face(message)
    warn "⚠️  config/site.yml: #{message} -- that face is skipped."
    nil
  end
end
