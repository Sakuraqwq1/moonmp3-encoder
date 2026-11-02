// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Quantisation, ISO/IEC 11172-3 §2.4.2.7, in the form big_values needs.
//
// The decoder requantises as
//
//   xr = sign(is) * |is|^(4/3) * 2^((global_gain - 210) / 4)
//
// (scalefactors are still all zero here, so they drop out), so the encoder's
// inverse is
//
//   is = sign(xr) * floor( (|xr| / 2^((gain - 210)/4))^(3/4) + 0.4054 )
//
// with `0.4054` the standard's rounding offset. The gain is now a real search
// rather than the fixed half-peak threshold of the first vertical slice: MPEG-1
// tables cannot escape past a magnitude of 15, so the search starts from the
// gain that maps the granule peak to 15 and coarsens until the granule fits its
// share of the frame.

///|
/// Frequency lines in one granule.
pub const LinesPerGranuleCount : Int32 = 576

///|
/// Rounding offset of the ISO quantiser; `0.4054^(4/3) = 0.5`.
pub const QuantizeOffset : Double = 0.4054

///|
/// Largest magnitude an MPEG-1 big_values table can carry.
pub const MaxQuantLevel : Int32 = 15

///|
/// Gain that maps a line of magnitude `peak` onto `top`.
///
/// Solving `(|xr| / 2^((g - 210)/4))^(3/4) = top` gives
/// `g = 210 + 4 log2(peak / top^(4/3))`. The result is clamped to the 8-bit
/// side-info field.
pub fn global_gain_for_peak(peak : Double, top : Int32) -> Int32 {
  if peak <= 0.0 || top <= 0 {
    return 0
  }
  let full = @math.pow(top.to_double(), 4.0 / 3.0)
  let gain = (210.0 + 4.0 * @math.log2(peak / full)).round()
  if gain <= 0.0 {
    return 0
  }
  if gain >= 255.0 {
    return 255
  }
  gain.to_int()
}

///|
/// Quantise every line with an explicit gain.
///
/// Magnitudes are clamped to `MaxQuantLevel`; with the gain chosen by
/// `global_gain_for_peak(peak, 15)` the clamp only bites on rounding noise, but
/// it has to be there because no MPEG-1 table can represent 16.
pub fn quantize_with_gain(lines : Array[Double], gain : Int32) -> Array[Int32] {
  let amplitude = @math.pow(2.0, (gain.to_double() - 210.0) / 4.0)
  let values = Array::make(LinesPerGranuleCount, 0)
  for index = 0
      index < lines.length() && index < LinesPerGranuleCount
      index = index + 1 {
    let value = lines[index]
    let magnitude = @math.pow(value.abs() / amplitude, 0.75) + QuantizeOffset
    let level = magnitude.floor().to_int()
    if level > 0 {
      let clamped = if level > MaxQuantLevel { MaxQuantLevel } else { level }
      values[index] = if value < 0.0 { -clamped } else { clamped }
    }
  }
  values
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
/// `i^(4/3)` for every level a table can carry: the decoder's dequantisation of
/// a unit level, so the quantiser can price a candidate without calling `pow`.
let dequant_levels : Array[Double] = [
  0.0, 1.0, 2.5198420997897464, 4.326748710922225, 6.349604207872798, 8.549879733383484,
  10.902723556992836, 13.390518279406722, 16.0, 18.720754407467133, 21.544346900318846,
  24.46371122807269, 27.473141821279957, 30.567350940369842, 33.74199169845322, 36.99318111495705,
]

///|
/// A granule's `|xr|^(3/4)`, precomputed once so that every candidate gain costs
/// one multiply and one truncation per line instead of a `pow`.
///
/// This is what makes an error-minimising gain search affordable: the encoder
/// can price a dozen gains per granule and keep the best that fits, rather than
/// taking the first that fits.
pub struct GranuleQuantiser {
  powers : Array[Double]
  lines : Array[Double]
}

///|
/// Prepare a granule for repeated quantisation.
pub fn GranuleQuantiser::new(lines : Array[Double]) -> GranuleQuantiser {
  let powers = Array::make(lines.length(), 0.0)
  for index = 0; index < lines.length(); index = index + 1 {
    powers[index] = @math.pow(lines[index].abs(), 0.75)
  }
  GranuleQuantiser::{ powers, lines, }
}

///|
/// Quantise with `gain`, using the same arithmetic as `quantize_with_gain`.
pub fn GranuleQuantiser::quantise(
  self : GranuleQuantiser,
  gain : Int32,
) -> Array[Int32] {
  let amplitude = @math.pow(2.0, (gain.to_double() - 210.0) / 4.0)
  let scale = 1.0 / @math.pow(amplitude, 0.75)
  let values = Array::make(self.powers.length(), 0)
  for index = 0; index < self.powers.length(); index = index + 1 {
    let level = (self.powers[index] * scale + QuantizeOffset).floor().to_int()
    if level > 0 {
      let clamped = if level > MaxQuantLevel { MaxQuantLevel } else { level }
      values[index] = if self.lines[index] < 0.0 { -clamped } else { clamped }
    }
  }
  values
}

///|
/// Squared reconstruction error of `values`: the sum over the lines of
/// `(sign(is) |is|^(4/3) 2^((gain-210)/4) - xr)^2`.
///
/// The sign matters twice: the decoder requantises `sign(is) * |is|^(4/3) * ...`,
/// so a coefficient's reconstruction is only comparable with the line it came
/// from once the sign is back on it. Without that, a granule whose coefficients
/// alternate sign scores an error larger than its own energy at *every* gain, and
/// the search that minimises this number picks essentially arbitrary gains — the
/// 2026-11-02 build wrote gains up to 7 steps coarser than the peak-matching one
/// for a steady tone and lost about 3.5 dB of end-to-end SNR to it.
pub fn GranuleQuantiser::error(
  self : GranuleQuantiser,
  values : Array[Int32],
  gain : Int32,
) -> Double {
  let amplitude = @math.pow(2.0, (gain.to_double() - 210.0) / 4.0)
  let mut total = 0.0
  for index = 0; index < values.length(); index = index + 1 {
    let level = values[index].abs()
    let magnitude = dequant_levels[level] * amplitude
    let reconstructed = if values[index] < 0 { -magnitude } else { magnitude }
    let difference = reconstructed - self.lines[index]
    total = total + difference * difference
  }
  total
}
