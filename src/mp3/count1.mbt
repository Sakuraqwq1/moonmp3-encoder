// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Count1-region Huffman coding, table A. ISO/IEC 11172-3 Table B.7:
// each four coefficients are represented by the codeword for their non-zero
// mask, followed by one sign bit per non-zero coefficient. Values are
// restricted to -1/0/1. After the last non-zero quadruple, table A's one-bit
// all-zero code terminates the tail; the remaining zero quadruples cost nothing.

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
/// Validate a count1 region and return the end of its last non-zero quadruple.
fn count1_last_end(values : Array[Int32]) -> Int32 raise Count1Error {
  if values.length() == 0 || values.length() % 4 != 0 {
    raise BadLength(values.length())
  }
  let mut last = 0
  for base = 0; base < values.length(); base = base + 4 {
    let mut nonzero = false
    for offset = 0; offset < 4; offset = offset + 1 {
      let value = values[base + offset]
      if value < -1 || value > 1 {
        raise BadValue(value)
      }
      if value != 0 {
        nonzero = true
      }
    }
    if nonzero {
      last = base + 4
    }
  }
  last
}

///|
/// Non-zero mask for one already-validated quadruple.
fn count1_mask(values : Array[Int32], base : Int32) -> Int32 {
  let mut mask = 0
  for offset = 0; offset < 4; offset = offset + 1 {
    if values[base + offset] != 0 {
      mask = mask | (1 << (3 - offset))
    }
  }
  mask
}

///|
/// Number of bits needed for a count1-region sequence.
///
/// Every quadruple through the last non-zero one pays its table-A code and sign
/// bits. One final all-zero code then terminates the tail. The length must be a
/// non-zero multiple of four and every value must be -1, 0 or 1.
pub fn count1_bits(values : Array[Int32]) -> Int32 raise Count1Error {
  let last = count1_last_end(values)
  let mut bits = 1
  for base = 0; base < last; base = base + 4 {
    let entry = count1_table_a[count1_mask(values, base)]
    bits = bits + (entry >> 16)
    for offset = 0; offset < 4; offset = offset + 1 {
      if values[base + offset] != 0 {
        bits = bits + 1
      }
    }
  }
  bits
}

///|
/// Write a count1-region sequence using Huffman table A and early termination.
///
/// The return value is the exact number of bits written and is suitable for
/// `part2_3_length` when no scalefactors are transmitted.
pub fn write_count1(
  w : @bits.BitWriter,
  values : Array[Int32],
) -> Int32 raise Count1Error {
  let last = count1_last_end(values)
  let mut bits = 0
  for base = 0; base < last; base = base + 4 {
    let entry = count1_table_a[count1_mask(values, base)]
    let length = entry >> 16
    w.write_bits((entry & 0xFFFF).to_int64(), length)
    bits = bits + length
    for offset = 0; offset < 4; offset = offset + 1 {
      let value = values[base + offset]
      if value != 0 {
        w.write_bit(if value < 0 { 1 } else { 0 })
        bits = bits + 1
      }
    }
  }
  let terminator = count1_table_a[0]
  let length = terminator >> 16
  w.write_bits((terminator & 0xFFFF).to_int64(), length)
  bits + length
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
    count1table_select: 0,
  }
}
