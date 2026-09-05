# frozen_string_literal: true

# lib/video_probe.rb -- which codec a local video actually carries, read
# out of the file's own boxes. No ffprobe, no gems: the same MP4/MOV box
# walk MediaDimensions already does for the picture size, taken two levels
# further down to the sample description.
#
# It exists for one question the author cannot answer by looking: a phone
# records HEVC by default, and an HEVC video in a post plays for most
# readers but not all -- the file name, the size and the preview say
# nothing about it. Knowing the codec is what lets the CLI mention it
# while the author can still do something about it.
#
# Not a refusal, deliberately. HEVC is not HEIC: a HEIC photo displays in
# Safari and nowhere else, while HEVC video plays in the large majority of
# browsers. Refusing it would take a file most readers could watch. See
# docs/decisions.md.
module VideoProbe
  # The sample-description codes that mean HEVC. hvc1 and hev1 differ only
  # in where the parameter sets are kept; dvh1/dvhe are Dolby Vision, which
  # is an HEVC stream with extra metadata -- and the same playback question.
  HEVC_CODECS = %w[hvc1 hev1 dvh1 dvhe].freeze

  # Boxes that hold other boxes on the way from the file down to stsd.
  # trak is handled separately: it is where a track's identity starts.
  CONTAINERS = %w[moov mdia minf stbl].freeze
  MAX_DEPTH = 6

  module_function

  def hevc?(path)
    HEVC_CODECS.include?(codec(path))
  end

  # Whether the index is at the FRONT of the file. A player needs the moov
  # box before it can show a frame, and a recorder can only write it when
  # the recording is over -- so a phone, and the share sheet that repacks
  # what a phone recorded, put it last. The reader then waits for the
  # whole file where they could have waited for the first second of it,
  # and on a slow connection that is the difference between a video and a
  # spinner.
  #
  # nil, not false, when the question does not arise: a file with no moov
  # or no mdat is not a movie this can say anything about, and a caller
  # must not read "unknown" as "badly ordered". Top level only -- both
  # boxes are the file's own, and finding them means reading a handful of
  # headers rather than the gigabyte between them.
  def faststart?(path)
    order = File.open(path, 'rb') { |f| top_level_order(f) }
    return nil unless order.include?('moov') && order.include?('mdat')

    order.index('moov') < order.index('mdat')
  rescue StandardError
    nil
  end

  # The four-character code of the first VIDEO track's sample description
  # ("hvc1", "avc1", ...), or nil for anything unreadable or not a movie.
  # Unreadable is not an error here, exactly as in MediaDimensions: a file
  # this cannot parse is simply a file whose codec is unknown, and an
  # unknown codec must never stop a save.
  def codec(path)
    File.open(path, 'rb') { |f| walk(f, 0, f.size, 0, nil) }
  rescue StandardError
    nil
  end

  # The four-character types of the top-level boxes, in the order the file
  # carries them. Its own reader rather than a mode of walk: walk descends,
  # and descending is exactly what this must not do -- an mdat holds
  # gigabytes that are not boxes at all, and a moov nested inside a
  # fragment is not the file's index. Sixty-four is a ceiling on a list
  # that is normally four entries long; a file that hands out more headers
  # than that has stopped being a movie and the answer is "unknown".
  def top_level_order(file)
    order = []
    offset = 0
    limit = file.size
    while offset < limit && order.size < 64
      file.seek(offset)
      header = file.read(8)
      break unless header && header.bytesize == 8

      size = header.byteslice(0, 4).unpack1('N').to_i
      order << header.byteslice(4, 4).to_s.force_encoding('UTF-8')
      if size == 1
        large = file.read(8)
        break unless large && large.bytesize == 8

        size = large.unpack1('Q>').to_i
      end
      size = limit - offset if size.zero?
      break if size < 8

      offset += size
    end
    order
  end

  # `track` carries whether the trak being walked is the video one -- the
  # audio track has a sample description too, and whichever comes first in
  # the file is an accident of the encoder. Taking the first one found
  # reports "mp4a" for most phone videos, which is a true fact about the
  # wrong track.
  def walk(file, offset, limit, depth, track)
    while offset < limit
      file.seek(offset)
      header = file.read(8)
      break unless header && header.bytesize == 8

      size = header.byteslice(0, 4).unpack1('N').to_i
      type = header.byteslice(4, 4)
      body = offset + 8
      # size 1 puts a 64-bit length in the next eight bytes; size 0 means
      # the box runs to the end of its parent.
      if size == 1
        large = file.read(8)
        break unless large && large.bytesize == 8

        size = large.unpack1('Q>').to_i
        body += 8
      end
      size = limit - offset if size.zero?
      break if size < 8

      found = descend(file, type, body, offset + size, depth, track)
      return found if found

      offset += size
    end
    nil
  end

  def descend(file, type, body, box_end, depth, track)
    return nil if depth >= MAX_DEPTH

    case type
    when 'trak'.b
      walk(file, body, box_end, depth + 1, { video: false })
    when 'hdlr'.b
      # version/flags (4) + pre_defined (4), then the handler type -- the
      # same offset in QuickTime, where those four bytes are the component
      # subtype.
      #
      # The FIRST hdlr in a track is the one that says what the track is:
      # it sits in mdia, before minf. minf holds a second hdlr -- the DATA
      # handler, "alis" or "url " -- and reading that one as the track's
      # identity turned every video track into a non-video track. Which is
      # exactly what happened: every .mov out of the phone probed as "no
      # codec found", and the feature would have sat there doing nothing.
      if track && !track[:decided]
        file.seek(body + 8)
        track[:video] = file.read(4) == 'vide'.b
        track[:decided] = true
      end
      nil
    when 'stsd'.b
      return nil unless track && track[:video]

      # version/flags (4) + entry count (4), then the first entry: its own
      # size, then the four-character format.
      file.seek(body + 8)
      entry = file.read(8).to_s
      code = entry.byteslice(4, 4)
      code && code.bytesize == 4 ? code.force_encoding('UTF-8') : nil
    else
      CONTAINERS.include?(type.to_s.force_encoding('UTF-8')) ? walk(file, body, box_end, depth + 1, track) : nil
    end
  end
end
