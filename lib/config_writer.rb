# frozen_string_literal: true

require 'json'
require 'yaml'
require 'fileutils'
require_relative 'atomic_write'
require_relative 'yaml_compat'

# lib/config_writer.rb -- changes a value in config/site.yml or env.sh
# without touching anything else in the file.
#
# The obvious implementation -- load the YAML, change the hash, dump it
# back -- is the one thing this must not do. config/site.yml.example is
# 277 lines of which only about 60 are keys; the rest is the documentation
# for every setting the engine has, and the commented-out blocks
# (widgets:, fonts:, analytics:) are the templates you uncomment when you
# want one. YAML.dump would throw all of it away, reflow the folded
# scalars, and hand back a file nobody can hand-edit afterwards. Real
# installs are hand-edited -- sean.cz keeps an <img> inside about.html's
# folded block -- so a config tool that destroys hand-editing is worse
# than no config tool.
#
# So: the file is edited as TEXT, one line at a time, and everything the
# edit doesn't name stays byte-for-byte identical.
#
# The move that makes this tractable is seeding: a config that doesn't
# exist yet is created by copying the .example verbatim (comments and
# all), so every key this writer will ever be asked to set is ALREADY IN
# THE FILE -- either active or commented out. The writer therefore never
# has to invent structure, decide where a new section belongs, or guess
# an indentation; it only ever activates a commented line and substitutes
# a value. A key that is genuinely absent (a hand-written config predating
# the template) is a loud error, not an invented block -- see fetch_line.
#
# Anchoring, and why it isn't optional: commented lines can't be indexed
# by "uncomment everything and parse", because prose comments in the
# template parse as keys too --
#
#     # Optional: posts per listing page (default 10). Set it ONCE, before
#     # url: here has to be your profile as Mastodon shows it
#
# would index as `Optional:` and `url:`. Every lookup is therefore
# anchored to BOTH the exact key name and the exact indentation its
# parent implies, and the result is verified by reparsing the file after
# the write (see save!). A prose line would have to impersonate the key
# name at the right depth to slip through, and even then the reparse
# catches it.
module ConfigWriter
  # Raised for a key the file doesn't contain in any form. Callers turn
  # this into "your config predates this setting, here's the block to
  # paste" rather than letting it reach the user as a backtrace.
  class MissingKey < StandardError; end

  # Raised when the shipped template a file would be seeded from is not on
  # disk. A MissingKey by inheritance, because that is what it is -- but
  # its own class, because the answer is not "your config is missing a
  # setting" but "config/site.yml.example is gone, put it back". Without
  # it, a tree whose template had been deleted met both wizards with a
  # five-line Ruby backtrace out of the constructor, before either had
  # asked a single question.
  # A file that is there and cannot be opened -- a permission bit, a
  # directory in its place, an unmounted volume. Its own class rather than
  # a bare Errno, so Wizard.guard can say a sentence about it the way it
  # already does for a missing template: both wizards died on a raw
  # backtrace before the first question otherwise, and the guard's own
  # comment says TemplateMissing exists precisely so that the one failure
  # a fresh checkout can produce is a sentence.
  class Unreadable < StandardError
    attr_reader :path

    def initialize(path, cause)
      @path = path
      super("#{path}: #{cause}")
    end
  end

  class TemplateMissing < MissingKey
    attr_reader :path

    def initialize(path)
      @path = path
      super("no template at #{path}")
    end
  end

  # Raised when the file we just wrote doesn't parse back to the values we
  # put in it. The file is restored before this is raised -- see save!.
  class VerificationFailed < StandardError; end

  # Raised when the filesystem refuses the write itself: the file (or the
  # backup written beside it) belongs to somebody else, the disk is full,
  # the mount is read-only. Its own class because it is not a fault in the
  # config and nothing about it is fixable by editing one -- and because
  # the alternative was what actually happened on a live installation: the
  # raw Errno travelled through the wizard, which rescues only
  # VerificationFailed, and out through Wizard.guard, which rescues only
  # Interrupt, so somebody trying to change one line of their footer got a
  # Ruby backtrace three times in a row and no idea what to do about it.
  #
  # The backup is the first thing save! writes, which is the part nobody
  # expects: a config the user CAN write is still unwritable when the .bak
  # beside it is not theirs -- the usual leftover of one run made as root.
  class NotWritable < StandardError; end

  INDENT = 2

  # A minimal diff of two line arrays, as ["-old\n", "+new\n", ...].
  #
  # Line-for-line comparison is not good enough here, and the way it
  # fails matters: adding one entry to a list shifts every line below it
  # by one, so a one-line change is reported as "everything from here to
  # the end of the file changed". This diff is shown to somebody who is
  # about to approve a write to their own config -- reading as though
  # the tool intends to rewrite the whole thing is the one impression it
  # must not give.
  #
  # Plain LCS by dynamic programming. These files are a few hundred
  # lines, so the quadratic table is a rounding error, and the code is
  # short enough to be obviously right -- which matters more here than
  # the cleverness of Myers.
  def self.diff_lines(before, after)
    lcs = Array.new(before.size + 1) { Array.new(after.size + 1, 0) }
    before.size.downto(1) do |i|
      after.size.downto(1) do |j|
        lcs[i - 1][j - 1] = if before[i - 1] == after[j - 1]
                              lcs[i][j] + 1
                            else
                              [lcs[i][j - 1], lcs[i - 1][j]].max
                            end
      end
    end

    out = []
    i = 0
    j = 0
    while i < before.size && j < after.size
      if before[i] == after[j]
        i += 1
        j += 1
      elsif lcs[i + 1][j] >= lcs[i][j + 1]
        out << "-#{before[i]}"
        i += 1
      else
        out << "+#{after[j]}"
        j += 1
      end
    end
    out.concat(before[i..].map { |l| "-#{l}" }) if i < before.size
    out.concat(after[j..].map { |l| "+#{l}" }) if j < after.size
    out
  end

  # A YAML scalar for a Ruby value, with the quoting YAML requires.
  #
  # Strings go through JSON: YAML 1.2 is a JSON superset, so a JSON string
  # literal is always a valid double-quoted YAML scalar, with the escaping
  # and the UTF-8 handling already correct. It also means values that look
  # like other types to YAML -- "#f5f8fa" (a comment!), "no" (false),
  # "09:30" (sexagesimal in YAML 1.1) -- come out quoted without a table
  # of special cases here.
  def self.scalar(value)
    case value
    when String then JSON.generate(value)
    when Integer, Float then value.to_s
    when true, false then value.to_s
    when nil then ''
    else JSON.generate(value.to_s)
    end
  end

  # What would stop save! from replacing this path, as a path to name --
  # the directory that will hold the atomic temp, or the .bak if one would
  # be made -- and nil when nothing would. Read-only, so review_and_write
  # can ask about EVERY file before it writes the first: the whole point of
  # the wizard's "nothing was written" is that it is true, and it stopped
  # being true the day two files were written in turn and the second was
  # refused.
  #
  # It answers for exactly what save! does and not one check more. A
  # refusal here ends the run on exit 1, so a check save! does not make is
  # not caution, it is a wizard that dead-ends where it used to recover:
  #
  #   * The file itself is deliberately NOT consulted. AtomicWrite writes a
  #     sibling temp and renames it over the target, which needs the
  #     DIRECTORY, not the file -- a root-made config the app user cannot
  #     open for writing is replaced perfectly well, and refusing it left
  #     both wizards dead on a `docker exec` leftover they used to survive.
  #   * The .bak matters only when there is a file to copy into it, which
  #     is save!'s own `had_file` (EnvFile.save! makes the same test). With
  #     no config yet -- delete the mangled one and re-run the wizard, the
  #     most ordinary recovery there is -- no backup is made, and a
  #     leftover one is not in the way of anything.
  def self.write_blocker(path, backup: true)
    dir = File.dirname(path)
    return dir unless File.writable?(dir)

    bak = "#{path}.bak"
    return bak if backup && File.exist?(path) && File.exist?(bak) && !File.writable?(bak)

    nil
  end

  # Strips one level of commenting: the first '#' and at most one space
  # after it, keeping what precedes it. One rule covers both shapes the
  # template uses --
  #
  #   "# widgets:"          -> "widgets:"        (block commented at col 0)
  #   "#   toots:"          -> "  toots:"        (its children, indent inside)
  #   "  # page_size: 10"   -> "  page_size: 10" (optional key, indent outside)
  #   "#     # instance:"   -> "    # instance:" (nested optional: stays off)
  #
  # -- and the last line is the reason it strips exactly one level and not
  # all of them: an optional key inside an optional block must still be
  # optional after its block is activated.
  def self.uncomment(line)
    line.sub(/\A(\s*)#[ ]?/) { Regexp.last_match(1) }
  end

  def self.comment?(line)
    line.match?(/\A\s*#/)
  end

  # Rewrites a commented line so its indentation sits BEFORE the '#'.
  #
  # The template writes the inside of an optional block with the '#' at
  # column 0 ("#     heading:"), because there the whole block is off. A
  # file where that block is ON writes its own inactive keys the other way
  # round ("    # heading:") -- compare banner.show_title in the template.
  # Grafting a block from the first form into the second without this
  # produces a config whose commented lines all hug the left margin inside
  # an indented section: valid, and visibly wrong.
  #
  # A line that is commented twice (an optional key, or prose, inside an
  # optional block) loses exactly the level the block itself would have
  # lost -- so it stays inactive either way, which is what both forms mean.
  def self.normalize_comment(line)
    return line unless comment?(line)

    bare = uncomment(line)
    return line if blank?(bare)

    indent = bare[/\A */]
    rest = bare.lstrip
    rest.start_with?('#') ? "#{indent}#{rest}" : "#{indent}# #{rest}"
  end

  def self.blank?(line)
    line.strip.empty?
  end

  # The indentation of a line's content, or nil when it has none to speak
  # of (blank). Comments are measured by what they'd be if activated,
  # which is what makes a commented block's extent measurable at all.
  def self.indent_of(line)
    return nil if blank?(line)

    effective = comment?(line) ? uncomment(line) : line
    return nil if blank?(effective)

    effective[/\A */].length
  end

  # Does this line declare `key` at exactly `indent` columns? Active and
  # commented lines both answer; the caller decides which it wanted.
  def self.declares?(line, key, indent)
    effective = comment?(line) ? uncomment(line) : line
    effective.match?(/\A {#{indent}}#{Regexp.escape(key)}:(\s|\z)/)
  end

  # Edits one YAML file. Nothing touches disk until save!.
  class YamlFile
    attr_reader :path

    def initialize(path, template: nil)
      @path = path
      @template = template
      @original = read_or_seed
      @lines = @original.lines
      @intended = {}
    end

    # True once a set/activate/deactivate actually changed a byte. A
    # wizard run where the user pressed Enter through every question must
    # not rewrite the file at all -- and must not leave a .bak behind
    # suggesting it did.
    def changed?
      current != @original
    end

    def current
      @lines.join
    end

    # Everything this run has set, as key_path => value. For the caller
    # that has to answer "what would the config say if I saved now?"
    # before saving -- a wizard whose second visit to a section must
    # offer the value the first visit set, not the one still on disk.
    def intended
      @intended.dup
    end

    # The line where `key_path` is declared, active or commented, or nil.
    # Read-only, and bounded at every level: the search for each segment
    # happens only inside the previous segment's body, so a lookup for
    # widgets.rss.feed_url cannot wander into widgets.pixelfed's.
    def locate(key_path)
      range = (0...@lines.size)
      found = nil
      key_path.each_with_index do |key, depth|
        indent = depth * ConfigWriter::INDENT
        found = range.find { |i| ConfigWriter.declares?(@lines[i], key, indent) }
        return nil unless found

        range = ((found + 1)..value_extent(found))
      end
      found
    end

    # The value a COMMENTED key carries -- what ./style.sh's widget removal
    # leaves behind, kept precisely so switching the widget back on is one
    # answer rather than a re-typing. Only a singly-commented key answers:
    # a doubly-commented one is the template's way of shipping a key
    # deliberately OFF inside an optional block, and its value is prose,
    # not somebody's answer. The caller still has to filter out the
    # template's own placeholders; this method cannot tell an answer from
    # an example, only an inactive line from a deliberately hidden one.
    def inactive_value(key_path)
      line_no = locate(key_path)
      return nil if line_no.nil?

      line = @lines[line_no]
      return nil unless ConfigWriter.comment?(line)

      bare = ConfigWriter.uncomment(line)
      return nil if ConfigWriter.comment?(bare)

      scalar = bare.sub(/\A\s*[A-Za-z_][A-Za-z0-9_-]*:/, '').sub(/\s#.*$/, '')
      value = YAML.safe_load("v:#{scalar}")
      value && value['v']
    rescue StandardError
      nil
    end

    # A section as text: its declaration, its body, and the run of prose
    # comments documenting it directly above. Used to graft a section one
    # config is missing out of the template that has it -- which is how a
    # hand-written config from before a setting existed gets that setting
    # (with its documentation) instead of a dead end.
    #
    # The walk upwards stops at the first line that is itself structure,
    # not just at the first non-comment: `#   rss:` in the template sits
    # directly under `#     limit: 3`, and swallowing that would graft the
    # tail of the bluesky widget along with it.
    def block_for(key_path)
      decl = locate(key_path)
      return nil unless decl

      start = decl
      while start.positive?
        above = @lines[start - 1]
        break unless ConfigWriter.comment?(above) && !ConfigWriter.blank?(above)
        break if structure?(above)

        start -= 1
      end
      @lines[start..value_extent(decl)].join
    end

    # A leaf key's template text -- its line and the run of prose directly
    # above it -- located tolerantly, because the template ships an
    # optional key double-commented (`#     # instance:`) so uncommenting
    # its section wholesale leaves it off. locate/declares? strip one
    # comment level and miss it; this strips as many as it takes.
    # declares?, but seeing through ANY number of leading '#': the
    # template ships an optional key double-commented, and a whole section
    # commented once on top of that.
    def tolerant_declares?(line, key, indent)
      bare = line
      bare = ConfigWriter.uncomment(bare) while ConfigWriter.comment?(bare)
      bare.match?(/\A {#{indent}}#{Regexp.escape(key)}:(\s|\z)/)
    end

    # value_extent measured on the fully-uncommented indentation, so a
    # commented template block has a measurable body.
    def tolerant_extent(line_no)
      strip = lambda do |l|
        b = l
        b = ConfigWriter.uncomment(b) while ConfigWriter.comment?(b)
        ConfigWriter.blank?(b) ? nil : b[/\A */].length
      end
      indent = strip.call(@lines[line_no])
      last = line_no
      ((line_no + 1)...@lines.size).each do |i|
        li = strip.call(@lines[i])
        next if li.nil?
        break if li <= indent

        last = i
      end
      last
    end

    def leaf_block(key_path)
      # Bounded to the parent's own block, walked segment by segment --
      # otherwise a finder for `instance:` matches the `#   # instance:`
      # EXAMPLE in the file's "how to read the # lines" header long before
      # the real one inside commits:, and grafts the whole header instead.
      range = (0...@lines.size)
      key_path.each_with_index do |seg, depth|
        indent = depth * ConfigWriter::INDENT
        hit = range.find { |i| tolerant_declares?(@lines[i], seg, indent) }
        return nil unless hit

        range = depth == key_path.size - 1 ? (hit..hit) : (hit + 1..tolerant_extent(hit))
      end
      decl = range.first

      start = decl
      while start.positive?
        above = @lines[start - 1]
        break unless ConfigWriter.comment?(above) && !ConfigWriter.blank?(above)
        break if structure?(above)

        start -= 1
      end
      # A little sibling object over just this slice, so its .lines is the
      # leaf's block -- graft_leaf normalises and activates it.
      block = self.class.allocate
      block.instance_variable_set(:@lines, @lines[start..decl])
      block
    end


    # What save! would change. Built here rather than shelled out to
    # diff(1): the wizard shows this before asking for confirmation, and
    # that must work on a machine with no diff in PATH -- and without
    # writing a temp copy of a config that has an API token in it.
    def diff
      ConfigWriter.diff_lines(@original.lines, @lines).join
    end

    # Sets a scalar. Activates every commented ancestor on the way down --
    # setting widgets.toots.limit on a fresh config has to uncomment
    # `widgets:` and the whole `toots:` sub-block first, while leaving the
    # pixelfed/commits/bluesky/rss siblings commented out. That
    # selectiveness is the whole reason activation walks the path instead
    # of uncommenting a section wholesale.
    def set(key_path, value)
      line_no = resolve!(key_path)
      # An unchanged value leaves the line untouched. Rewriting it
      # normalized quoting and comment spacing, so an Enter-through
      # re-run over a hand-edited config presented a diff and churned
      # the file's VCS history while claiming nothing changed.
      begin
        existing = YAML.safe_load("v:#{@lines[line_no].sub(/\A\s*[A-Za-z_][A-Za-z0-9_-]*:/, '').sub(/\s#.*$/, '')}")
        existing = existing && existing['v']
      rescue StandardError
        existing = nil
      end
      if existing == value && !ConfigWriter.comment?(@lines[line_no])
        @intended[key_path] = value
        return self
      end

      replace_value(line_no, ConfigWriter.scalar(value))
      @intended[key_path] = value
      self
    end

    # Sets a value that spans lines, as a block scalar. Literal (|-) when
    # the text has newlines the author meant to keep, folded (>-)
    # otherwise -- which is what the template uses for about.html and
    # footer.note_html, and what keeps a long paragraph readable in the
    # file instead of running off the screen.
    def set_text(key_path, value)
      line_no = resolve!(key_path)
      indent = ConfigWriter.indent_of(@lines[line_no])
      key = key_path.last
      body_indent = indent + ConfigWriter::INDENT

      # The folded scalar ('>-') re-wraps prose nicely but collapses every
      # run of whitespace to one space -- and verify! then compares the
      # reloaded value against the original, fails, and rolls back the
      # WHOLE run's answers. Two spaces after a period was enough. Such
      # text goes out as a quoted scalar instead, which YAML reads back
      # byte for byte; multiline text whose first line is indented gets
      # the literal style with an explicit indentation indicator, for the
      # same reason.
      if value.include?("\n")
        first_indented = value.split("\n", 2).first.to_s.start_with?(' ', "\t")
        style = first_indented ? "|#{ConfigWriter::INDENT}-" : '|-'
        body = wrap(value, body_indent)
        @lines[line_no..value_extent(line_no)] = ["#{' ' * indent}#{key}: #{style}\n", *body]
      elsif value.match?(/\s\s|\t/)
        @lines[line_no..value_extent(line_no)] = ["#{' ' * indent}#{key}: #{value.to_json}\n"]
      else
        body = wrap(value, body_indent)
        @lines[line_no..value_extent(line_no)] = ["#{' ' * indent}#{key}: >-\n", *body]
      end
      @intended[key_path] = value
      self
    end

    # Replaces a sequence of mappings (social:, footer.links:). The
    # comment block that documents these sits ABOVE the key, so it is
    # never inside the extent being replaced and survives untouched.
    def set_list(key_path, items)
      line_no = resolve!(key_path)
      indent = ConfigWriter.indent_of(@lines[line_no])
      key = key_path.last
      item_indent = indent + ConfigWriter::INDENT

      body = items.flat_map do |item|
        # A plain sequence of scalars -- site.extra_css is one -- as well as
        # the sequence of mappings this was written for (social, footer
        # links, nav). Told apart by the item, not by a second method: the
        # caller knows what it is holding and should not have to say so.
        next ["#{' ' * item_indent}- #{ConfigWriter.scalar(item)}\n"] unless item.is_a?(Hash)

        pairs = item.reject { |_, v| v.nil? }
        pairs.each_with_index.map do |(k, v), i|
          marker = i.zero? ? '- ' : '  '
          "#{' ' * item_indent}#{marker}#{k}: #{ConfigWriter.scalar(v)}\n"
        end
      end
      extent = value_extent(line_no)
      # An empty list is written inline. `key:` followed by an indented
      # `[]` parses the same, but it reads as a key someone forgot to
      # finish -- and for `nav:` the difference between 'no items' and
      # 'nothing written yet' is the difference between no menu bar and
      # the derived one.
      @lines[line_no..extent] = if items.empty?
                                  ["#{' ' * indent}#{key}: []\n"]
                                else
                                  ["#{' ' * indent}#{key}:\n", *body]
                                end
      @intended[key_path] = items.map { |i| i.is_a?(Hash) ? i.reject { |_, v| v.nil? } : i }
      self
    end

    # Comments a section back out, with its whole body. This is what makes
    # "mastodon OR bluesky, never both" enforceable: picking one network
    # deactivates the other rather than leaving a config the build refuses
    # to load (SiteConfig.comment_network aborts on both). A nested path
    # works too -- that is how ./style.sh switches a single sidebar widget
    # off -- and commenting rather than deleting is deliberate: the
    # heading, the account id and the template's prose all stay, so
    # switching the widget back on is one answer instead of a re-typing.
    def deactivate(key_path)
      line_no = active_index[key_path]
      return self unless line_no # already off, or never there -- nothing to do

      extent = value_extent(line_no)
      (line_no..extent).each do |i|
        next if ConfigWriter.blank?(@lines[i])

        # A whole top-level block goes off the way the template writes an
        # optional one, with the '#' at column 0; a key INSIDE an active
        # block keeps its indentation and takes the '#' after it, which is
        # how the same file writes its own inactive keys.
        @lines[i] = if key_path.size == 1
                      "# #{@lines[i]}"
                    else
                      "#{@lines[i][/\A */]}# #{@lines[i].lstrip}"
                    end
      end
      @intended.delete_if { |path, _| path[0, key_path.size] == key_path }
      self
    end

    # Writes, then proves it wrote what was asked. Verification is not
    # belt-and-braces here: every edit above is a text substitution
    # located by pattern, and the one failure mode that matters -- the
    # right-looking line in the wrong place -- is invisible in the diff
    # but obvious the moment the file is reparsed. A file that fails the
    # check is restored from the backup before raising, so a bad edit
    # costs nothing.
    def save!(backup: true)
      return false unless changed?

      backup_path = "#{@path}.bak"
      had_file = File.exist?(@path)
      begin
        FileUtils.cp(@path, backup_path) if backup && had_file
        AtomicWrite.write(@path, current)
      rescue SystemCallError => e
        # The Errno's own message already names the file it could not open,
        # which is the one fact the reader needs and the one the wizard
        # cannot work out for itself -- the backup and the config fail
        # differently and only one of them is the file being edited.
        raise NotWritable, e.message
      end

      begin
        verify!
      rescue StandardError => e
        if had_file && File.exist?(backup_path)
          FileUtils.cp(backup_path, @path)
          raise VerificationFailed, "#{e.message} -- #{@path} was restored from #{backup_path}"
        end
        File.delete(@path) if File.exist?(@path) && !had_file
        raise VerificationFailed, e.message
      end

      true
    end

    private

    # Option C, the seeding step: a config that isn't there yet starts as
    # a byte-for-byte copy of the template, so the user's file carries the
    # same documentation the repo ships and every key is present to be
    # substituted into. Nothing is written to disk here -- the copy lives
    # in memory until save!, so a wizard that gets cancelled leaves no
    # file behind.
    def read_or_seed
      if File.exist?(@path)
        begin
          return File.read(@path)
        rescue SystemCallError => e
          raise Unreadable.new(@path, e.message)
        end
      end
      # The path when there is no template to name: a writer opened over
      # the example itself (style.rb reads the shipped defaults out of it)
      # has none, and the file the sentence has to name is that one.
      raise TemplateMissing, (@template || @path).to_s unless @template && File.exist?(@template)

      File.read(@template)
    end

    # path -> line number, built from ACTIVE lines only. Commented lines
    # are deliberately excluded: see the anchoring note in the module
    # header for what indexing them globally would do.
    def active_index
      index = {}
      stack = []
      @lines.each_with_index do |line, i|
        next if ConfigWriter.blank?(line) || ConfigWriter.comment?(line)

        m = line.match(/\A(\s*)([A-Za-z_][A-Za-z0-9_-]*):(\s|\z)/)
        next unless m

        indent = m[1].length
        stack.pop while stack.any? && stack.last[0] >= indent
        stack.push([indent, m[2]])
        path = stack.map(&:last)
        index[path] ||= i
      end
      index
    end

    # Walks the path from the root, activating whatever is still
    # commented -- and grafting from the template whatever isn't there in
    # any form -- then returns the line number of the final key.
    def resolve!(key_path)
      key_path.each_index do |depth|
        prefix = key_path[0..depth]
        next if active_index[prefix]

        begin
          activate(prefix)
        rescue MissingKey
          # A whole section the file lacks is grafted from the template.
          # A single LEAF the file lacks -- widgets.commits.instance on a
          # config written before 1.4 added it, the exact case the forge
          # widget was built for -- is not a missing section: its parent
          # is active and present, only this one key never existed in the
          # file. Graft that one line (with its documentation) from the
          # template into the parent's body, then activate it.
          if graft(prefix)
            # The template may carry the section active (mastodon:) or
            # commented (bluesky:, widgets:); only the latter needs turning on.
            next if active_index[prefix]

            activate(prefix)
          elsif depth.positive? && active_index[key_path[0...depth]] && graft_leaf(prefix)
            next
          else
            raise
          end
        end
      end
      active_index[key_path] || raise(MissingKey, "#{key_path.join('.')} is not in #{@path}")
    end

    # Copies a section the file doesn't have out of the template,
    # documentation comments and all, and puts it where it belongs: at the
    # end of its parent's body, or at the end of the file for a top-level
    # section. Indentation needs no adjusting -- depth follows the path in
    # both files.
    #
    # This is the one case where the writer adds structure rather than
    # only filling it in, and it is deliberately narrow: the block is
    # copied verbatim from the shipped template, never composed here.
    def graft(key_path)
      return false unless @template && File.exist?(@template)

      block = self.class.new(@template).block_for(key_path)
      return false unless block

      parent = key_path[0..-2]
      if parent.empty?
        @lines << "\n" unless @lines.empty? || ConfigWriter.blank?(@lines.last)
        @lines.concat(block.lines)
      else
        parent_line = locate(parent)
        return false unless parent_line

        # Only when the destination's parent is ACTIVE: inside a section
        # that is itself still commented, the template's own form is
        # already the right one.
        body = block.lines
        body = body.map { |l| ConfigWriter.normalize_comment(l) } if active_index[parent]
        @lines.insert(value_extent(parent_line) + 1, *body)
      end
      true
    end

    # Copies a SINGLE leaf key out of the template into an active parent
    # section the file already has -- the counterpart of graft, which
    # copies a whole missing section. widgets.commits.instance is why this
    # exists: 1.4 added the key, so every config written before it has an
    # active `commits:` block with no `instance` line in any form, and the
    # forge question -- the release's headline feature, aimed at exactly
    # those sites -- died on it. The template's line (with the prose above
    # it) is grafted in, activated, and left for the caller to give a value.
    def graft_leaf(key_path)
      return false unless @template && File.exist?(@template)

      block = self.class.new(@template).leaf_block(key_path)
      return false unless block

      parent = key_path[0..-2]
      parent_line = locate(parent)
      return false unless parent_line

      body = block.instance_variable_get(:@lines).map { |l| ConfigWriter.normalize_comment(l) }
      # The key line itself active, the prose above it left as comments.
      body[-1] = ConfigWriter.uncomment(body[-1]) while ConfigWriter.comment?(body[-1])
      @lines.insert(value_extent(parent_line) + 1, *body)
      true
    end

    # Is this line YAML structure (a key or a sequence entry) rather than
    # prose? Measured on the activated form, so a commented key counts.
    #
    # A sentence can open with a word and a colon, and "key: value" alone
    # cannot tell the two apart: `# Optional: posts per listing page` sits
    # directly above `# page_size: 10` in the shipped template, read as a
    # key, and stopped the walk in the middle of its own paragraph -- so a
    # config that asked for page_size got the second and third lines of
    # the explanation and not the first, opening mid-sentence. What
    # separates them is the VALUE: a setting carries one scalar (quoted, a
    # number, a flow collection, a block scalar) or nothing at all, while
    # prose carries a run of bare words.
    def structure?(line)
      effective = (ConfigWriter.comment?(line) ? ConfigWriter.uncomment(line) : line).chomp
      return true if effective.match?(/\A\s*-\s/)

      declaration = effective.match(/\A\s*[A-Za-z_][A-Za-z0-9_-]*:(?:\s+(?<value>.*))?\z/)
      return false unless declaration

      value = declaration[:value].to_s.strip
      value.empty? || value.start_with?('"', "'", '[', '{', '|', '>', '#', '&', '*') ||
        !value.match?(/\S\s+\S/)
    end

    # Turns ONE commented line into active YAML. Anchored on the key name
    # AND the indentation its parent implies, and searched only within the
    # parent's own extent -- the two constraints that keep `# Optional:
    # posts per listing page` from ever being mistaken for a key.
    #
    # Exactly one line, never the block it opens, for two reasons. It is
    # what makes activation selective: turning on the toots widget must
    # leave pixelfed, commits, bluesky and rss commented, and they are all
    # siblings inside the same `widgets:` body. And it is what keeps the
    # template's placeholders out of a real config -- uncommenting a block
    # wholesale would activate `account_id: "000000000000000000"` and
    # `feed_url: "https://pixelfed.social/users/yourname.atom"` as if they
    # were settings, which is worse than leaving the widget off. Callers
    # reach a leaf through resolve!, so every line that ends up active is
    # one somebody actually gave a value to.
    def activate(key_path)
      key = key_path.last
      parent = key_path[0..-2]
      indent = parent.size * ConfigWriter::INDENT

      range = search_range(parent)
      line_no = range.find do |i|
        ConfigWriter.comment?(@lines[i]) && ConfigWriter.declares?(@lines[i], key, indent)
      end
      if line_no
        @lines[line_no] = ConfigWriter.uncomment(@lines[line_no])
        return
      end

      # A key the template deliberately keeps switched OFF -- written with
      # two '#' so that uncommenting its section wholesale leaves it alone
      # -- is still a key somebody can ask for by name. widgets.commits.
      # instance is the case that found this: the wizard asked the question,
      # the person answered it, and the write died on a key the template
      # was hiding on their behalf. Asking for it by name IS the switch.
      double = range.find do |i|
        ConfigWriter.comment?(@lines[i]) &&
          ConfigWriter.comment?(ConfigWriter.uncomment(@lines[i])) &&
          ConfigWriter.declares?(ConfigWriter.uncomment(@lines[i]), key, indent)
      end
      raise MissingKey, "#{key_path.join('.')} is not in #{@path}, active or commented" unless double

      @lines[double] = ConfigWriter.uncomment(ConfigWriter.uncomment(@lines[double]))
    end

    # Where a key may legitimately be found: inside its parent's body, or
    # anywhere in the file for a top-level key. Bounding the search is
    # what stops a lookup for `heading` from finding some other section's
    # `heading` further down the file.
    def search_range(parent)
      return (0...@lines.size) if parent.empty?

      parent_line = active_index[parent]
      return (0...@lines.size) unless parent_line

      (parent_line + 1)..value_extent(parent_line)
    end

    # The last line belonging to an ACTIVE key: everything below it that
    # is indented deeper, minus the blank lines that trail it (those
    # separate sections and belong to nobody).
    def value_extent(line_no)
      indent = ConfigWriter.indent_of(@lines[line_no])
      last = line_no
      # Have we passed a comment at or above the key's own indent since the
      # last real line? If so, we have left the key's body -- what follows
      # is a sibling, or a commented-out SECTION after the key (its
      # `# bluesky:` head sat at the key's indent), or the prose between two
      # sections -- and their own deeper-indented lines (`#   handle:`, a
      # hanging-indented paragraph) must not be mistaken for the key's
      # children and swallowed. A commented child of the key itself
      # (`# page_size: 10` right under `base_url`, with no shallower comment
      # before it) is reached with this still false, so it stays findable
      # inside the block. Getting this wrong deleted ~100 documented lines
      # from site.yml on the first setup write.
      saw_shallow_comment = false
      ((line_no + 1)...@lines.size).each do |i|
        line_indent = ConfigWriter.indent_of(@lines[i])
        if line_indent.nil? # blank -- may be interior, decided by what follows
          next
        end
        # A block sequence may sit at the SAME indentation as the key that
        # owns it -- valid YAML, and exactly what YAML.dump emits. Read as
        # "not deeper, therefore not mine", the key's extent was one line:
        # set_list then wrote the new entries and left the old ones below
        # them, which is invalid YAML, so verify! rolled the file back and
        # ./style.sh abandoned every other answer in the session and
        # blamed the user's file.
        # The uncommented form, so a commented-out sequence entry sitting at
        # the key's own indent ("# - title: ...", which is how the template
        # shows optional entries) stays INSIDE the key's body instead of
        # ending it.
        if line_indent == indent && ConfigWriter.uncomment(@lines[i]).lstrip.match?(/\A-(\s|\z)/)
          # ...but only while we are still inside the key's own body. A
          # COMMENTED entry reached after a shallower comment belongs to
          # whatever that comment opened, and claiming it here also
          # disarmed the guard, so everything below was annexed too:
          # writing colors.dark.pill_bg -- the last active key in the
          # colors section -- swallowed the 34 documented lines of the
          # commented-out `fonts:` block, because `#     - family:` under
          # `#   faces:` uncomments to indent 4, the same as a colour key.
          # Choosing a palette in ./style.sh deleted them from the user's
          # config, silently.
          next if ConfigWriter.comment?(@lines[i]) && saw_shallow_comment

          last = i
          saw_shallow_comment = false
          next
        end
        # A comment is decided by what FOLLOWS it, the way a blank line is:
        #   * at or above the key's indent -- passed over, never counted as
        #     the end of the body, and it arms saw_shallow_comment so what
        #     lies below cannot be annexed. With ONE exception: a line that
        #     is still a comment after one '#' is stripped is not the file
        #     talking, it is a line of a block that is already switched off.
        #     Removing a widget comments the template's own flush-left prose
        #     a second time ("# #     # instance is optional ..."), which
        #     lands at column 0 INSIDE the block -- armed there, it hid every
        #     answer below it, and a widget switched off forgot its account
        #     id and its limit instead of offering them back.
        #   * deeper than the key -- a child. A genuine trailing child of
        #     the key (`# page_size` under `site:`) commits, so it stays in
        #     the block and remains findable; the body of a following
        #     commented section, and the hanging indent of the paragraph
        #     documenting it, are reached only after a shallower comment and
        #     do not.
        if ConfigWriter.comment?(@lines[i])
          if line_indent <= indent
            saw_shallow_comment = true unless ConfigWriter.comment?(ConfigWriter.uncomment(@lines[i]))
          elsif !saw_shallow_comment
            last = i
          end
          next
        end

        break if line_indent <= indent

        last = i
        saw_shallow_comment = false
      end
      last
    end

    # Substitutes the value on a `key: value` line, keeping the key, the
    # indentation and any trailing comment -- the template has real ones
    # ("account_id: ... # numeric Mastodon account id, not the @handle")
    # and they are exactly the kind of hint a beginner needs to keep.
    def replace_value(line_no, scalar)
      line = @lines[line_no]
      m = line.match(/\A(\s*[A-Za-z_][A-Za-z0-9_-]*:)([^\n]*)\n?\z/)
      raise MissingKey, "line #{line_no + 1} of #{@path} is not a key line" unless m

      trailing = trailing_comment(m[2])
      # A key that currently opens a block (`html: >-`, or a nested
      # mapping) owns the lines below it; they have to go, or the new
      # scalar would sit above an orphaned body.
      extent = value_extent(line_no)
      @lines[line_no..extent] = ["#{m[1]} #{scalar}#{trailing}\n"]
    end

    # A '#' inside a quoted value is not a comment. Rather than parse the
    # scalar, only a '#' that follows whitespace and sits outside quotes
    # counts -- which is the YAML rule anyway.
    def trailing_comment(rest)
      in_single = false
      in_double = false
      rest.each_char.with_index do |c, i|
        in_single = !in_single if c == "'" && !in_double
        in_double = !in_double if c == '"' && !in_single
        next unless c == '#' && !in_single && !in_double
        next unless i.zero? || rest[i - 1] =~ /\s/

        return "  #{rest[i..].rstrip}"
      end
      ''
    end

    # Folded scalars join their lines with a space, so wrapping is free
    # for '>-' -- and must NOT happen for '|-', where every newline is
    # meant. Long unbreakable tokens (a URL) are left over-long rather
    # than broken, since a break would change the value.
    def wrap(value, indent)
      pad = ' ' * indent
      return value.split("\n", -1).map { |l| l.empty? ? "\n" : "#{pad}#{l}\n" } if value.include?("\n")

      width = 72 - indent
      out = []
      line = +''
      value.split(/\s+/).each do |word|
        if line.empty?
          line = word.dup
        elsif line.length + 1 + word.length <= width
          line << ' ' << word
        else
          out << "#{pad}#{line}\n"
          line = word.dup
        end
      end
      out << "#{pad}#{line}\n" unless line.empty?
      out
    end

    # Reparses the written file and checks every value we set is actually
    # there. Lists compare on the keys we wrote (string keys, since that
    # is what YAML gives back).
    def verify!
      data = YamlCompat.load_file(@path) || {}
      @intended.each do |key_path, expected|
        actual = key_path.reduce(data) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
        # Sequences of mappings get their keys stringified before the
        # comparison; a sequence of scalars (site.extra_css) has nothing to
        # stringify and must be left as it is.
        stringify = ->(list) { list.map { |i| i.is_a?(Hash) ? i.transform_keys(&:to_s) : i } }
        actual = stringify.call(actual) if actual.is_a?(Array)
        want = expected.is_a?(Array) ? stringify.call(expected) : expected
        next if actual == want

        raise "#{key_path.join('.')} reads back as #{actual.inspect}, expected #{want.inspect}"
      end
    rescue Psych::SyntaxError => e
      raise "the result is not valid YAML (#{e.message})"
    end
  end

  # Edits env.sh. Simpler than the YAML side in every way that matters:
  # the lines are `export NAME=value`, there is no nesting, and a setting
  # that is commented out is commented with a single '#'. The reason it
  # exists at all rather than being a few gsubs at the call site is the
  # same as above -- env.sh.example is 94 lines of comments explaining
  # which backend needs which values, and that is the only place a user
  # ever reads it.
  class EnvFile
    attr_reader :path

    def initialize(path, template: nil)
      @path = path
      @template = template
      @original = read_or_seed
      @lines = @original.lines
      @intended = {}
    end

    def changed?
      current != @original
    end

    def current
      @lines.join
    end

    # What this run has set NAME to, before anything is saved -- so a
    # caller can act on an answer it just collected (checking that a
    # deploy directory exists) without reaching into the file or the
    # environment, neither of which knows about it yet.
    def value(name)
      @intended[name]
    end

    # All of them, for the caller that has to bring its own process's ENV
    # up to date: env.sh is read by the SHELL that started us, so anything
    # written here is invisible to this process until someone copies it
    # across. Without that, a check run after the write still sees the
    # values the wizard just replaced.
    def values
      @intended.dup
    end

    def diff
      ConfigWriter.diff_lines(@original.lines, @lines).join
    end

    # Values are single-quoted, with the one escape POSIX sh allows inside
    # single quotes ('\'' -- close, escaped quote, reopen). Tokens are the
    # values that land here, and an API token with a $ or a backtick in it
    # would otherwise be interpreted by the shell that sources this file.
    #
    # The replacement is a BLOCK, not a string: in a gsub replacement
    # string \' means "everything after the match", so the string form of
    # this exact escape silently pastes the rest of the token back into
    # itself. A block is taken literally.
    def set(name, value)
      quoted = "'#{value.to_s.gsub("'") { "'\\''" }}'"
      line_no = find_line(name)
      if line_no
        @lines[line_no] = "export #{name}=#{quoted}\n"
      else
        @lines << "\n" unless @lines.empty? || @lines.last.end_with?("\n")
        @lines << "export #{name}=#{quoted}\n"
      end
      @intended[name] = value.to_s
      self
    end

    # A setting the user declined: commented out rather than emptied, so
    # the template's explanation of it stays visible for later.
    # EVERY active assignment goes, not one of them. `set` may pick the
    # last line because the shell reads the last value -- but switching a
    # name OFF by commenting one line out of two just promotes the other:
    # "no deploy target" left the site deploying, with the diff on screen
    # showing a line duly commented out.
    def unset(name)
      hit = false
      @lines.each_index do |i|
        next unless @lines[i].match?(/\A\s*export\s+#{Regexp.escape(name)}=/)

        @lines[i] = "# #{@lines[i]}"
        hit = true
      end
      @intended.delete(name)
      hit
      self
    end

    # env.sh holds live credentials, so it is created 0600 and an existing
    # file has its mode left alone (the user may have tightened it
    # further). The backup inherits the same mode -- a world-readable
    # env.sh.bak next to a 0600 env.sh would defeat the point.
    def save!(backup: true)
      return false unless changed?

      backup_path = "#{@path}.bak"
      begin
        if backup && File.exist?(@path)
          FileUtils.cp(@path, backup_path)
          File.chmod(0o600, backup_path)
        end
      # Read BEFORE the write: AtomicWrite replaces the file with a new
      # inode, so afterwards the mode is the new file's and the old one is
      # gone. Skipping the chmod when the file existed -- which is what this
      # did -- therefore dropped an env.sh full of live tokens from 0600 to
      # whatever the umask says (0644 by default) on every single save,
      # while the wizard printed "readable only by you (mode 600)" a few
      # lines earlier.
        previous = File.stat(@path).mode & 0o7777 if File.exist?(@path)
        AtomicWrite.write(@path, current)
        # A mode that already lets nobody but the owner in is kept exactly --
        # somebody who chose 0400 meant it. Anything wider is not a choice
        # this file can honour.
        File.chmod(previous && (previous & 0o077).zero? ? previous : 0o600, @path)
      rescue SystemCallError => e
        raise NotWritable, e.message
      end
      true
    end

    private

    def read_or_seed
      if File.exist?(@path)
        begin
          return File.read(@path)
        rescue SystemCallError => e
          raise Unreadable.new(@path, e.message)
        end
      end
      # The path when there is no template to name: a writer opened over
      # the example itself (style.rb reads the shipped defaults out of it)
      # has none, and the file the sentence has to name is that one.
      raise TemplateMissing, (@template || @path).to_s unless @template && File.exist?(@template)

      File.read(@template)
    end

    # Prefers an active line, falls back to a commented one (which is how
    # every optional backend ships -- "# export RSYNC_TARGET=..."), so
    # setting one activates the documented line in place instead of
    # appending a duplicate at the bottom.
    # The LAST active assignment, not the first. env.sh is a shell script:
    # every line runs, so a name written twice ends up with the value from
    # the bottom -- while the wizard rewrote the top one, reported success,
    # and left the old value in force. A file with one assignment (all of
    # them, in practice) is unaffected.
    def find_line(name)
      active = @lines.rindex { |l| l.match?(/\A\s*export\s+#{Regexp.escape(name)}=/) }
      return active if active

      @lines.index { |l| l.match?(/\A\s*#\s*export\s+#{Regexp.escape(name)}=/) }
    end
  end
end
