// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Count1-region Huffman coding, table B. ISO/IEC 11172-3 Table B.7:
// each four coefficients are represented by a four-bit mask of the non-zero
// positions, followed by one sign bit per non-zero coefficient. The codeword
// is the bitwise complement of that mask. Values are restricted to -1/0/1.
//
// This deliberately small subset is the first vertical slice of the encoder.
// It lets the bitstream and frame assembly be verified independently of the
// analysis filterbank and the larger big-values Huffman tables.

///|
/// Errors reported by the count1 writer and its fixed-spectrum test encoder.
pub suberror Count1Error {
  BadLength(Int32)
  BadValue(Int32)
  BadChannels(Int32)
  BadFrames(Int32)
  BadGain(Int32)
  FrameOverflow(Int32)
}

///|
/// Number of bits needed for a count1-region sequence.
///
/// Every group of four coefficients costs four bits for its mask, plus one
/// sign bit for each non-zero coefficient. The length must be a non-zero
/// multiple of four and every value must be -1, 0 or 1.
pub fn count1_bits(values : Array[Int32]) -> Int32 raise Count1Error {
  if values.length() == 0 || values.length() % 4 != 0 {
    raise BadLength(values.length())
  }
  let mut bits = values.length()
  for value in values {
    if value < -1 || value > 1 {
      raise BadValue(value)
    }
    if value != 0 {
      bits = bits + 1
    }
  }
  bits
}

///|
/// Write a count1-region sequence using Huffman table B.
///
/// The return value is the exact number of bits written and is suitable for
/// `part2_3_length` when no scalefactors are transmitted.
pub fn write_count1(
  w : @bits.BitWriter,
  values : Array[Int32],
) -> Int32 raise Count1Error {
  let bits = count1_bits(values)
  for base = 0; base < values.length(); base = base + 4 {
    let mut mask = 0
    for offset = 0; offset < 4; offset = offset + 1 {
      if values[base + offset] != 0 {
        mask = mask | (1 << (3 - offset))
      }
    }
    w.write_bits((15 - mask).to_int64(), 4)
    for offset = 0; offset < 4; offset = offset + 1 {
      let value = values[base + offset]
      if value != 0 {
        w.write_bit(if value < 0 { 1 } else { 0 })
      }
    }
  }
  bits
}

///|
/// Side information for one count1-only granule with no scalefactor bytes.
pub fn GranuleInfo::count1(
  part2_3_length : Int32,
  global_gain : Int32,
) -> GranuleInfo {
  {
    part2_3_length,
    big_values: 0,
    global_gain,
    scalefac_compress: 0,
    window_switching_flag: 0,
    block_type: 0,
    mixed_block_flag: 0,
    table_select0: 0,
    table_select1: 0,
    table_select2: 0,
    subblock_gain0: 0,
    subblock_gain1: 0,
    subblock_gain2: 0,
    region0_count: 0,
    region1_count: 0,
    preflag: 0,
    scalefac_scale: 0,
    count1table_select: 1,
  }
}
