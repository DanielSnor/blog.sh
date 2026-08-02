# frozen_string_literal: true

# lib/media_dimensions.rb -- reads pixel dimensions straight out of image
# and video file headers, no external tools or gems. Used by manage_post.rb
# to stamp width/height onto media blocks, so the page can reserve space
# before the file loads and never jumps. Extracted from manage_post.rb,
# where ~90 lines of binary header parsing sat between CLI commands.
#
# Both readers return [width, height] or nil. Every parse error is
# deliberately swallowed into nil: a file these readers can't understand is
# not an error, just a file without known dimensions.
#
# But a nil is not harmless downstream, so anything writing an image block
# should try hard to get real numbers: `degenerate_image?` in
# build_blog.rb tests `media['width'].to_i <= 1`, and `nil.to_i` is 0 --
# so an image block with no dimensions is dropped from the rendered page
# exactly like a 1x1 tracking pixel. (An earlier version of this comment
# claimed the opposite; the code has always been the other way.)
module MediaDimensions
  module_function

  # PNG (IHDR, fixed offset), GIF (logical screen descriptor), WebP (the
  # RIFF chunk, in three flavours) and JPEG (scan the segment markers for
  # the SOFn frame header). Only the first bytes are ever read.
  #
  # HEIC is deliberately absent: Chrome and Firefox don't render it at all,
  # so knowing its dimensions would only produce a page that works in
  # Safari and shows a broken image to everyone else. Converting it is a
  # separate, opt-in decision (see media.convert_heic in the roadmap), not
  # something a dimension reader can paper over.
  def image(path)
    File.open(path, 'rb') do |f|
      head = f.read(30)
      return nil unless head

      if head.byteslice(0, 8) == "\x89PNG\r\n\x1a\n".b
        w, h = head.byteslice(16, 8).unpack('N2')
        return [w, h]
      elsif head.byteslice(0, 3) == 'GIF'.b
        # Logical screen descriptor: width and height, 16-bit little-endian.
        return head.byteslice(6, 4).unpack('v2')
      elsif head.byteslice(0, 4) == 'RIFF'.b && head.byteslice(8, 4) == 'WEBP'.b
        return webp(head)
      elsif head.byteslice(0, 3) == "\xFF\xD8\xFF".b
        f.rewind
        f.read(2)
        loop do
          marker = f.read(2)
          break unless marker && marker.bytesize == 2

          len = f.read(2)&.unpack1('n')
          break unless len

          code = marker.getbyte(1)
          if (0xC0..0xCF).cover?(code) && ![0xC4, 0xC8, 0xCC].include?(code)
            f.read(1)
            h, w = f.read(4).unpack('n2')
            return [w, h]
          else
            f.seek(len - 2, IO::SEEK_CUR)
          end
        end
      end
    end
    nil
  rescue StandardError
    nil
  end

  # WebP has three container flavours and each keeps its size somewhere
  # else: lossy (VP8 ) after the sync code, lossless (VP8L) as two 14-bit
  # fields packed into four bytes, extended (VP8X) as a 24-bit canvas size.
  # All three sit within the first 30 bytes, so no extra read is needed.
  def webp(head)
    case head.byteslice(12, 4)
    when 'VP8 '.b
      return nil unless head.byteslice(23, 3) == "\x9D\x01\x2A".b

      w, h = head.byteslice(26, 4).unpack('v2')
      [w & 0x3FFF, h & 0x3FFF]
    when 'VP8L'.b
      return nil unless head.getbyte(20) == 0x2F

      bits = head.byteslice(21, 4).unpack1('V')
      [(bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1]
    when 'VP8X'.b
      w = head.byteslice(24, 2).unpack1('v') | (head.getbyte(26) << 16)
      h = head.byteslice(27, 2).unpack1('v') | (head.getbyte(29) << 16)
      [w + 1, h + 1]
    end
  end

  # MP4/MOV dimensions from the tkhd atom (moov > trak > tkhd). Without
  # them <video> would have no reserved space and the page would jump on
  # load -- the same reason images and the banner carry dimensions. Only
  # reads headers by scanning through them; the actual video data is never
  # loaded.
  def video(path)
    File.open(path, 'rb') { |f| find_tkhd(f, f.size) }
  rescue StandardError
    nil
  end

  def find_tkhd(io, limit)
    while io.pos < limit
      start = io.pos
      header = io.read(8)
      break unless header && header.bytesize == 8

      size, type = header.unpack('Na4')
      header_size = 8
      if size == 1
        size = io.read(8).unpack1('Q>')
        header_size = 16
      elsif size.zero?
        size = limit - start
      end
      break if size < header_size

      finish = start + size
      if %w[moov trak mdia].include?(type)
        found = find_tkhd(io, [finish, limit].min)
        return found if found
      elsif type == 'tkhd'
        found = parse_tkhd(io.read(size - header_size))
        return found if found
      end
      io.seek(finish)
    end
    nil
  end

  # The audio track has zeros in its tkhd, so the first track with nonzero
  # dimensions is used. A phone video's rotation is hidden in the transform
  # matrix -- at 90/270 degrees the tkhd dimensions are pre-rotation, so
  # they get swapped.
  def parse_tkhd(body)
    return nil unless body

    version_offset = body.getbyte(0) == 1 ? 36 : 24
    matrix_at = version_offset + 16
    return nil if body.bytesize < matrix_at + 44

    matrix = body.byteslice(matrix_at, 36).unpack('N9')
    width = body.byteslice(matrix_at + 36, 4).unpack1('N') >> 16
    height = body.byteslice(matrix_at + 40, 4).unpack1('N') >> 16
    return nil if width.zero? || height.zero?

    rotated = matrix[0].zero? && matrix[4].zero? && !(matrix[1].zero? && matrix[3].zero?)
    rotated ? [height, width] : [width, height]
  end
end
