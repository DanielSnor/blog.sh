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

  # Raised when the file we just wrote doesn't parse back to the values we
  # put in it. The file is restored before this is raised -- see save!.
  class VerificationFailed < StandardError; end

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
        pairs = item.reject { |_, v| v.nil? }
        pairs.each_with_index.map do |(k, v), i|
          marker = i.zero? ? '- ' : '  '
          "#{' ' * item_indent}#{marker}#{k}: #{ConfigWriter.scalar(v)}\n"
        end
      end
      body = ["#{' ' * item_indent}[]\n"] if items.empty?

      extent = value_extent(line_no)
      @lines[line_no..extent] = ["#{' ' * indent}#{key}:\n", *body]
      @intended[key_path] = items.map { |i| i.reject { |_, v| v.nil? } }
      self
    end

    # Comments a top-level section back out, with its whole body. This is
    # what makes "mastodon OR bluesky, never both" enforceable: picking
    # one network deactivates the other rather than leaving a config the
    # build refuses to load (SiteConfig.comment_network aborts on both).
    def deactivate(key_path)
      raise ArgumentError, 'only top-level sections can be deactivated' unless key_path.size == 1

      line_no = active_index[key_path]
      return self unless line_no # already off -- nothing to do

      extent = value_extent(line_no)
      (line_no..extent).each do |i|
        next if ConfigWriter.blank?(@lines[i])

        @lines[i] = "# #{@lines[i]}"
      end
      @intended.delete(key_path)
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
      FileUtils.cp(@path, backup_path) if backup && had_file

      AtomicWrite.write(@path, current)

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
      return File.read(@path) if File.exist?(@path)
      raise MissingKey, "no #{@path} and no template to seed it from" unless @template && File.exist?(@template)

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
          raise unless graft(prefix)
          # The template may carry the section active (mastodon:) or
          # commented (bluesky:, widgets:); only the latter needs turning on.
          next if active_index[prefix]

          activate(prefix)
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

    # Is this line YAML structure (a key or a sequence entry) rather than
    # prose? Measured on the activated form, so a commented key counts.
    def structure?(line)
      effective = ConfigWriter.comment?(line) ? ConfigWriter.uncomment(line) : line
      effective.match?(/\A\s*(-\s|[A-Za-z_][A-Za-z0-9_-]*:(\s|\z))/)
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
      raise MissingKey, "#{key_path.join('.')} is not in #{@path}, active or commented" unless line_no

      @lines[line_no] = ConfigWriter.uncomment(@lines[line_no])
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
        if line_indent == indent && @lines[i].lstrip.match?(/\A-(\s|\z)/)
          last = i
          next
        end
        break if line_indent <= indent

        last = i
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
        actual = actual.map { |h| h.transform_keys(&:to_s) } if actual.is_a?(Array)
        want = expected.is_a?(Array) ? expected.map { |h| h.transform_keys(&:to_s) } : expected
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
    def unset(name)
      line_no = find_line(name)
      return self unless line_no

      @lines[line_no] = "# #{@lines[line_no]}" unless ConfigWriter.comment?(@lines[line_no])
      @intended.delete(name)
      self
    end

    # env.sh holds live credentials, so it is created 0600 and an existing
    # file has its mode left alone (the user may have tightened it
    # further). The backup inherits the same mode -- a world-readable
    # env.sh.bak next to a 0600 env.sh would defeat the point.
    def save!(backup: true)
      return false unless changed?

      backup_path = "#{@path}.bak"
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
      true
    end

    private

    def read_or_seed
      return File.read(@path) if File.exist?(@path)
      raise MissingKey, "no #{@path} and no template to seed it from" unless @template && File.exist?(@template)

      File.read(@template)
    end

    # Prefers an active line, falls back to a commented one (which is how
    # every optional backend ships -- "# export RSYNC_TARGET=..."), so
    # setting one activates the documented line in place instead of
    # appending a duplicate at the bottom.
    def find_line(name)
      active = @lines.index { |l| l.match?(/\A\s*export\s+#{Regexp.escape(name)}=/) }
      return active if active

      @lines.index { |l| l.match?(/\A\s*#\s*export\s+#{Regexp.escape(name)}=/) }
    end
  end
end
