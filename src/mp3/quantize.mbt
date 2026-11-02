// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Quantisation of one granule's 576 frequency lines down to the range the
// count1 Huffman region can represent, i.e. -1, 0 and 1.
//
// This is a deliberately narrow first step: it makes the whole chain
// PCM -> filterbank -> MDCT -> quantiser -> Huffman -> frame audible and
// verifiable, without the big_values tables, scalefactor bands or rate loop.
// The requantisation it inverts is ISO/IEC 11172-3 §2.4.2.7,
//
//   xr = sign(is) * |is|^(4/3) * 2^((global_gain - 210) / 4)
//
// (scalefactors are all zero here, so they drop out). That relation is pinned
// by the existing tone tests: one coefficient of 1.0 at global_gain 210
// decodes to a peak of about 1.0065, and at 206 to about 0.503.

///|
/// Failures reported by the quantiser.
pub suberror QuantizeError {
  /// The granule did not carry exactly 576 lines.
  BadLineCount(Int32)
}

///|
/// Frequency lines in one granule.
pub const LinesPerGranuleCount : Int32 = 576

///|
/// Rounding offset of the ISO quantiser. It is what makes the truncated
/// `|xr|^(3/4) + 0.4054` land on 1 for a line at exactly the top of the range,
/// and it is also why the natural cut-off sits at half of the granule peak:
/// `0.4054^(4/3) = 0.5`.
pub const QuantizeOffset : Double = 0.4054

///|
/// Gain that places `|is| = 1` such that a line of magnitude `peak` reaches it.
///
/// Solving `(|xr| / 2^((g - 210)/4))^(3/4) = 1` gives `g = 210 + 4 log2(peak)`.
/// The result is clamped to the 8-bit side-info field; a granule whose peak
/// falls outside that window is renormalised by the clamp.
pub fn global_gain_for_peak(peak : Double) -> Int32 {
  if peak <= 0.0 {
    return 0
  }
  let gain = (210.0 + 4.0 * @math.log2(peak)).round()
  if gain <= 0.0 {
    return 0
  }
  if gain >= 255.0 {
    return 255
  }
  gain.to_int()
}

///|
/// Quantise with a fixed gain, dropping every line below `floor`.
fn quantize_floor(
  lines : Array[Double],
  gain : Int32,
  floor : Double,
) -> Array[Int32] {
  let amplitude = @math.pow(2.0, (gain.to_double() - 210.0) / 4.0)
  let quantized = Array::make(LinesPerGranuleCount, 0)
  for index = 0; index < LinesPerGranuleCount; index = index + 1 {
    let value = lines[index]
    if value.abs() < floor {
      continue
    }
    let magnitude = @math.pow(value.abs() / amplitude, 0.75) + QuantizeOffset
    if magnitude.floor().to_int() > 0 {
      quantized[index] = if value < 0.0 { -1 } else { 1 }
    }
  }
  quantized
}

///|
/// Quantise 576 frequency lines to -1, 0 or 1 and report the `global_gain` the
/// decoder needs to place them at the right amplitude.
///
/// Every line above half of the granule peak becomes a unit coefficient and
/// everything quieter becomes zero, so a pure tone costs one or two coefficients
/// per subband and a dense spectrum costs many.
pub fn quantize_count1(
  lines : Array[Double],
) -> (Int32, Array[Int32]) raise QuantizeError {
  if lines.length() != LinesPerGranuleCount {
    raise BadLineCount(lines.length())
  }
  let peak = peak_absolute(lines)
  if peak <= 0.0 {
    return (0, Array::make(LinesPerGranuleCount, 0))
  }
  let gain = global_gain_for_peak(peak)
  (gain, quantize_floor(lines, gain, peak * 0.5))
}

///|
/// Exact bit cost of a count1 granule: four mask bits per quadruple plus one
/// sign bit per non-zero coefficient.
///
/// The count1 writer refuses out-of-range input, but this quantiser can only
/// emit -1, 0 and 1, so the cost can be computed directly and cannot disagree
/// with what `write_count1` will emit.
pub fn count1_cost(values : Array[Int32]) -> Int32 {
  let mut bits = values.length()
  for value in values {
    if value != 0 {
      bits = bits + 1
    }
  }
  bits
}

///|
/// Non-zero coefficients in a quantised granule.
pub fn count1_nonzero(values : Array[Int32]) -> Int32 {
  let mut count = 0
  for value in values {
    if value != 0 {
      count = count + 1
    }
  }
  count
}

///|
/// Quantise while respecting a budget of at most `limit` non-zero coefficients.
///
/// A dense spectrum can cost more than a frame holds — stereo has about 762 bits
/// of main data per granule, so at most 186 unit coefficients once the 576 mask
/// bits are paid for. Rather than overflow the frame or silently drop the
/// stream, the quantiser raises its cut-off above half of the peak until the
/// count fits: the loudest lines survive and the coefficients that would not
/// have been audible go to zero.
pub fn quantize_count1_fitting(
  lines : Array[Double],
  limit : Int32,
) -> (Int32, Array[Int32]) raise QuantizeError {
  if lines.length() != LinesPerGranuleCount {
    raise BadLineCount(lines.length())
  }
  let peak = peak_absolute(lines)
  if peak <= 0.0 {
    return (0, Array::make(LinesPerGranuleCount, 0))
  }
  let gain = global_gain_for_peak(peak)
  let mut floor = peak * 0.5
  let mut quantized = quantize_floor(lines, gain, floor)
  let mut attempts = 0
  while count1_nonzero(quantized) > limit && attempts < 64 && floor < peak {
    floor = floor * 1.15
    quantized = quantize_floor(lines, gain, floor)
    attempts = attempts + 1
  }
  (gain, quantized)
}
