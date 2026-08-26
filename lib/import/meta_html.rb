# frozen_string_literal: true

require 'time'
require_relative 'html_blocks'

module Import
  # What Meta's HTML exports share, so the Facebook and Threads readers
  # don't each grow a private copy: the printed timestamp, and the fact
  # that it is printed in words -- "dub 10, 2014 9:02:15 odpol." in a
  # Czech-requested export, "Jul 29, 2026 6:28 am" in an English one.
  # The export's language follows the account's UI language at request
  # time, so one person's archives genuinely arrive mixed (the pair this
  # was built against: Facebook in Czech, Threads in English), and a
  # parser that knows only English fails on exactly the exports this
  # codebase's own locales invite.
  #
  # Only languages verified against a real export are in the tables;
  # German is conspicuously missing until someone can hold an export in
  # it, because a guessed month table would parse confidently and date
  # everything wrong. An unknown token comes back nil, and the caller
  # says which token it was -- the person holding the export can ask
  # Meta for JSON, whose epochs need no dictionary.
  #
  # The Instagram importer predates this module and carries its own
  # English-only timestamp handling, verified against its own export;
  # the two are kept in step by hand, same arrangement as MetaText.
  module MetaHtml
    MONTHS = {
      # English
      'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6,
      'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12,
      # Czech
      'led' => 1, 'úno' => 2, 'bře' => 3, 'dub' => 4, 'kvě' => 5, 'čvn' => 6,
      'čvc' => 7, 'srp' => 8, 'zář' => 9, 'říj' => 10, 'lis' => 11, 'pro' => 12
    }.freeze

    # Afternoon markers per language; anything listed here that isn't in
    # this hash means morning. Czech exports write "dopol."/"odpol."
    # with the dot.
    MERIDIEMS = %w[am pm dopol. odpol.].freeze
    AFTERNOON = %w[pm odpol.].freeze

    # The row label a profile file gives the account's username -- each
    # verified against a real export requested in that language, the
    # Czech one arriving as a string_map_data key mangled like every
    # other localized string, which is why the JSON reader repairs
    # before it compares. A language missing from this list costs
    # nothing -- a label that never matches falls back to the export
    # directory's name, where a wrong month would silently mis-date an
    # archive -- so this list may grow on weaker evidence than the
    # months above. Tried as a list, not a translation, because Meta's
    # localization is patchy: the Czech export this codebase was built
    # against leaves whole labels in English mid-page.
    USERNAME_LABELS = ['Username', 'Uživatelské jméno'].freeze

    # "dub 10, 2014 9:02:15 odpol." (Facebook, with seconds) and
    # "Jul 29, 2026 6:28 am" (Threads, without) are the same shape once
    # the seconds go optional. Anchored by the caller as needed.
    STAMP = /(\p{L}+\.?) (\d{1,2}), (\d{4}) (\d{1,2}):(\d{2})(?::(\d{2}))? (\p{L}+\.?)/u.freeze

    # A whole node that is nothing but a timestamp -- how a date cell is
    # recognized among text nodes without leaning on minified class
    # names.
    TIMESTAMP_NODE = /\A#{STAMP}\z/u.freeze

    # One leading word and then a timestamp is the shape of the export's
    # own "Aktualizováno …" / "Updated …" furniture line, which sits
    # inside the post's text cell and would otherwise import as prose.
    # The month and meridiem tables still have to agree, so a sentence
    # that merely ends in a date keeps its life.
    FURNITURE = /\A\p{L}+ #{STAMP}\z/u.freeze

    module_function

    # nil for anything the tables don't cover, and the unrecognized
    # token is worth reporting: it is the difference between "this post
    # is broken" and "this export is in a language the tables don't
    # know yet".
    def parse_parts(text)
      match = text.to_s.strip.match(TIMESTAMP_NODE)
      return nil unless match

      month = MONTHS[match[1].downcase.delete_suffix('.')]
      meridiem = match[7].downcase
      return nil unless month && MERIDIEMS.include?(meridiem)

      hour = match[4].to_i % 12
      hour += 12 if AFTERNOON.include?(meridiem)
      [match[3].to_i, month, match[2].to_i, hour, match[5].to_i, match[6].to_i]
    end

    # Facebook prints wall-clock time in the account's own timezone,
    # daylight saving observed (verified against the same account's JSON
    # epochs: winter posts an hour apart from summer ones, exactly along
    # the DST boundary). The export doesn't name the zone, so this reads
    # it in the site's -- for the ordinary case of importing your own
    # archive into your own blog the two are the same place, and the
    # timestamps come out epoch-exact.
    def parse_local(text)
      parts = parse_parts(text)
      parts && Time.local(*parts)
    end

    # Threads prints Pacific standard time all year, the same convention
    # (and the same fixed -08:00, deliberately not the DST-observing
    # zone) as the Instagram HTML export -- see that importer for the
    # measurement. Verified here against the Threads JSON epochs: every
    # post agrees to the minute, summer and winter both.
    def parse_pacific(text)
      parts = parse_parts(text)
      parts && Time.new(*parts, '-08:00').getlocal
    end

    def furniture?(text)
      match = text.to_s.strip.match(FURNITURE)
      return false unless match

      MONTHS.key?(match[1].downcase.delete_suffix('.')) && MERIDIEMS.include?(match[7].downcase)
    end

    # Case-insensitive on purpose: the label is a display string, and
    # which letters Meta capitalizes has already varied between
    # products. A JSON reader hands its keys through its mojibake
    # repair before asking, since Meta mangles the keys of a localized
    # export exactly as it mangles the values.
    def username_label?(text)
      node = text.to_s.strip
      USERNAME_LABELS.any? { |label| label.casecmp?(node) }
    end

    # Tag soup to text nodes, entities decoded -- the same treatment the
    # Instagram reader gives its fragments.
    def text_nodes(fragment)
      fragment.gsub(/<[^>]*>/, "\n").split("\n")
              .map { |node| HtmlBlocks.decode_entities(node).strip }
              .reject(&:empty?)
    end

    # One node's worth of markup to plain text: line breaks survive as
    # newlines, tags go, entities decode last (an entity that spells a
    # bracket must not conjure a tag).
    def plain_text(fragment)
      # Meta writes a line break as the SEVEN bytes "<br /> " -- the tag
      # followed by a literal space. Turning the tag into a newline and
      # leaving the space made every paragraph break "\n \n", which the
      # paragraph splitter (/\n{2,}/) does not see as one, so a
      # multi-paragraph post collapsed into a single block and every
      # continuation line kept a stray leading space. 193 of the 1603
      # posts in the export this was measured against; and because the
      # post's id is a digest over its text, those posts also stopped
      # matching their JSON-imported twins on re-import.
      HtmlBlocks.decode_entities(
        fragment.gsub(%r{<br\s*/?>[ \t]?}i, "\n").gsub(/<[^>]*>/, '')
      ).strip
    end
  end
end
