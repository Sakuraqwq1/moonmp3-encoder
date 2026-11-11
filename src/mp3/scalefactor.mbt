// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Scalefactor bands and their transmission, ISO/IEC 11172-3 §2.4.2.7 and
// Table B.8.
//
// A long block at 44.1 kHz partitions the 576 frequency lines into 22 bands,
// but only the first 21 carry a scalefactor. The last band (lines 418..575)
// has no transmitted scalefactor, so its only step control is `global_gain`.
// The 21 values are split into two groups: sfb 0..10 use `slen1` bits each and
// sfb 11..20 use `slen2` bits each, with the pair selected by the four-bit
// `scalefac_compress` field (Table B.8 / 3-B.32).
//
// Each scalefactor is an attenuation, not an amplification: the decoder
// multiplies the requantised line by
//
//   2^(-(1 + scalefac_scale) / 2 * scalefac)
//
// so a larger value means a coarser step for that band. The encoder therefore
// quantises a band as if its `global_gain` were lowered by
// `4 * (1 + scalefac_scale) / 2 * scalefac` steps.

///|
/// Number of long-block scalefactor bands that carry a transmitted
/// scalefactor at 44.1 kHz: sfb 0..20. Band 21 exists as a frequency partition
/// but has no scalefactor field in the bitstream.
pub const LongScalefactorBandCount : Int32 = 21

///|
/// Number of actual frequency partitions in a long block, including the
/// unscaled band 21.
pub const LongFrequencyBandCount : Int32 = 22

///|
/// Start line of each transmitted scalefactor band, ISO/IEC 11172-3
/// Table B.8.a (32 kHz). Widths: 4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20,
/// 24, 30, 38, 46, 56, 68, 84, 102.
/// Transmitted bands sfb 0..20 end at 550; the unscaled band 21 covers 550..575 (width 26).
let long_scalefactor_starts_32k : Array[Int32] = [
  0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296,
  364, 448,
]

///|
/// Start line of each transmitted scalefactor band, ISO/IEC 11172-3
/// Table B.8.b (44.1 kHz). Widths: 4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16,
/// 20, 24, 28, 34, 42, 50, 54, 76.
/// Transmitted bands sfb 0..20 end at 418; the unscaled band 21 covers 418..575 (width 158).
let long_scalefactor_starts_44k : Array[Int32] = [
  0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288,
  342,
]

///|
/// Start line of each transmitted scalefactor band, ISO/IEC 11172-3
/// Table B.8.c (48 kHz). Widths: 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16,
/// 18, 22, 28, 34, 40, 46, 54, 54.
/// Transmitted bands sfb 0..20 end at 384; the unscaled band 21 covers 384..575 (width 192).
let long_scalefactor_starts_48k : Array[Int32] = [
  0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276,
  330,
]

///|
/// Active sample rate tracker for band-table selection during encoding.
let active_rate : Ref[Int32] = { val: 44100, }

///|
/// Set the active sample rate used by scalefactor band queries.
pub fn set_active_samplerate(rate : Int32) -> Unit {
  active_rate.val = rate
}

///|
/// Get the active sample rate used by scalefactor band queries.
pub fn get_active_samplerate() -> Int32 {
  active_rate.val
}

///|
/// Band starts and unscaled tail boundary for a given sample rate.
fn long_scalefactor_partition_for(rate : Int32) -> (Array[Int32], Int32) {
  if rate == SampleRate32000 {
    (long_scalefactor_starts_32k, 550)
  } else if rate == SampleRate48000 {
    (long_scalefactor_starts_48k, 384)
  } else {
    (long_scalefactor_starts_44k, 418)
  }
}

///|
/// Short-window scalefactor bands transmitted per granule: 12 bands, each with
/// three window values.
pub const ShortScalefactorCount : Int32 = 36

///|
/// Number of short frequency partitions including the unscaled 136..191 tail.
pub const ShortFrequencyBandCount : Int32 = 37

///|
/// Start frequency of each 44.1 kHz short-window band within one 192-line
/// window, plus the 192-line sentinel. Bands 0..11 carry scalefactors; band 12
/// is the unscaled tail.
let short_scalefactor_starts : Array[Int32] = [
  0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192,
]

///|
/// Short band of one frequency within a 192-line window, 0..12.
pub fn short_scalefactor_band_of_frequency(frequency : Int32) -> Int32 {
  if frequency < 0 {
    return 0
  }
  if frequency >= 136 {
    return 12
  }
  for band = 1; band < 13; band = band + 1 {
    if frequency < short_scalefactor_starts[band] {
      return band - 1
    }
  }
  12
}

///|
/// Start of a short scalefactor partition in one 192-line window.
pub fn short_scalefactor_band_start(band : Int32) -> Int32 {
  if band <= 0 {
    0
  } else if band < 13 {
    short_scalefactor_starts[band]
  } else {
    192
  }
}

///|
/// End of a short scalefactor partition in one 192-line window.
pub fn short_scalefactor_band_end(band : Int32) -> Int32 {
  short_scalefactor_band_start(band + 1)
}

///|
/// Width of a short scalefactor partition.
pub fn short_scalefactor_band_width(band : Int32) -> Int32 {
  short_scalefactor_band_end(band) - short_scalefactor_band_start(band)
}

///|
/// Index in the Huffman coefficient stream for a native short-block
/// coefficient `(subband, window, line)`.
///
/// The bitstream orders short coefficients as `[sfb][window][line]`, whereas
/// analysis naturally produces `[subband][window][line]`. `sfb` is found in the
/// 192-line per-window frequency domain; its start frequency occupies three
/// consecutive window sections in the 576-line Huffman stream.
pub fn short_huffman_index(
  subband : Int32,
  window : Int32,
  line : Int32,
) -> Int32 {
  let frequency = subband * 6 + line
  let band = short_scalefactor_band_of_frequency(frequency)
  let width = short_scalefactor_band_width(band)
  short_scalefactor_band_start(band) * 3 +
  window * width +
  (frequency - short_scalefactor_band_start(band))
}

///|
/// 36-entry vector of zero short-block scalefactors.
pub fn zero_short_scalefactors() -> Array[Int32] {
  Array::make(ShortScalefactorCount, 0)
}

///|
/// Independent copy of a 36-entry short-block vector.
pub fn copy_short_scalefactors(scalefactors : Array[Int32]) -> Array[Int32] {
  let out = Array::make(ShortScalefactorCount, 0)
  for index = 0
      index < ShortScalefactorCount && index < scalefactors.length()
      index = index + 1 {
    out[index] = scalefactors[index]
  }
  out
}

///|
/// Scalefactor field index for a line already in short-block Huffman order:
/// 3*sfb + window. The sfb12 tail has no scalefactor and maps to the sentinel
/// `ShortScalefactorCount` (36), which callers treat as a fixed zero.
pub fn short_scalefactor_of_line(line : Int32) -> Int32 {
  if line < 0 {
    return 0
  }
  for band = 0; band < 12; band = band + 1 {
    let width = short_scalefactor_band_width(band)
    let start = short_scalefactor_band_start(band) * 3
    let stop = start + width * 3
    if line < stop {
      return band * 3 + (line - start) / width
    }
  }
  ShortScalefactorCount
}

///|
/// Bits spent on the 36 short-block scalefactors for `compress`.
pub fn short_scalefactor_bit_count(compress : Int32) -> Int32 {
  let (slen1, slen2) = scalefactor_widths(compress)
  18 * (slen1 + slen2)
}

///|
/// Maximum values in the two short groups, each `sfb × window`.
pub fn short_scalefactor_group_maxima(
  scalefactors : Array[Int32],
) -> (Int32, Int32) {
  let mut max1 = 0
  let mut max2 = 0
  for index = 0; index < 18 && index < scalefactors.length(); index = index + 1 {
    if scalefactors[index] > max1 {
      max1 = scalefactors[index]
    }
  }
  for index = 18; index < 36 && index < scalefactors.length(); index = index + 1 {
    if scalefactors[index] > max2 {
      max2 = scalefactors[index]
    }
  }
  (max1, max2)
}

///|
/// `scalefac_compress` that covers a 36-value short-block vector, priced at
/// 18 values in each slen group.
pub fn short_scalefactor_compress(scalefactors : Array[Int32]) -> Int32 {
  let (max1, max2) = short_scalefactor_group_maxima(scalefactors)
  if max1 > 15 || max2 > 7 {
    return -1
  }
  let mut best = -1
  let mut best_bits = 0x7fffffff
  for compress = 0; compress < 16; compress = compress + 1 {
    let (slen1, slen2) = scalefactor_widths(compress)
    let capacity1 = (1 << slen1) - 1
    let capacity2 = (1 << slen2) - 1
    if capacity1 < max1 || capacity2 < max2 {
      continue
    }
    let bits = short_scalefactor_bit_count(compress)
    if bits < best_bits {
      best = compress
      best_bits = bits
    }
  }
  best
}

///|
/// Write the 36 short-block scalefactors as `sfb 0..5 × window 0..2` with
/// slen1, then `sfb 6..11 × window 0..2` with slen2.
pub fn write_short_scalefactors(
  w : @bits.BitWriter,
  scalefactors : Array[Int32],
  compress : Int32,
) -> Int32 {
  let (slen1, slen2) = scalefactor_widths(compress)
  for band = 0; band < 6; band = band + 1 {
    for window = 0; window < 3; window = window + 1 {
      let index = band * 3 + window
      if slen1 > 0 {
        w.write_bits(scalefactors[index].to_int64(), slen1)
      }
    }
  }
  for band = 6; band < 12; band = band + 1 {
    for window = 0; window < 3; window = window + 1 {
      let index = band * 3 + window
      if slen2 > 0 {
        w.write_bits(scalefactors[index].to_int64(), slen2)
      }
    }
  }
  18 * (slen1 + slen2)
}

///|
/// `slen1` for every `scalefac_compress` value, ISO/IEC 11172-3 Table B.8.
let slen1_table : Array[Int32] = [
  0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4,
]

///|
/// `slen2` for every `scalefac_compress` value.
let slen2_table : Array[Int32] = [
  0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3,
]

///|
/// Number of transmitted scalefactors in the `slen1` group (sfb 0..10).
pub const ScalefactorsInGroup1 : Int32 = 11

///|
/// Number of transmitted scalefactors in the `slen2` group (sfb 11..20).
pub const ScalefactorsInGroup2 : Int32 = 10

///|
/// `(slen1, slen2)` selected by a four-bit `scalefac_compress`.
pub fn scalefactor_widths(compress : Int32) -> (Int32, Int32) {
  if compress < 0 || compress > 15 {
    return (0, 0)
  }
  (slen1_table[compress], slen2_table[compress])
}

///|
/// Bits spent on the 21 scalefactors for a given `scalefac_compress`.
pub fn scalefactor_bit_count(compress : Int32) -> Int32 {
  let (slen1, slen2) = scalefactor_widths(compress)
  ScalefactorsInGroup1 * slen1 + ScalefactorsInGroup2 * slen2
}

///|
/// Smallest `scalefac_compress` that can transmit maxima `max1` and `max2`.
///
/// The table is not monotone in total width (compress 4 spends 33 bits where
/// compress 3 spends 30, and compress 5 spends 21), so every entry is priced
/// instead of walking a ramp. Ties go to the lower value, which keeps the
/// bitstream deterministic. Returns -1 when a value needs more than four bits.
pub fn scalefactor_compress_for(max1 : Int32, max2 : Int32) -> Int32 {
  if max1 < 0 || max2 < 0 || max1 > 15 || max2 > 15 {
    return -1
  }
  let mut best = -1
  let mut best_bits = 0x7fffffff
  for compress = 0; compress < 16; compress = compress + 1 {
    let (slen1, slen2) = scalefactor_widths(compress)
    // A field of `slen` bits holds values 0 .. 2^slen - 1, not 0 .. slen.
    let capacity1 = (1 << slen1) - 1
    let capacity2 = (1 << slen2) - 1
    if capacity1 < max1 || capacity2 < max2 {
      continue
    }
    let bits = scalefactor_bit_count(compress)
    if bits < best_bits {
      best = compress
      best_bits = bits
    }
  }
  best
}

///|
/// Maximum scalefactor in each transmission group, for a 21-value vector.
pub fn scalefactor_group_maxima(scalefactors : Array[Int32]) -> (Int32, Int32) {
  let mut max1 = 0
  let mut max2 = 0
  for band = 0
      band < ScalefactorsInGroup1 && band < scalefactors.length()
      band = band + 1 {
    if scalefactors[band] > max1 {
      max1 = scalefactors[band]
    }
  }
  for band = ScalefactorsInGroup1
      band < LongScalefactorBandCount && band < scalefactors.length()
      band = band + 1 {
    if scalefactors[band] > max2 {
      max2 = scalefactors[band]
    }
  }
  (max1, max2)
}

///|
/// The `scalefac_compress` that exactly covers a 21-value vector.
pub fn scalefactor_compress(scalefactors : Array[Int32]) -> Int32 {
  let (max1, max2) = scalefactor_group_maxima(scalefactors)
  scalefactor_compress_for(max1, max2)
}

///|
/// Start line of a transmitted scalefactor band, 0..20.
pub fn scalefactor_band_start(
  band : Int32,
  rate~ : Int32 = active_rate.val,
) -> Int32 {
  if band <= 0 {
    0
  } else {
    let (starts, tail_start) = long_scalefactor_partition_for(rate)
    if band < LongScalefactorBandCount {
      starts[band]
    } else if band == LongScalefactorBandCount {
      tail_start
    } else {
      576
    }
  }
}

///|
/// End line (exclusive) of a frequency partition, 0..21.
pub fn scalefactor_band_end(
  band : Int32,
  rate~ : Int32 = active_rate.val,
) -> Int32 {
  if band < 0 {
    0
  } else {
    let (starts, tail_start) = long_scalefactor_partition_for(rate)
    if band < LongScalefactorBandCount - 1 {
      starts[band + 1]
    } else if band == LongScalefactorBandCount - 1 {
      tail_start
    } else {
      576
    }
  }
}

///|
/// Width of a frequency partition, 0..21.
pub fn scalefactor_band_width(
  band : Int32,
  rate~ : Int32 = active_rate.val,
) -> Int32 {
  scalefactor_band_end(band, rate~) - scalefactor_band_start(band, rate~)
}

///|
/// Frequency partition that owns a line, 0..21. Band 21 has no transmitted
/// scalefactor but is still a distinct partition for error accounting.
pub fn scalefactor_band_of_line(
  line : Int32,
  rate~ : Int32 = active_rate.val,
) -> Int32 {
  if line < 0 {
    return 0
  }
  let (starts, tail_start) = long_scalefactor_partition_for(rate)
  if line >= tail_start {
    return 21
  }
  for band = 1; band < LongScalefactorBandCount; band = band + 1 {
    if line < starts[band] {
      return band - 1
    }
  }
  20
}

///|
/// Step-size multiplier selected by `scalefac_scale`: 0.5 (0.5 dB per
/// scalefactor step) when the bit is zero and 1.0 (1 dB per step) when it is
/// one. The decoder applies `2^(-multiplier * scalefactor)`.
pub fn scalefactor_step_multiplier(scalefac_scale : Int32) -> Double {
  if scalefac_scale == 0 {
    0.5
  } else {
    1.0
  }
}

///|
/// A 21-entry vector of zero scalefactors.
pub fn zero_scalefactors() -> Array[Int32] {
  Array::make(LongScalefactorBandCount, 0)
}

///|
/// Independent copy, because a plan must not be mutated after it is recorded.
pub fn copy_scalefactors(scalefactors : Array[Int32]) -> Array[Int32] {
  let out = Array::make(LongScalefactorBandCount, 0)
  for band = 0
      band < LongScalefactorBandCount && band < scalefactors.length()
      band = band + 1 {
    out[band] = scalefactors[band]
  }
  out
}

///|
/// Write the 21 scalefactors for one granule/channel, in sfb order:
/// sfb 0..10 with slen1 bits, then sfb 11..20 with slen2 bits.
///
/// Returns the exact number of bits written. The caller must have chosen
/// `compress` with `scalefactor_compress`, so every value fits its field.
pub fn write_scalefactors(
  w : @bits.BitWriter,
  scalefactors : Array[Int32],
  compress : Int32,
) -> Int32 {
  let (slen1, slen2) = scalefactor_widths(compress)
  for band = 0; band < ScalefactorsInGroup1; band = band + 1 {
    let value = if band < scalefactors.length() {
      scalefactors[band]
    } else {
      0
    }
    if slen1 > 0 {
      w.write_bits(value.to_int64(), slen1)
    }
  }
  for band = ScalefactorsInGroup1
      band < LongScalefactorBandCount
      band = band + 1 {
    let value = if band < scalefactors.length() {
      scalefactors[band]
    } else {
      0
    }
    if slen2 > 0 {
      w.write_bits(value.to_int64(), slen2)
    }
  }
  ScalefactorsInGroup1 * slen1 + ScalefactorsInGroup2 * slen2
}
