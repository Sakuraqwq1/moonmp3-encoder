// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Whitebox tests for the scalefactor band table, the `scalefac_compress`
// width table and the exact bit layout of the 21 transmitted values.

///|
test "scalefactor : the bands partition all 576 lines" {
  let mut total = 0
  for band = 0; band < LongFrequencyBandCount; band = band + 1 {
    let width = scalefactor_band_width(band)
    assert_true(width > 0)
    total = total + width
  }
  assert_eq(total, 576)
  // The first band is four lines wide, the transmitted table ends at 418 and
  // the unscaled tail (sfb 21) is 158 lines.
  assert_eq(scalefactor_band_start(0), 0)
  assert_eq(scalefactor_band_end(0), 4)
  assert_eq(scalefactor_band_start(20), 342)
  assert_eq(scalefactor_band_end(20), 418)
  assert_eq(scalefactor_band_width(20), 76)
  assert_eq(scalefactor_band_width(21), 158)
  assert_eq(scalefactor_band_of_line(417), 20)
  assert_eq(scalefactor_band_of_line(418), 21)
  assert_eq(scalefactor_band_of_line(575), 21)
}

///|
test "scalefactor : the compress table is ISO Table B.8" {
  let (first1, first2) = scalefactor_widths(0)
  assert_eq(first1, 0)
  assert_eq(first2, 0)
  let (middle1, middle2) = scalefactor_widths(5)
  assert_eq(middle1, 1)
  assert_eq(middle2, 1)
  let (high1, high2) = scalefactor_widths(15)
  assert_eq(high1, 4)
  assert_eq(high2, 3)
  let (odd1, odd2) = scalefactor_widths(14)
  assert_eq(odd1, 4)
  assert_eq(odd2, 2)
  // 11 values at slen1 plus 10 at slen2.
  assert_eq(scalefactor_bit_count(0), 0)
  assert_eq(scalefactor_bit_count(5), 21)
  assert_eq(scalefactor_bit_count(14), 64)
  assert_eq(scalefactor_bit_count(15), 74)
}

///|
test "scalefactor : compress selection spends the fewest bits" {
  assert_eq(scalefactor_compress_for(0, 0), 0)
  assert_eq(scalefactor_compress_for(1, 1), 5)
  // Two-bit group 2 holds 0..3, so compress 2 is cheaper than compress 3.
  assert_eq(scalefactor_compress_for(0, 3), 2)
  // Three bits carry 0..7, so compress 12 (3, 2) is enough for (4, 3) and
  // costs 53 bits; the wider compress 13 costs 63 and 14 costs 64.
  assert_eq(scalefactor_compress_for(4, 3), 12)
  assert_eq(scalefactor_compress_for(16, 0), -1)
  // slen2 tops out at three bits, so sfb 11..20 cannot carry 8..15.
  assert_eq(scalefactor_compress_for(0, 7), 3)
  assert_eq(scalefactor_compress_for(0, 8), -1)
  let values = zero_scalefactors()
  values[0] = 3
  values[10] = 2
  values[11] = 1
  values[20] = 3
  // Maxima (3, 3) need two bits per group; compress 9 is (2, 2), 42 bits.
  assert_eq(scalefactor_compress(values), 9)
}

///|
test "scalefactor : the 21 values are written sfb-major, slen1 then slen2" {
  let values = zero_scalefactors()
  values[0] = 1
  values[10] = 1
  values[11] = 1
  values[20] = 1
  let w = @bits.BitWriter::new()
  let bits = write_scalefactors(w, values, 5)
  assert_eq(bits, 21)
  assert_eq(w.bit_length(), 21)
  let bytes = w.finish()
  assert_eq(bytes[0].to_int(), 0x80)
  assert_eq(bytes[1].to_int(), 0x30)
  assert_eq(bytes[2].to_int(), 0x08)
}

///|
test "scalefactor : a band scalefactor changes only that band's step" {
  let lines = Array::make(576, 0.0)
  lines[0] = 0.1
  lines[4] = 0.1
  // A louder line in another band fixes the global gain, so the two equal
  // lines below it are not already clamped at level 15.
  lines[100] = 0.5
  let sf = zero_scalefactors()
  sf[0] = 2
  let quantiser = GranuleQuantiser::new(lines)
  let gain = global_gain_for_peak(peak_absolute(lines), MaxQuantLevel)
  let values = quantiser.quantise_scaled(gain, sf, 0)
  // 2^(0.75 * 0.5 * 2) = 2^0.75, so the first band lands about 1.68 levels
  // higher than the second at the same input amplitude.
  assert_true(values[0] > values[4])
  let plain = quantiser.quantise(gain)
  assert_true(
    quantiser.band_error(values, gain, sf, 0, 0) <
    quantiser.band_error(plain, gain, zero_scalefactors(), 0, 0),
  )
}

///|
test "scalefactor : the short block has 12 transmitted bands and an unscaled tail" {
  // 12 bands x 3 windows = 36 scalefactors, then a 168-line tail with no
  // scalefactor (lines 136..191 per window).
  assert_eq(ShortScalefactorCount, 36)
  assert_eq(short_scalefactor_band_of_frequency(0), 0)
  assert_eq(short_scalefactor_band_of_frequency(3), 0)
  assert_eq(short_scalefactor_band_of_frequency(4), 1)
  assert_eq(short_scalefactor_band_of_frequency(135), 11)
  assert_eq(short_scalefactor_band_of_frequency(136), 12)
  assert_eq(short_scalefactor_band_width(0), 4)
  assert_eq(short_scalefactor_band_width(12), 56)
}

///|
test "scalefactor : short coefficients reorder into [sfb][window][line]" {
  // Subband 0, window 0, line 0 is the very first Huffman coefficient.
  assert_eq(short_huffman_index(0, 0, 0), 0)
  // Subband 0, line 3 ends band 0; the next line (band 1) starts at 4*3 = 12.
  assert_eq(short_huffman_index(0, 0, 4), 12)
  // The reorder is a bijection over 576 lines: every Huffman index is hit once.
  let seen = Array::make(576, false)
  for subband = 0; subband < 32; subband = subband + 1 {
    for window = 0; window < 3; window = window + 1 {
      for line = 0; line < 6; line = line + 1 {
        let index = short_huffman_index(subband, window, line)
        assert_true(index >= 0 && index < 576)
        assert_eq(seen[index], false)
        seen[index] = true
      }
    }
  }
  for index = 0; index < 576; index = index + 1 {
    assert_eq(seen[index], true)
  }
}

///|
test "scalefactor : short field index maps the tail to the sentinel" {
  // sfb 0 window 0 is field 0; sfb 0 window 1 is field 1.
  assert_eq(short_scalefactor_of_line(0), 0)
  assert_eq(short_scalefactor_of_line(4), 1)
  // The tail (line >= 408) has no scalefactor and maps to the 36 sentinel.
  assert_eq(short_scalefactor_of_line(408), 36)
  assert_eq(short_scalefactor_of_line(575), 36)
  // The sentinel is never transmitted: a 36-entry vector has no index 36, so
  // callers index a 37-entry attenuation table where entry 36 is the fixed 1.0.
  assert_eq(short_scalefactor_bit_count(5), 36)
  assert_eq(short_scalefactor_bit_count(15), 126)
}

///|
test "scalefactor : short compress prices 18 values per group" {
  let sf = zero_short_scalefactors()
  assert_eq(short_scalefactor_compress(sf), 0)
  sf[0] = 3
  sf[18] = 2
  // Group 1 max 3 (two bits), group 2 max 2 (two bits): compress 9 is (2, 2).
  assert_eq(short_scalefactor_compress(sf), 9)
  // Group 2 cannot exceed 7 (three bits).
  let overflow = zero_short_scalefactors()
  overflow[18] = 8
  assert_eq(short_scalefactor_compress(overflow), -1)
}
