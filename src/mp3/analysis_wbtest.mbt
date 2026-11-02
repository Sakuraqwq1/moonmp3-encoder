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
test "quantiser : a tone becomes unit coefficients and a gain" {
  let lines = Array::make(576, 0.0)
  lines[12] = 8.0
  lines[13] = -4.0
  lines[14] = 1.0
  let (gain, quantized) = quantize_count1(lines) catch {
    (_ : QuantizeError) => {
      assert_true(false)
      return
    }
  }
  // 210 + 4 log2(8) = 222.
  assert_eq(gain, 222)
  assert_eq(quantized[12], 1)
  assert_eq(quantized[13], -1)
  // 1.0 is a quarter of the peak, so it falls under the half-peak cut-off.
  assert_eq(quantized[14], 0)
  assert_eq(count1_nonzero(quantized), 2)
  assert_eq(count1_cost(quantized), 576 + 2)
}
