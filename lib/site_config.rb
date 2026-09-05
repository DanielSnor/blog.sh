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
    begin
      YAML.load_file(path, aliases: true) || {}
    rescue ArgumentError
      YAML.load_file(path) || {}
    end
  rescue Psych::SyntaxError => e
    # A hand-edited config with a stray tab or an unquoted colon used to
    # surface as a Psych backtrace from whichever entry point happened to
    # read the file first -- an unreadable answer to the single most
    # common way this file breaks. The line number is what fixes it, and
    # Psych knew it all along.
    # The line is where the parser gave up, which is not always where the
    # mistake is: an indented block whose header got commented out, or a
    # quote left open, breaks at the first thing that no longer fits --
    # often further down the file, and sometimes further up, inside the
    # section before it. Said out loud, because the first person to report
    # this had read the named line, found it blameless, and gone looking
    # through the engine's source instead.
    abort("❌ #{path} is not valid YAML: #{e.problem} at line #{e.line}, column #{e.column}. " \
          "Usually indentation (spaces only, never tabs), a missing quote, or a colon inside an unquoted value. " \
          "If that line looks fine, the cause is elsewhere -- most often a commented-out section header " \
          "with its keys left behind, or an unclosed quote earlier. " \
          "Run ./blog.sh doctor for the full picture.")
  rescue SystemCallError => e
    # A file that exists but cannot be OPENED. Wrong owner after a wizard
    # ran under sudo is the usual story, and until this rescue existed the
    # build answered it with Psych's own backtrace -- eight frames naming
    # psych.rb and feed_http.rb, and nowhere the sentence "check the
    # permissions on this one file". doctor had the sentence all along;
    # this is the same one, said by whoever gets there first.
    abort("❌ #{path} cannot be read: #{e.message}. " \
          "Check the file's owner and permissions (ls -l config/site.yml). Usually: " \
          "chmod 644 config/site.yml -- and if the file is owned by root after a wizard " \
          "ran under sudo, chown it too. Run ./blog.sh doctor for the full picture.")
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

  # Whether a key is WRITTEN DOWN, as opposed to what it holds. `get` cannot
  # answer this: a key with nothing under it and no key at all both read as
  # nil, and for a list they mean opposite things -- "I want none of these"
  # against "decide for me". Only the file itself knows which was typed.
  def key?(*keys)
    return false unless File.exist?(PATH)

    parent = keys[0..-2].reduce(data) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
    parent = data if keys.length == 1
    parent.is_a?(Hash) && parent.key?(keys.last)
  end


  # --- what the chrome's keys mean -----------------------------------------
  #
  # The chrome (nav, about, footer, social, widgets, layout) is configured
  # in one file and read by three programs, and until now each of them
  # worked out the meaning for itself: the build asked "is this key written
  # down", ./style.sh asked "is it an Array", and doctor asked neither. So a
  # widget name with a typo in it took the whole sidebar off every page
  # while doctor called the config healthy, and an `about:` written as a
  # list ended the build in a TypeError from inside an ERB template.
  #
  # Four states, one answer for all three programs:
  #   absent    -- nothing is written; the engine decides. Never an error.
  #   empty     -- written with nothing under it; the site decided: none of
  #                these. Never an error.
  #   malformed -- written in a shape the key cannot hold. Read as empty
  #                everywhere (never a traceback), and always said out loud.
  #   set       -- the site's own answer.
  module Chrome
    # The five cards the sidebar can draw. One list, because it used to be
    # copied into four places and the copy in doctor was missing one of
    # them -- which is exactly why an unknown name passed the check meant
    # to catch it.
    CARDS = %w[toots pixelfed commits bluesky rss].freeze
    # Every key the engine reads back with `list` belongs here, or the four
    # states above do not apply to it and the key falls back to being read
    # as empty in silence. `share` was missing until the shape check learned
    # it, and `tag_icons` was the last one left: a mapping under it --
    # `tag_icons:` with `kolo: bike` indented beneath, which is how half of
    # site.yml is written -- gave the site no icons, the build no warning
    # and doctor a clean bill of health. It stays a list because the order
    # in it is the priority, and a mapping cannot say an order out loud.
    LISTS = [%w[nav], %w[social], %w[share], %w[footer links], %w[tag_icons]].freeze
    MAPS = [%w[about], %w[footer], %w[widgets], %w[layout]].freeze
    # The chrome's prose. Written as a list or a map it renders as nothing
    # at all -- the page simply loses its about text, and until now without
    # a word from anywhere.
    TEXTS = [%w[about html], %w[about heading], %w[footer note_html],
             %w[footer note_heading], %w[footer copyright], %w[banner claim]].freeze

    module_function

    def dig(data, *path)
      path.reduce(data) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    end

    # Whether the key is WRITTEN DOWN, which is a different question from
    # what it holds: `nav:` with nothing under it means "no menu", and no
    # `nav:` at all means "engine, decide".
    def written?(data, *path)
      parent = path.length == 1 ? data : dig(data, *path[0..-2])
      parent.is_a?(Hash) && parent.key?(path.last)
    end

    def state(data, *path, shape: :list)
      return :absent unless written?(data, *path)

      value = dig(data, *path)
      return :empty if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      return :set if shape == :list ? value.is_a?(Array) : value.is_a?(Hash)

      :malformed
    end

    # Always the right class, whatever the file says.
    def list(data, *path)
      value = dig(data, *path)
      value.is_a?(Array) ? value : []
    end

    def map(data, *path)
      value = dig(data, *path)
      value.is_a?(Hash) ? value : {}
    end

    # Only names the sidebar can draw, each holding settings.
    def widgets(data)
      map(data, 'widgets').select { |name, conf| CARDS.include?(name) && conf.is_a?(Hash) }
    end

    # What the build will actually render from a nav entry: a label and
    # somewhere to go.
    def nav_item?(entry)
      return false unless entry.is_a?(Hash)

      label = entry['label'].to_s.strip
      target = entry['tag'].to_s.strip.empty? ? entry['url'].to_s.strip : entry['tag'].to_s.strip
      !label.empty? && !target.empty?
    end

    # Everything the config says that the engine cannot use, as data rather
    # than as sentences -- so the build's warnings and doctor's findings
    # cannot name a different set of keys from each other.
    def complaints(data)
      found = []
      LISTS.each { |path| found << [:not_a_list, path.join('.')] if state(data, *path, shape: :list) == :malformed }
      MAPS.each { |path| found << [:not_a_map, path.join('.')] if state(data, *path, shape: :map) == :malformed }
      map(data, 'widgets').each do |name, conf|
        next found << [:unknown_widget, name] unless CARDS.include?(name)

        found << [:widget_shape, name] unless conf.is_a?(Hash)
      end
      list(data, 'nav').each_with_index { |entry, i| found << [:nav_item, i + 1] unless nav_item?(entry) }
      TEXTS.each do |path|
        value = dig(data, *path)
        found << [:not_text, path.join('.')] unless value.nil? || value.is_a?(String) || value.is_a?(Numeric)
      end
      found
    end

    # The same complaints as sentences, in the site's language. doctor has
    # had these since 1.3.1; the build printed the raw identifiers next to
    # the raw key ("config/site.yml: not_a_list -- nav"), in English, on a
    # Czech site -- and it is the build that most people see first.
    def complaint_sentences(data, translate)
      complaints(data).map do |kind, what|
        key = COMPLAINT_KEYS.fetch(kind, 'list_shape')
        translate.call(key, what)
      end
    end

    COMPLAINT_KEYS = {
      not_a_list: 'list_shape', not_a_map: 'map_shape', unknown_widget: 'widget_unknown',
      widget_shape: 'widget_shape', nav_item: 'nav_item_shape', not_text: 'text_shape'
    }.freeze
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

  # How a reply earns its place under the article: :fav means the author
  # favourited it on the network, nil means every reply shows (what every
  # install did before this existed, and still the default).
  #
  # Off is not merely the safe default, it is a different data path: with
  # moderation off the visitor's browser reads the live thread from the
  # network, as always. With it on, the thread cannot be judged in the
  # browser at all -- "did *I* favourite this" is an authenticated
  # question and the token can never leave the server -- so the comments
  # are prepared by cron and served from this origin instead. Turning it
  # on therefore also makes the comments depend on that cron running (see
  # scripts/refresh-sidebar.sh and Doctor.check_comments).
  # YAML reads an unquoted off/no as the boolean false, which means the
  # documented `approval: off` arrives here as "false" -- it has to be
  # understood, not rejected. Its opposite (`on`/`yes` -> true) is not
  # accepted in return: there is one mode today and guessing which one
  # somebody meant would be a decision the config never made. The
  # message says what YAML did, since the value it names is not the
  # value that was typed.
  def comments_approval
    value = get('comments', 'approval').to_s.strip.downcase
    return nil if value.empty? || value == 'off' || value == 'false'
    return :fav if %w[fav favourite favorite].include?(value)

    if value == 'true'
      abort("❌ comments.approval is on/yes in #{PATH}, which YAML reads as true -- write the mode by name: \"fav\".")
    end

    abort("❌ Unknown comments.approval #{value.inspect} in #{PATH} -- expected \"fav\" or \"off\".")
  end
end
