# frozen_string_literal: true

require_relative 'import/html_blocks'

# Turning HTML entities back into the characters they stand for, in text
# that carries formatting spans over it.
#
# Lives on its own because two places need exactly this and must not
# disagree: the Twitter importer, where an archive delivers "&amp;" for
# every ampersand the author typed, and `check --repair`, which cleans up
# archives imported before the importer knew that.
#
# The difficulty is the spans. Decoding shortens the text, so every offset
# after an entity moves left -- and a link whose start is not moved with it
# walks off its own words. So the text is walked once, a map of old offset
# to new offset is built as it goes, and the spans are moved afterwards.
module EntityText
  module_function

  ENTITY = /\A&(?:#x?[0-9a-fA-F]+|\w+);/
  # What "this text has entities in it" means to a caller that only wants to
  # know whether to bother. Deliberately the same shape as the pattern above.
  ANY_ENTITY = /&(?:#x?[0-9a-fA-F]+|\w+);/

  def entities?(text)
    text.to_s.match?(ANY_ENTITY) && decode(text.to_s, []).first != text.to_s
  end

  # Returns [decoded_text, formatting] -- formatting is mutated in place and
  # returned for the caller's convenience, matching what the importer did
  # before this moved out of it.
  def decode(text, formatting)
    moved = Array.new(text.length + 1)
    decoded = +''
    index = 0
    while index < text.length
      moved[index] = decoded.length
      match = text[index..].match(ENTITY)
      replacement = match && Import::HtmlBlocks.decode_entities(match[0])
      if match && replacement != match[0]
        decoded << replacement
        # An index that lands INSIDE an entity has no character of its own
        # to point at; it belongs after the letter the entity became.
        (1...match[0].length).each { |offset| moved[index + offset] = decoded.length }
        index += match[0].length
      else
        decoded << text[index]
        index += 1
      end
    end
    moved[text.length] = decoded.length

    Array(formatting).each do |span|
      span['start'] = moved[span['start']] || span['start']
      span['end'] = moved[span['end']] || span['end']
    end
    [decoded, formatting]
  end
end
