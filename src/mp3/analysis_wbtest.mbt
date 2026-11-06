// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Whitebox tests for the analysis layer. The window table is data with a known
// provenance, so it is pinned at a handful of indices; the filterbank and the
// MDCT are pinned behaviourally, by the properties a correct implementation must
// have rather than by hard-coded outputs.

///|
test "window : the table has the documented shape" {
  assert_eq(analysis_window.length(), 512)
  assert_eq(analysis_window[0], 0.0)
  assert_eq(analysis_window[256], 1.144989014)
  assert_eq(analysis_window[255], -1.144287109)
  // The published table is antisymmetric to about 2.5 % of its peak; that is a
  // property of the numbers, not of the reader, so it is pinned rather than
  // assumed exact.
  let mut worst = 0.0
  for index = 1; index < 511; index = index + 1 {
    let deviation = (analysis_window[index] + analysis_window[511 - index]).abs()
    if deviation > worst {
      worst = deviation
    }
  }
  assert_true(worst < 0.03)
}

///|
test "filterbank : a tone inside one band stays inside it" {
  // 344.53125 Hz is the centre of subband 0 (44100 / 64 / 2).
  let rate = 44100.0
  let subbands = Array::make(SubbandCount * LinesPerGranule, 0.0)
  let analyser = AnalysisFilterbank::new()
  let hop = Array::make(StepSamples, 0.0)
  let energy = Array::make(SubbandCount, 0.0)
  for step = 0; step < 64; step = step + 1 {
    for index = 0; index < StepSamples; index = index + 1 {
      let time = (step * StepSamples + index).to_double()
      hop[index] = @math.sin(2.0 * @math.PI * 344.53125 * time / rate)
    }
    let values = analyser.step(hop) catch {
      (_ : AnalysisError) => {
        assert_true(false)
        return
      }
    }
    for band = 0; band < SubbandCount; band = band + 1 {
      let value = values[band]
      energy[band] = energy[band] + value * value
    }
  }
  let _ = subbands
  let total = energy.fold(init=0.0, fn(acc, value) { acc + value })
  assert_true(energy[0] / total > 0.9)
  let mut largest = 0
  for band = 1; band < SubbandCount; band = band + 1 {
    if energy[band] > energy[largest] {
      largest = band
    }
  }
  assert_eq(largest, 0)
}

///|
test "mdct : cached windows and kernels match their mathematical definitions" {
  for block_type = 0; block_type < 4; block_type = block_type + 1 {
    for index = 0; index < LongBlockSamples; index = index + 1 {
      assert_eq(
        block_windows[block_type * LongBlockSamples + index],
        block_window(block_type, index),
      )
    }
  }
  for line = 0; line < LongBlockLines; line = line + 1 {
    for index = 0; index < LongBlockSamples; index = index + 1 {
      let expected = @math.cos(
        @math.PI /
        72.0 *
        (2.0 * index.to_double() + 19.0) *
        (2.0 * line.to_double() + 1.0),
      )
      assert_eq(long_mdct_cosines[line * LongBlockSamples + index], expected)
    }
  }
  for line = 0; line < ShortBlockLines; line = line + 1 {
    for index = 0; index < ShortBlockSamples; index = index + 1 {
      let expected = @math.cos(
        @math.PI /
        24.0 *
        (2.0 * index.to_double() + 7.0) *
        (2.0 * line.to_double() + 1.0),
      )
      assert_eq(short_mdct_cosines[line * ShortBlockSamples + index], expected)
    }
  }
  for index = 0; index < ShortBlockSamples; index = index + 1 {
    assert_eq(short_window[index], short_block_window(index))
  }
}

///|
test "mdct : overlapping blocks reconstruct through time-domain aliasing cancellation" {
  // Three blocks with 50 % overlap cover 72 samples. The sine window satisfies
  // w[n]^2 + w[n + 18]^2 = 1, so overlap-adding the windowed inverse transforms
  // has to give the input back, up to the fixed 9x gain of the untransposed
  // inverse. Only the fully overlapped middle is compared: the first and last
  // 18 samples see a single block and are the stream's start-up transient.
  let length = 72
  let signal = Array::make(length, 0.0)
  for index = 0; index < length; index = index + 1 {
    signal[index] = @math.sin(0.31 * index.to_double()) +
      0.2 * @math.cos(0.11 * index.to_double())
  }
  let accumulated = Array::make(length, 0.0)
  let block = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < 3; index = index + 1 {
    for offset = 0; offset < LongBlockSamples; offset = offset + 1 {
      block[offset] = signal[index * LinesPerGranule + offset]
    }
    let lines = mdct_long(block) catch {
      (_ : AnalysisError) => {
        assert_true(false)
        return
      }
    }
    let restored = imdct_long(lines) catch {
      (_ : AnalysisError) => {
        assert_true(false)
        return
      }
    }
    for offset = 0; offset < LongBlockSamples; offset = offset + 1 {
      accumulated[index * LinesPerGranule + offset] = accumulated[index *
        LinesPerGranule +
        offset] +
        restored[offset]
    }
  }
  // Least-squares gain, then the relative residual.
  let mut cross = 0.0
  let mut energy = 0.0
  for index = LinesPerGranule
      index < length - LinesPerGranule
      index = index + 1 {
    cross = cross + accumulated[index] * signal[index]
    energy = energy + signal[index] * signal[index]
  }
  let gain = cross / energy
  let mut worst = 0.0
  let mut peak = 0.0
  for index = LinesPerGranule
      index < length - LinesPerGranule
      index = index + 1 {
    let deviation = (accumulated[index] - gain * signal[index]).abs()
    if deviation > worst {
      worst = deviation
    }
    if signal[index].abs() > peak {
      peak = signal[index].abs()
    }
  }
  // The untransposed inverse has gain 18 / 2 = 9.
  assert_true((gain - 9.0).abs() < 0.001)
  assert_true(worst / peak < 0.000000001)
}

///|
test "windows : start and stop are the short block's two ends" {
  for index = 0; index < 18; index = index + 1 {
    let a = long_block_window(index)
    let b = long_block_window(index + 18)
    assert_true((a * a + b * b - 1.0).abs() < 0.000000000001)
  }
  for index = 0; index < 6; index = index + 1 {
    let a = short_block_window(index)
    let b = short_block_window(index + 6)
    assert_true((a * a + b * b - 1.0).abs() < 0.0000000001)
  }
  // A start window's last six samples are the short window's falling half, and
  // a stop window's first six samples are its rising half.
  for index = 24; index < 30; index = index + 1 {
    assert_true(
      (start_block_window(index) - short_block_window(index - 18)).abs() <
      0.000000000001,
    )
  }
  for index = 6; index < 12; index = index + 1 {
    assert_true(
      (stop_block_window(index) - short_block_window(index - 6)).abs() <
      0.000000000001,
    )
  }
}

///|
test "mdct : long/start/short/stop cancel their own time-domain aliasing" {
  let blocks = 6
  let signal = Array::make(18 * (blocks - 1) + 36, 0.0)
  for index = 0; index < signal.length(); index = index + 1 {
    signal[index] = @math.sin(index.to_double() * 0.31) +
      0.2 * @math.cos(index.to_double() * 0.11)
  }
  let types = [
    BlockTypeLong,
    BlockTypeStart,
    BlockTypeShort,
    BlockTypeShort,
    BlockTypeStop,
    BlockTypeLong,
  ]
  // The untransposed inverse of an N-point MDCT has gain N/2, which differs
  // between the 36-point (18) and 12-point (6) transforms. Normalise each
  // transform's lines by that gain before the inverse so the short and long
  // contributions overlap at a common scale.
  let accumulated = Array::make(signal.length(), 0.0)
  for b = 0; b < blocks; b = b + 1 {
    let block = Array::make(36, 0.0)
    for index = 0; index < 36; index = index + 1 {
      block[index] = signal[b * 18 + index]
    }
    if types[b] == BlockTypeShort {
      for window = 0; window < 3; window = window + 1 {
        let small = Array::make(12, 0.0)
        for index = 0; index < 12; index = index + 1 {
          small[index] = block[6 + window * 6 + index]
        }
        let lines = mdct_short(small) catch {
          (_ : AnalysisError) => {
            assert_true(false)
            return
          }
        }
        let normalised = Array::make(ShortBlockLines, 0.0)
        for index = 0; index < ShortBlockLines; index = index + 1 {
          normalised[index] = lines[index] / 3.0
        }
        let decoded = imdct_short(normalised) catch {
          (_ : AnalysisError) => {
            assert_true(false)
            return
          }
        }
        for index = 0; index < 12; index = index + 1 {
          accumulated[b * 18 + 6 + window * 6 + index] = accumulated[b * 18 +
            6 +
            window * 6 +
            index] +
            decoded[index]
        }
      }
    } else {
      let lines = mdct_switched_long(block, types[b]) catch {
        (_ : AnalysisError) => {
          assert_true(false)
          return
        }
      }
      let normalised = Array::make(LongBlockLines, 0.0)
      for index = 0; index < LongBlockLines; index = index + 1 {
        normalised[index] = lines[index] / 9.0
      }
      let decoded = imdct_switched_long(normalised, types[b]) catch {
        (_ : AnalysisError) => {
          assert_true(false)
          return
        }
      }
      for index = 0; index < 36; index = index + 1 {
        accumulated[b * 18 + index] = accumulated[b * 18 + index] +
          decoded[index]
      }
    }
  }
  let mut worst = 0.0
  let mut peak = 0.0
  for index = 18; index < signal.length() - 18; index = index + 1 {
    let error = (accumulated[index] - signal[index]).abs()
    if error > worst {
      worst = error
    }
    if signal[index].abs() > peak {
      peak = signal[index].abs()
    }
  }
  assert_true(worst / peak < 0.0000000001)
}

///|
/// Inverse of a long/start/stop MDCT with its own window.
fn imdct_switched_long(
  lines : Array[Double],
  block_type : Int32,
) -> Array[Double] raise AnalysisError {
  if lines.length() != LongBlockLines {
    raise BadBlockLength(lines.length())
  }
  let block = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < LongBlockSamples; index = index + 1 {
    let mut sum = 0.0
    for line = 0; line < LongBlockLines; line = line + 1 {
      sum = sum +
        lines[line] *
        @math.cos(
          @math.PI /
          72.0 *
          (2.0 * index.to_double() + 19.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    block[index] = sum * block_window(block_type, index)
  }
  block
}

///|
/// Inverse of the 12-point short MDCT, followed by the short window.
fn imdct_short(lines : Array[Double]) -> Array[Double] raise AnalysisError {
  if lines.length() != ShortBlockLines {
    raise BadBlockLength(lines.length())
  }
  let block = Array::make(ShortBlockSamples, 0.0)
  for index = 0; index < ShortBlockSamples; index = index + 1 {
    let mut sum = 0.0
    for line = 0; line < ShortBlockLines; line = line + 1 {
      sum = sum +
        lines[line] *
        @math.cos(
          @math.PI /
          24.0 *
          (2.0 * index.to_double() + 7.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    block[index] = sum * short_block_window(index)
  }
  block
}

///|
/// Inverse of `mdct_long`: 18 lines back to 36 subband samples, with the same
/// kernel and the same sine window. Used by the round-trip test above; the
/// encoder never needs it.
fn imdct_long(lines : Array[Double]) -> Array[Double] raise AnalysisError {
  if lines.length() != LongBlockLines {
    raise BadBlockLength(lines.length())
  }
  let block = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < LongBlockSamples; index = index + 1 {
    let mut sum = 0.0
    for line = 0; line < LongBlockLines; line = line + 1 {
      sum = sum +
        lines[line] *
        @math.cos(
          @math.PI /
          72.0 *
          (2.0 * index.to_double() + 19.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    block[index] = sum
  }
  let windowed = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < LongBlockSamples; index = index + 1 {
    windowed[index] = block[index] * long_block_window(index)
  }
  windowed
}

///|
test "granule : a steady tone concentrates in its own subband" {
  let samples = Array::make(GranulePcm, 0.0)
  let analyser = ChannelAnalysis::new()
  let mut lines : Array[Double] = []
  // Feed four granules so the overlap and the filterbank history are settled.
  for pass = 0; pass < 4; pass = pass + 1 {
    for index = 0; index < GranulePcm; index = index + 1 {
      let time = (pass * GranulePcm + index).to_double()
      samples[index] = 0.5 *
        @math.sin(2.0 * @math.PI * 344.53125 * time / 44100.0)
    }
    lines = analyser.granule(samples) catch {
      (_ : AnalysisError) => {
        assert_true(false)
        return
      }
    }
  }
  assert_eq(lines.length(), 576)
  // Every line outside subband 0 must be far below the strongest line of
  // subband 0: the prototype window has to reject the neighbouring bands.
  let mut peak_in_band = 0.0
  for index = 0; index < LongBlockLines; index = index + 1 {
    let magnitude = lines[index].abs()
    if magnitude > peak_in_band {
      peak_in_band = magnitude
    }
  }
  let mut peak_out_of_band = 0.0
  for index = LongBlockLines; index < 576; index = index + 1 {
    let magnitude = lines[index].abs()
    if magnitude > peak_out_of_band {
      peak_out_of_band = magnitude
    }
  }
  assert_true(peak_in_band > 0.0)
  assert_true(peak_out_of_band / peak_in_band < 0.1)
}

///|
test "quantiser : the peak lands on the top level available" {
  let lines = Array::make(576, 0.0)
  lines[12] = 8.0
  lines[13] = -4.0
  lines[14] = 0.25
  let peak = peak_absolute(lines)
  let gain = global_gain_for_peak(peak, MaxQuantLevel)
  // 210 + 4 log2(8 / 15^(4/3)) = 210 - 8.83, i.e. 201.
  assert_eq(gain, 201)
  let values = quantize_with_gain(lines, gain)
  // The companded peak has to reach the top level, and the half-amplitude line
  // has to keep its relative scale instead of collapsing to +-1.
  assert_eq(values[12], 15)
  assert_true(values[13] < -6 && values[13] > -12)
  assert_eq(values[13] < 0, true)
  assert_true(values[14] >= 0)
  // Nothing may exceed what an MPEG-1 table can carry.
  for index = 0; index < 576; index = index + 1 {
    assert_true(values[index].abs() <= MaxQuantLevel)
  }
}

///|
test "quantiser : the error metric puts the sign back on the reconstruction" {
  // A coefficient's reconstruction is `sign(is) |is|^(4/3) 2^((g-210)/4)`; an
  // error metric that drops the sign scores a sign-alternating granule as worse
  // than silence at every gain, and the allocator then picks gains at random.
  // Alternating +-0.5 over 36 lines is the smallest input that catches that: the
  // error has to come out far below the granule's own energy.
  let lines = Array::make(576, 0.0)
  let mut energy = 0.0
  for index = 0; index < 36; index = index + 1 {
    let value = if index % 2 == 0 { 0.5 } else { -0.5 }
    lines[index] = value
    energy = energy + value * value
  }
  let quantiser = GranuleQuantiser::new(lines)
  let gain = global_gain_for_peak(peak_absolute(lines), MaxQuantLevel)
  let values = quantiser.quantise(gain)
  let error = quantiser.error(values, gain)
  // With the sign restored the reconstruction is within a few percent, so the
  // residual is a small fraction of the energy; without it the residual is 4x.
  assert_true(error < energy * 0.01)
  assert_true(values[0] > 0)
  assert_true(values[1] < 0)
}

///|
test "quantiser : raising the gain only ever shrinks coefficients" {
  let lines = Array::make(576, 0.0)
  for index = 0; index < 576; index = index + 1 {
    lines[index] = @math.sin(index.to_double() * 0.37) * 6.0
  }
  let mut previous = quantize_with_gain(lines, 190)
  for gain = 191; gain < 196; gain = gain + 1 {
    let current = quantize_with_gain(lines, gain)
    for index = 0; index < 576; index = index + 1 {
      assert_true(current[index].abs() <= previous[index].abs())
    }
    previous = current
  }
}

///|
test "huffman : the tables are the ones the standard defines" {
  // Extents per ISO/IEC 11172-3 Table B.7: 1, 2, 2, -, 3, 3, 5, 5, 5, 7, 7, 7,
  // 15, -, 15. Table 0 encodes only zeros, 4 and 14 do not exist.
  assert_eq(huffman_table_extent[0], 0)
  assert_eq(huffman_table_extent[4], 0)
  assert_eq(huffman_table_extent[14], 0)
  assert_eq(huffman_table_extent[1], 1)
  assert_eq(huffman_table_extent[2], 2)
  assert_eq(huffman_table_extent[3], 2)
  assert_eq(huffman_table_extent[5], 3)
  assert_eq(huffman_table_extent[9], 5)
  assert_eq(huffman_table_extent[12], 7)
  assert_eq(huffman_table_extent[13], 15)
  assert_eq(huffman_table_extent[15], 15)
  // No MPEG-1 table uses escapes.
  for table = 0; table <= 15; table = table + 1 {
    assert_eq(table_linbits(table), 0)
  }
}

///|
test "huffman : known code words are bit-exact" {
  // Table 1 has four leaves: (0,0) is one bit, (1,0) is two bits, and (0,1) and
  // (1,1) are three. Pinning these four is what locks the transcription, and the
  // end-to-end decoder test is what proves the numbers are the standard's.
  assert_eq(pair_cost(1, 0, 0), 1)
  assert_eq(pair_cost(1, 1, 0), 3)
  assert_eq(pair_cost(1, 0, 1), 4)
  assert_eq(pair_cost(1, 1, 1), 5)
  // (1, 0) is code 01 with one positive sign bit: 010 in the top of the byte.
  let w = @bits.BitWriter::new()
  let bits = write_pair(w, 1, 1, 0) catch {
    (_ : HuffmanError) => {
      assert_true(false)
      return
    }
  }
  assert_eq(bits, 3)
  let bytes = w.finish()
  assert_eq(bytes[0].to_int(), 0b01000000)
  // (0, 0) is the single bit 1.
  let u = @bits.BitWriter::new()
  let _ = write_pair(u, 1, 0, 0) catch {
    (_ : HuffmanError) => {
      assert_true(false)
      return
    }
  }
  assert_eq(u.finish()[0].to_int(), 0b10000000)
}

///|
test "huffman : big_values covers every coefficient above one" {
  let values = Array::make(576, 0)
  values[0] = 3
  values[5] = -1
  // The last "big" coefficient is at index 0, so one pair is enough and the
  // +-1 at index 5 stays in the count1 tail.
  assert_eq(big_values_needed(values), 2)
  values[9] = 2
  // Index 9 needs 5 pairs, rounded up to a quad boundary.
  assert_eq(big_values_needed(values), 6)
  let zeros = Array::make(576, 0)
  assert_eq(big_values_needed(zeros), 0)
}

///|
test "huffman : table selection respects the extents" {
  let values = Array::make(576, 0)
  values[0] = 1
  values[1] = 2
  // A pair of (1, 2) needs a table that reaches 2.
  let table = choose_table(values, 2)
  assert_true(table >= 2)
  assert_true(table_extent(table) >= 2)
  // Costs must agree with what the writer emits.
  let w = @bits.BitWriter::new()
  let written = write_granule(w, values, table, 2) catch {
    (_ : HuffmanError) => {
      assert_true(false)
      return
    }
  }
  assert_eq(written, granule_cost(values, table, 2))
}

///|
test "huffman : a coefficient past the largest extent cannot be coded" {
  let values = Array::make(576, 0)
  values[0] = 15
  values[1] = 15
  // No MPEG-1 table escapes, so 15 is the cap and (15, 15) must still fit.
  assert_eq(choose_table(values, 2) >= 13, true)
  let w = @bits.BitWriter::new()
  let table = choose_table(values, 2)
  let written = write_granule(w, values, table, 2) catch {
    (_ : HuffmanError) => {
      assert_true(false)
      return
    }
  }
  assert_eq(written, granule_cost(values, table, 2))
}

///|
test "huffman : a granule with no count1 region can still be written" {
  // 288 pairs is the whole spectrum. There is then no count1 tail, and calling
  // the count1 writer with an empty array used to raise BadLength, which made
  // broadband transients fail to encode at all. Found by the impulse case in
  // tools/selftest.py.
  let values = Array::make(576, 0)
  for index = 0; index < 576; index = index + 1 {
    values[index] = if index % 2 == 0 { 1 } else { -1 }
  }
  let table = choose_table(values, 288)
  assert_true(table >= 1)
  let w = @bits.BitWriter::new()
  let written = write_granule(w, values, table, 288) catch {
    (_ : HuffmanError) => {
      assert_true(false)
      return
    }
  }
  assert_eq(written, granule_cost(values, table, 288))
  // Every pair carries two sign bits plus at least one code bit.
  assert_true(written >= 288 * 3)
}
