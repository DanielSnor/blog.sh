# frozen_string_literal: true

# lib/exif_location.rb -- takes the place out of a photo, and nothing else.
#
# A phone writes where it stood into every picture it takes, and this engine
# copied media byte for byte, so a snapshot from a back garden published the
# back garden's coordinates along with it. Social networks strip this on
# upload and their users have long since stopped thinking about it; a static
# blog has nobody to do it for them.
#
# ONLY the location goes. The rest of the Exif block -- the camera, the lens,
# the moment the shutter opened -- is the author's own record of their own
# photograph, and an archive that quietly threw it away would be answering a
# question nobody asked. That decision has a second, larger consequence: the
# Orientation tag stays, so a portrait photo (stored landscape, with a tag
# telling the viewer to turn it) still turns. Nothing here touches a pixel,
# which is what makes it possible at all -- rotating an image needs a decoder
# the standard library does not have, and this engine takes no gems.
#
# The same principle as lib/media_dimensions.rb next door: read exactly the
# bytes the question needs, and no general TIFF parser.
#
# Scope: JPEG. That is where the problem lives -- phones produce JPEG (a HEIC
# converted by lib/heic_converter.rb arrives here as one, carrying its GPS
# across the conversion, which is how this was found). PNG and WebP have
# places to keep Exif too, but no camera fills them, and an XMP packet can
# hold a second copy of the coordinates that this does not read. Both are
# written down in docs rather than guessed at.
module ExifLocation
  # IFD0's pointer to the GPS block, and the entry sizes of the TIFF
  # structure it lives in: 12 bytes per entry, a 2-byte count before them
  # and a 4-byte "next IFD" offset after.
  GPS_IFD_POINTER = 0x8825
  ENTRY_SIZE = 12
  COUNT_SIZE = 2
  NEXT_IFD_SIZE = 4

  # GPSVersionID -- the version of the GPS block's own format, and the one
  # tag in it that says nothing about where anybody was. Cameras write a GPS
  # block holding this and nothing else, which is not a location and must not
  # be reported as one: three photos in a real 2962-photo archive had exactly
  # that shape, and counting them would have opened this with a headline
  # number that was entirely false alarms.
  GPS_VERSION_ID = 0x0000

  # Bytes per TIFF type code, indexed by the code itself. Needed to find the
  # data an entry points at: a value of four bytes or fewer sits inside the
  # entry, anything longer is stored elsewhere in the block and referenced.
  # Coordinates are RATIONALs -- three of them, eight bytes each -- so they
  # are always out of line, always the second kind.
  TYPE_SIZES = { 1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 6 => 1, 7 => 1,
                 8 => 2, 9 => 4, 10 => 8, 11 => 4, 12 => 8 }.freeze

  EXIF_PREFIX = "Exif\0\0".b

  module_function

  # True when the file has coordinates in it. Cheap on purpose: doctor asks
  # this of every photo in an archive, and the answer is in the first
  # kilobytes of a file that may be several megabytes.
  def present?(path)
    located?(File.binread(path, 256 * 1024).to_s)
  rescue StandardError
    false
  end

  # Rewrites the file without its coordinates, and answers whether it had to.
  # Writes a sibling and renames, like everything else that touches media
  # here: a rewrite interrupted halfway must not leave a truncated photo
  # under the real name.
  def strip_file(path)
    data = begin
      File.binread(path)
    rescue StandardError
      return false
    end

    stripped = strip(data)
    return false unless stripped

    tmp = File.join(File.dirname(path), ".#{File.basename(path)}.scrub")
    begin
      File.binwrite(tmp, stripped)
      File.rename(tmp, path)
      true
    rescue StandardError
      begin
        File.delete(tmp)
      rescue StandardError
        nil
      end
      false
    end
  end

  # The whole of it: nil when there is nothing to remove (which is most
  # photos), otherwise the same bytes with the GPS block gone.
  #
  # The block is emptied in place rather than cut out, and the file keeps its
  # exact length. Every offset inside a TIFF block is counted from the start
  # of that block, so removing bytes would mean rewriting every offset in it,
  # including ones belonging to tags this has no business understanding.
  # Leaving a hole costs a few dozen bytes and cannot corrupt a tag it never
  # looked at. What matters is that the coordinates are overwritten, not
  # merely unreferenced -- an unlinked GPS block is still a GPS block to
  # anything that reads the file with a hex editor.
  def strip(data)
    # Binary throughout: String#[]= counts characters, and on a UTF-8-tagged
    # copy of the same bytes it would write in the wrong place -- or raise on
    # a byte sequence that is not a character at all. Downloaded bodies
    # arrive tagged however the connection felt like tagging them.
    data = data.b
    each_app1(data) do |offset, length|
      payload_at = offset + 4
      payload = data.byteslice(payload_at, length - 2).to_s
      next unless payload.start_with?(EXIF_PREFIX)

      out = strip_tiff(payload.byteslice(6..).to_s)
      next unless out

      copy = data.dup
      copy[(payload_at + 6), out.bytesize] = out
      return copy
    end
    nil
  end

  # --- reading ------------------------------------------------------------

  def located?(data)
    data = data.b
    each_app1(data) do |offset, length|
      payload = data.byteslice(offset + 4, length - 2).to_s
      next unless payload.start_with?(EXIF_PREFIX)

      tiff = payload.byteslice(6..).to_s
      found = gps_entry(tiff)
      return true if found && location?(tiff, found)
    end
    false
  end

  # Whether the GPS block holds anything beyond its own version number. A
  # block with only GPSVersionID in it is an empty envelope: rewriting the
  # file for it would change a photo's checksum -- and so re-upload it on the
  # next deploy -- to remove nothing at all.
  def location?(tiff, found)
    base = found[:target]
    short = found[:short]
    return false if base < 8 || base + COUNT_SIZE > tiff.bytesize

    count = tiff.byteslice(base, COUNT_SIZE).unpack1(short).to_i
    count.times do |i|
      entry = tiff.byteslice(base + COUNT_SIZE + (i * ENTRY_SIZE), ENTRY_SIZE)
      break unless entry && entry.bytesize == ENTRY_SIZE
      return true unless entry.byteslice(0, 2).unpack1(short) == GPS_VERSION_ID
    end
    false
  rescue StandardError
    false
  end

  # Walks the segment headers of a JPEG and yields each APP1's position and
  # declared length. Stops at the start of compressed data (SOS): everything
  # after it is the picture, and scanning it for markers finds them in the
  # pixels.
  def each_app1(data)
    return unless data.byteslice(0, 2) == "\xFF\xD8".b

    pos = 2
    while pos + 4 <= data.bytesize
      break unless data.getbyte(pos) == 0xFF

      marker = data.getbyte(pos + 1)
      break if marker == 0xDA || marker == 0xD9 # SOS, EOI

      length = data.byteslice(pos + 2, 2).to_s.unpack1('n').to_i
      break if length < 2

      yield(pos, length) if marker == 0xE1
      pos += 2 + length
    end
    nil
  end

  # The GPS pointer entry of IFD0, as [tiff_offset_of_entry, byte_order], or
  # nil. Deliberately shaped like media_dimensions.rb's orientation reader:
  # one tag, one pass, no recursion into the sub-IFDs that hold everything
  # else.
  def gps_entry(tiff)
    return nil if tiff.bytesize < 8

    short, long = byte_order(tiff)
    return nil unless short

    ifd = tiff.byteslice(4, 4).unpack1(long).to_i
    return nil if ifd < 8 || ifd + COUNT_SIZE > tiff.bytesize

    count = tiff.byteslice(ifd, COUNT_SIZE).unpack1(short).to_i
    count.times do |i|
      at = ifd + COUNT_SIZE + (i * ENTRY_SIZE)
      entry = tiff.byteslice(at, ENTRY_SIZE)
      break unless entry && entry.bytesize == ENTRY_SIZE
      next unless entry.byteslice(0, 2).unpack1(short) == GPS_IFD_POINTER

      return { at: at, ifd: ifd, count: count, short: short, long: long,
               target: entry.byteslice(8, 4).unpack1(long).to_i }
    end
    nil
  rescue StandardError
    nil
  end

  def byte_order(tiff)
    case tiff.byteslice(0, 2)
    when 'II'.b then ['v', 'V']
    when 'MM'.b then ['n', 'N']
    end
  end

  # --- writing ------------------------------------------------------------

  # Returns the TIFF block without its GPS data, or nil when it had none.
  def strip_tiff(tiff)
    found = gps_entry(tiff)
    return nil unless found && location?(tiff, found)

    out = tiff.dup
    zero_gps_ifd(out, found)
    drop_entry(out, found)
    out
  rescue StandardError
    nil
  end

  # Overwrites the GPS IFD itself and everything it points at. The entries
  # come first so their offsets can still be read, then the block that held
  # them -- a coordinate is a RATIONAL triplet stored outside the entry, so
  # zeroing the entries alone would leave the numbers lying in the file.
  def zero_gps_ifd(out, found)
    short, long = found[:short], found[:long]
    base = found[:target]
    return if base < 8 || base + COUNT_SIZE > out.bytesize

    count = out.byteslice(base, COUNT_SIZE).unpack1(short).to_i
    count.times do |i|
      at = base + COUNT_SIZE + (i * ENTRY_SIZE)
      entry = out.byteslice(at, ENTRY_SIZE)
      break unless entry && entry.bytesize == ENTRY_SIZE

      size = TYPE_SIZES.fetch(entry.byteslice(2, 2).unpack1(short).to_i, 0) *
             entry.byteslice(4, 4).unpack1(long).to_i
      next unless size > 4

      blank(out, entry.byteslice(8, 4).unpack1(long).to_i, size)
    end
    blank(out, base, COUNT_SIZE + (count * ENTRY_SIZE) + NEXT_IFD_SIZE)
  end

  # Takes the pointer out of IFD0 by sliding the entries after it down and
  # saying there is one fewer. The freed twelve bytes at the end become dead
  # space inside the block, which no reader ever visits: entries are found by
  # counting from the start, data by absolute offset. Nothing moves, so
  # nothing else has to be rewritten.
  def drop_entry(out, found)
    short = found[:short]
    ifd = found[:ifd]
    tail_at = found[:at] + ENTRY_SIZE
    tail_end = ifd + COUNT_SIZE + (found[:count] * ENTRY_SIZE) + NEXT_IFD_SIZE
    return if tail_end > out.bytesize

    tail = out.byteslice(tail_at, tail_end - tail_at).to_s
    out[found[:at], tail.bytesize] = tail
    blank(out, found[:at] + tail.bytesize, ENTRY_SIZE)
    out[ifd, COUNT_SIZE] = [found[:count] - 1].pack(short)
  end

  def blank(out, at, size)
    return if size <= 0 || at < 8 || at + size > out.bytesize

    out[at, size] = "\0".b * size
  end
end
