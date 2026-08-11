# frozen_string_literal: true

module Import
  # Meta's data exports escape each BYTE of a UTF-8 string as its own
  # code point, so what JSON hands back is Latin-1 that has to be read
  # as UTF-8 again: Czech "stastne" with its accents arrives one byte
  # at a time as accented Latin noise. The guard range is every byte
  # that can start a UTF-8 sequence (C2..F4) -- Czech r-hacek is C5 99
  # and an emoji is F0 9F ... -- and the repair is only applied where
  # the pattern appears, since the same conversion would destroy text
  # that arrived intact.
  #
  # Built with Regexp.new from escape strings on purpose: the class
  # ranges are unprintable/confusable code points, and a literal form
  # has already been mangled once by tooling that normalized it.
  #
  # The Instagram importer carries its own private copy of this logic,
  # verified against real exports before this module existed; the two
  # are kept in step by hand until a consolidation with tests to lean
  # on. New Meta-family importers use this one.
  module MetaText
    MOJIBAKE = Regexp.new('[Â-ô][-¿]').freeze

    module_function

    def repair(text)
      text = text.to_s
      return text unless text.match?(MOJIBAKE)

      candidate = text.encode('ISO-8859-1').force_encoding('UTF-8')
      candidate.valid_encoding? ? candidate : text
    rescue Encoding::UndefinedConversionError
      text
    end
  end
end
