# frozen_string_literal: true

module Import
  # Reads an export that is very nearly XML and hands back one that is.
  #
  # Blog exports are printed by templating engines, not written by XML
  # writers. WordPress puts a raw query string in an element --
  #   <wp:attachment_url>https://img.example/p-1?ixlib=rb-1.2.1&w=1268</wp:attachment_url>
  # -- and Squarespace prints a bare & in a <title>. Both files are then
  # rejected outright by every conforming parser, so one unescaped
  # character used to cost the author the entire archive: 4 of the 12
  # fixtures that Ghost's own migration tools ship are refused this way,
  # while Ghost's parser reads them.
  #
  # Only characters that had to be escaped and were not:
  #   &  that begins no reference  ->  &amp;
  #   control bytes XML forbids    ->  dropped
  # Nothing structural. A missing end tag or a download that stopped
  # halfway is left to fail, because guessing where a tag was meant to
  # close invents an archive instead of rescuing one.
  #
  # WHY THIS IS NOT ONE gsub OVER THE FILE
  # A WordPress post body lives inside <![CDATA[ ]]>, where & is already
  # an ordinary character. Substituting across the whole file turns every
  # href="?a=1&b=2" in every post into a visible "&amp;" -- it damages
  # precisely the archives it claims to rescue, and silently, because the
  # file parses afterwards.
  #
  # So the regions that must not be touched are found FIRST, by a plain
  # left-to-right search for their own opening and closing markers, with
  # no model of the document's tags at all. That is deliberately dumber
  # than tracking elements and attributes, and it is why it is safe: the
  # way this can go wrong is by treating ordinary text as untouchable --
  # a bare & then stays bare, the document still fails to parse, and the
  # author gets the same clear refusal as before. It cannot go wrong by
  # editing a post body.
  module XmlRepair
    # What came back, and what it cost -- counted apart because a control
    # byte dropped from a title is different news than an escaped
    # ampersand, and the summary says both.
    Result = Struct.new(:text, :ampersands, :controls) do
      def changed?
        ampersands.positive? || controls.positive?
      end
    end

    # What opens a region that must survive byte for byte, and what closes
    # it. The DOCTYPE is the one whose end has to be counted rather than
    # found, so it has no entry here -- see doctype_end.
    DOCTYPE = '<!DOCTYPE'.b.freeze
    CLOSING = { '<![CDATA['.b.freeze => ']]>'.b.freeze, '<!--'.b.freeze => '-->'.b.freeze,
                '<?'.b.freeze => '?>'.b.freeze }.freeze
    MARKERS = (CLOSING.keys + [DOCTYPE]).freeze

    # The characters XML 1.0 forbids outright. Tab, newline and carriage
    # return are the three control characters it allows, and they are the
    # three that appear in every export, so they are absent here. NUL is
    # absent too, but for the opposite reason -- see repairable?.
    # Written as an escape on purpose: a literal NUL in a source file is
    # invisible in every editor and does not survive being copied.
    NUL = "\u0000"

    FORBIDDEN = /[\x01-\x08\x0B\x0C\x0E-\x1F]/n.freeze

    # An & that opens no reference at all. Named references are matched
    # loosely on purpose: &mdash; is not declared by any DTD a blog export
    # carries, but it IS well-formed, REXML accepts it and leaves the text
    # as written -- so escaping it here would change a document that parses
    # perfectly well.
    BARE_AMPERSAND = /&(?!(?:[A-Za-z_][A-Za-z0-9._-]*|#[0-9]+|#x[0-9A-Fa-f]+);)/n.freeze

    # The declaration's own encoding, read from the declaration alone and
    # not from the first kilobyte -- an export whose <description> merely
    # mentions the string encoding="utf-16" is an ordinary UTF-8 file.
    DECLARED_ENCODING = /\A<\?xml\b[^>]*?\bencoding\s*=\s*["']([^"']+)["']/.freeze

    # The encodings whose bytes are the ones this reads. Everything else
    # keeps today's refusal: see repairable?.
    OWN_ENCODINGS = %w[utf-8 utf8 us-ascii ascii].freeze

    module_function

    # A Result, or nil when this must not touch the file at all. nil means
    # the caller keeps the refusal it was already going to print.
    def call(raw)
      return nil unless repairable?(raw)

      # BYTES, not characters, from here down. String#index and String#[]
      # take CHARACTER offsets, and on a multi-byte string a character
      # offset has to be walked to from the front -- so every slice costs
      # the file up to that point. With one CDATA section per post that is
      # thousands of slices and the whole thing turns quadratic: a 666 kB
      # archive took 2.6 seconds and a 6 MB one 213. Every marker below is
      # ASCII and UTF-8 is self-synchronising, so no ASCII byte can occur
      # inside a multi-byte character and a byte scan finds exactly what a
      # character scan would. repairable? has already established that
      # these bytes really are UTF-8.
      bytes = raw.b
      out = +''.b
      amps = 0
      controls = 0
      pos = 0

      opaque_spans(bytes).each do |start, finish|
        text, a, c = repair(bytes[pos...start])
        out << text << bytes[start...finish]
        amps += a
        controls += c
        pos = finish
      end
      text, a, c = repair(bytes[pos..] || ''.b)
      out << text
      amps += a
      controls += c

      # Only ASCII was inserted, and only ASCII control bytes removed --
      # neither can fall inside a multi-byte character, so what comes out
      # is UTF-8 exactly as surely as what went in.
      result = Result.new(out.force_encoding(Encoding::UTF_8), amps, controls)
      # Hand back the very string that came in when nothing was touched,
      # so the caller cannot end up parsing a copy it never asked for.
      result.text = raw unless result.changed?
      result
    end

    # Three ways this file is not the file this reads. All three keep the
    # existing refusal rather than being guessed at, because every one of
    # them ends the same way if guessed at wrong: an import that finishes,
    # reports success, and fills the archive with mangled text. A loud
    # refusal is the better failure.
    #
    # Bytes that are not valid UTF-8: a regular expression over them
    # raises before anything can be repaired.
    #
    # A NUL byte anywhere. XML forbids it outright, so no readable export
    # contains one -- and its presence is exactly how a file in UTF-16 or
    # UTF-32 arrives here. Read as UTF-8, such a file is ASCII text with a
    # NUL between every character, which String#valid_encoding? happily
    # accepts: the markers below would then never match, every post body
    # would count as ordinary text, and dropping the NULs as stray control
    # characters would quietly transcode the document. It parsed
    # afterwards, which is what made it dangerous.
    #
    # A declaration naming some other encoding. REXML reads such a file
    # correctly BY that declaration, so patching its bytes as UTF-8 and
    # handing them back turns a refusal into an import of mojibake. A
    # template with a stale encoding= line over a database that has since
    # moved to UTF-8 is the common way to meet this.
    def repairable?(raw)
      return false unless raw.is_a?(String) && raw.valid_encoding?
      return false if raw.include?(NUL)

      declared = raw[DECLARED_ENCODING, 1]
      declared.nil? || OWN_ENCODINGS.include?(declared.downcase)
    end

    # Every region that must survive byte for byte, in the order they
    # appear, as [start, end] pairs.
    #
    # Where each marker sits next is REMEMBERED, and looked for again only
    # once the walk has passed it. Asking for all four from the cursor on
    # every round is the obvious way to write this and it is quadratic --
    # not mildly, because a WordPress export puts every post body in its
    # own CDATA section: a 666 kB archive has 6,414 of them. A marker the
    # file does not contain at all (no WXR has a DOCTYPE) was then searched
    # for 6,414 times, each search running to the end of the file, and
    # escaping a single ampersand in that archive took 8.7 seconds. The
    # remembered nil is what makes an absent marker free, and a remembered
    # position is what keeps a distant one from being hunted twice.
    def opaque_spans(raw)
      at = {}
      MARKERS.each { |marker| at[marker] = raw.index(marker) }

      spans = []
      pos = 0
      loop do
        winner = nil
        MARKERS.each do |marker|
          found = at[marker]
          # Behind the cursor means this one has just been consumed; every
          # other marker's position still stands.
          found = at[marker] = raw.index(marker, pos) if found && found < pos
          next if found.nil?

          winner = marker if winner.nil? || found < at[winner]
        end
        break if winner.nil?

        start = at[winner]
        spans << [start, region_end(raw, winner, start)]
        pos = spans.last[1]
      end
      spans
    end

    def region_end(raw, marker, start)
      return doctype_end(raw, start) if marker == DOCTYPE

      closing = CLOSING.fetch(marker)
      # No closing marker means the rest of the file is inside this one.
      # That is a broken document either way, and treating the remainder as
      # untouchable keeps this from writing into it on the way out.
      finish = raw.index(closing, start + marker.length)
      finish ? finish + closing.length : raw.length
    end

    # A DOCTYPE ends at the first > that is not inside its internal
    # subset. The subset is what the brackets hold, and it is the reason
    # the end has to be counted instead of searched for: an entity
    # declaration inside it legitimately contains >.
    def doctype_end(raw, start)
      i = start + DOCTYPE.length
      depth = 0
      while i < raw.length
        case raw[i]
        when '[' then depth += 1
        when ']' then depth -= 1
        when '>' then return i + 1 if depth <= 0
        end
        i += 1
      end
      raw.length
    end

    def repair(chunk)
      return [''.b, 0, 0] if chunk.empty?

      controls = 0
      text = chunk.gsub(FORBIDDEN) do
        controls += 1
        ''
      end
      amps = 0
      text = text.gsub(BARE_AMPERSAND) do
        amps += 1
        '&amp;'
      end
      [text, amps, controls]
    end
  end
end
