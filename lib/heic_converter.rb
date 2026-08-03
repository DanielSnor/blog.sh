# frozen_string_literal: true

require 'fileutils'

# lib/heic_converter.rb -- detects HEIC/HEIF photos by content and, when the
# site opted in (media.convert_heic in config/site.yml), converts them to
# JPEG by shelling out to an image tool the machine already has.
#
# Deliberately separate from MediaDimensions, whose whole point is reading
# headers with no external tools. Conversion is the one place the engine
# shells out for media, it is opt-in, and a missing tool degrades to
# refusing the file -- never to a broken archive. Same pattern as the
# deploy backends (git, rsync, rclone, sftp): system binaries a site
# chooses to rely on, not dependencies of the engine. The "zero gems"
# promise is about the Ruby dependency chain, and this adds nothing to it.
module HeicConverter
  # Brands from the HEIF spec that mean "an HEVC-coded image" -- what
  # iPhones produce, and what no browser except Safari displays. AVIF
  # shares the exact same ftyp container structure but Chrome and Firefox
  # render it natively, so converting it would be a bug: it is recognized
  # below and explicitly NOT treated as HEIC.
  HEIC_BRANDS = %w[heic heix hevc hevx heim heis hevm hevs].freeze
  AVIF_BRANDS = %w[avif avis].freeze
  CONTAINER_BRANDS = %w[mif1 msf1].freeze
  JPEG_QUALITY = 90

  module_function

  # Content detection, not extension: a HEIC renamed to .jpg is still a
  # HEIC (and still displays nowhere but Safari), while an AVIF named
  # .heic must not be converted needlessly. Reads the ftyp box, nothing
  # else, and any unreadable or non-BMFF file is simply "not HEIC".
  def heic?(path)
    File.open(path, 'rb') do |f|
      head = f.read(16)
      return false unless head && head.bytesize == 16
      return false unless head.byteslice(4, 4) == 'ftyp'.b

      major = head.byteslice(8, 4)
      return true if HEIC_BRANDS.include?(major)
      return false if AVIF_BRANDS.include?(major)
      return false unless CONTAINER_BRANDS.include?(major)

      # A generic HEIF container (mif1/msf1): the codec hides in the
      # compatible-brands list, which runs to the end of the ftyp box.
      box_size = head.byteslice(0, 4).unpack1('N')
      rest = f.read([box_size - 16, 240].min.to_i.clamp(0, 240)).to_s
      brands = rest.scan(/.{4}/m)
      return false if (brands & AVIF_BRANDS).any?

      (brands & HEIC_BRANDS).any?
    end
  rescue StandardError
    false
  end

  # [display name, conversion proc] of the first tool this machine has that
  # can actually read HEIC, or nil. Memoized: the capability probes cost a
  # subprocess each and the answer cannot change mid-run. Order: sips is
  # built into every Mac; heif-convert/heif-dec are libheif's own tools;
  # ImageMagick and vips are probed for an actual HEIC delegate, because a
  # binary that exists but cannot read the format would "convert" nothing.
  def tool
    return @tool if defined?(@tool)

    @tool = detect_tool
  end

  def detect_tool
    if RUBY_PLATFORM.include?('darwin') && command?('sips')
      return ['sips', ->(src, dest) { run('sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', JPEG_QUALITY.to_s, src, '--out', dest) }]
    end
    if command?('heif-convert')
      return ['heif-convert', ->(src, dest) { run('heif-convert', '-q', JPEG_QUALITY.to_s, src, dest) }]
    end
    if command?('heif-dec')
      return ['heif-dec', ->(src, dest) { run('heif-dec', '-q', JPEG_QUALITY.to_s, src, dest) }]
    end
    %w[magick convert].each do |im|
      next unless command?(im) && probe(im, '-list', 'format') =~ /^\s*HEIC\s+\S*\s+r/

      return [im, ->(src, dest) { run(im, src, '-quality', JPEG_QUALITY.to_s, dest) }]
    end
    if command?('vips') && probe('vips', '-l', 'heifload').include?('heifload')
      return ['vips', ->(src, dest) { run('vips', 'copy', src, "#{dest}[Q=#{JPEG_QUALITY}]") }]
    end
    nil
  end

  # true only when the tool exited cleanly AND left a non-empty file --
  # a converter that "succeeded" with an empty output is a failure with
  # extra steps, and half a photo must never enter the archive.
  def convert(src, dest)
    pair = tool
    return false unless pair

    pair[1].call(src, dest) && File.exist?(dest) && File.size(dest).positive?
  end

  # The ready-made command the refusal messages hand the author, matching
  # what this machine actually has.
  def suggested_command(src)
    base = File.basename(src)
    if RUBY_PLATFORM.include?('darwin')
      "sips -s format jpeg '#{base}' --out '#{base}.jpg'"
    else
      "heif-convert '#{base}' '#{base}.jpg'"
    end
  end

  def command?(name)
    system('which', name, out: File::NULL, err: File::NULL)
  end

  def probe(*args)
    IO.popen(args, err: File::NULL, &:read).to_s
  rescue StandardError
    ''
  end

  def run(*args)
    system(*args, out: File::NULL, err: File::NULL) ? true : false
  end
end
