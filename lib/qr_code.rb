# frozen_string_literal: true

# lib/qr_code.rb -- a minimal QR encoder, so the CLI can show a draft's
# preview URL as a scannable code right in the terminal: publish over SSH,
# point the phone at the screen, preview open. Pure stdlib, like
# everything else here -- which means encoding QR by hand.
#
# Deliberately the smallest correct subset of the spec this use needs:
# byte mode, error-correction level L, versions 1-5 only (all
# single-ECC-block, which keeps the interleaving step away entirely) --
# that's up to 106 bytes, comfortably above any draft URL; longer input
# returns nil and the caller just skips the QR. The mask is fixed to
# pattern 0 instead of scoring all eight: the format bits declare the
# mask, so every decoder handles it; penalty scoring only optimizes
# scannability margins, and a terminal render has bigger distortions than
# a suboptimal mask anyway.
module QrCode
  # [data codewords, error-correction codewords] per version, level L.
  CODEWORDS = { 1 => [19, 7], 2 => [34, 10], 3 => [55, 15], 4 => [80, 20], 5 => [108, 26] }.freeze
  # Precomputed BCH(15,5) format strings for level L, masks 0-7 -- only
  # mask 0 is used, the rest kept for reference.
  FORMAT_L = %w[
    111011111000100 111001011110011 111110110101010 111100010011101
    110011000101111 110001100011000 110110001000001 110100101110110
  ].freeze

  module_function

  # --- GF(256) arithmetic for Reed-Solomon ---------------------------------

  GF_EXP = Array.new(512)
  GF_LOG = Array.new(256)
  x = 1
  256.times do |i|
    GF_EXP[i] = x
    GF_LOG[x] = i if i < 255
    x <<= 1
    x ^= 0x11D if x > 255
  end
  255.times { |i| GF_EXP[255 + i] = GF_EXP[i] }

  def gf_mul(a, b)
    return 0 if a.zero? || b.zero?

    GF_EXP[GF_LOG[a] + GF_LOG[b]]
  end

  # Coefficients leading-first (index 0 = x^degree), which is the order
  # the synthetic division below consumes them in.
  def generator_poly(degree)
    poly = [1]
    degree.times do |i|
      next_poly = Array.new(poly.size + 1, 0)
      poly.each_with_index do |coef, j|
        next_poly[j] ^= gf_mul(coef, GF_EXP[i])
        next_poly[j + 1] ^= coef
      end
      poly = next_poly
    end
    poly.reverse
  end

  def ecc_for(data, degree)
    gen = generator_poly(degree)
    remainder = Array.new(degree, 0)
    data.each do |byte|
      factor = byte ^ remainder.shift
      remainder.push(0)
      gen[1..].each_with_index do |coef, i|
        remainder[i] ^= gf_mul(coef, factor)
      end
    end
    remainder
  end

  # --- encoding ------------------------------------------------------------

  def codewords(bytes, data_capacity)
    bits = +'0100'
    bits << bytes.size.to_s(2).rjust(8, '0')
    bytes.each { |b| bits << b.to_s(2).rjust(8, '0') }

    capacity_bits = data_capacity * 8
    bits << '0' * [4, capacity_bits - bits.size].min
    bits << '0' * ((8 - bits.size % 8) % 8)
    words = bits.scan(/.{8}/).map { |w| w.to_i(2) }
    # Pad bytes alternate 0xEC, 0x11, always starting with 0xEC --
    # counted from the first pad, not from the stream length.
    pads = 0
    while words.size < data_capacity
      words << (pads.even? ? 0xEC : 0x11)
      pads += 1
    end
    words
  end

  # Returns the module matrix (arrays of booleans, true = dark) or nil
  # when the text doesn't fit version 5.
  def encode(text)
    bytes = text.to_s.b.bytes
    version = CODEWORDS.keys.find { |v| bytes.size <= CODEWORDS[v][0] - 2 }
    return nil unless version

    data_cap, ecc_len = CODEWORDS[version]
    data = codewords(bytes, data_cap)
    stream = data + ecc_for(data, ecc_len)

    size = 17 + 4 * version
    matrix = Array.new(size) { Array.new(size) }
    function = Array.new(size) { Array.new(size, false) }

    place_function_patterns(matrix, function, version, size)
    place_data(matrix, function, stream, size)
    place_format_bits(matrix, size)
    matrix
  end

  def place_function_patterns(matrix, function, version, size)
    set = lambda do |r, c, dark|
      return if r.negative? || c.negative? || r >= size || c >= size

      matrix[r][c] = dark
      function[r][c] = true
    end

    # Finder patterns with separators at three corners.
    [[0, 0], [0, size - 7], [size - 7, 0]].each do |orow, ocol|
      (-1..7).each do |r|
        (-1..7).each do |c|
          dark = r.between?(0, 6) && c.between?(0, 6) &&
                 (r.zero? || r == 6 || c.zero? || c == 6 || (r.between?(2, 4) && c.between?(2, 4)))
          set.call(orow + r, ocol + c, dark)
        end
      end
    end

    # Timing patterns.
    (8..size - 9).each do |i|
      set.call(6, i, i.even?)
      set.call(i, 6, i.even?)
    end

    # One alignment pattern for versions 2-5, centered at (c, c).
    if version >= 2
      center = 4 * version + 10
      (-2..2).each do |r|
        (-2..2).each do |c|
          dark = r.abs == 2 || c.abs == 2 || (r.zero? && c.zero?)
          set.call(center + r, center + c, dark)
        end
      end
    end

    # Dark module, and the reserved format-information areas (filled in
    # later, but data placement must already skip them).
    set.call(4 * version + 9, 8, true)
    (0..8).each do |i|
      set.call(8, i, false) unless function[8][i]
      set.call(i, 8, false) unless function[i][8]
      set.call(8, size - 1 - i, false) if i < 8 && !function[8][size - 1 - i]
      set.call(size - 1 - i, 8, false) if i < 7 && !function[size - 1 - i][8]
    end
  end

  # The standard zigzag: column pairs right to left (skipping the timing
  # column 6), alternating upward and downward, MSB first -- with mask
  # pattern 0 ((row + col) even flips) applied on the way in.
  def place_data(matrix, function, stream, size)
    bits = stream.flat_map { |w| 7.downto(0).map { |i| (w >> i) & 1 } }
    index = 0
    upward = true
    col = size - 1
    while col > 0
      col -= 1 if col == 6
      rows = upward ? (size - 1).downto(0) : 0.upto(size - 1)
      rows.each do |row|
        [col, col - 1].each do |c|
          next if function[row][c]

          bit = bits[index] || 0
          index += 1
          matrix[row][c] = ((row + c).even? ? bit.zero? : bit == 1)
        end
      end
      upward = !upward
      col -= 2
    end
  end

  def place_format_bits(matrix, size)
    bits = FORMAT_L[0].chars.map { |c| c == '1' }

    copy1 = (0..5).map { |i| [8, i] } + [[8, 7], [8, 8], [7, 8]] + 5.downto(0).map { |i| [i, 8] }
    copy2 = (1..7).map { |i| [size - i, 8] } + (8.downto(1)).map { |i| [8, size - i] }
    copy1.each_with_index { |(r, c), i| matrix[r][c] = bits[i] }
    copy2.each_with_index { |(r, c), i| matrix[r][c] = bits[i] }
  end

  # --- terminal rendering --------------------------------------------------

  QUIET = 4

  # Half-block glyphs: one character per module horizontally, two module
  # rows per text line -- a version-1 code fits in 15 lines. Pure glyphs,
  # no colors, so it works on any terminal; on a dark background the code
  # comes out inverted, which phone scanners handle.
  def render(text)
    matrix = encode(text)
    return nil unless matrix

    size = matrix.size
    total = size + 2 * QUIET
    dark = ->(r, c) { r.between?(0, size - 1) && c.between?(0, size - 1) && matrix[r][c] }

    (0...total).step(2).map do |row|
      (0...total).map do |col|
        upper = dark.call(row - QUIET, col - QUIET)
        lower = dark.call(row + 1 - QUIET, col - QUIET)
        if upper && lower then '█'
        elsif upper then '▀'
        elsif lower then '▄'
        else ' '
        end
      end.join
    end.join("\n")
  end
end
