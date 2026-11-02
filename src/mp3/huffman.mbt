// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The big_values Huffman region of ISO/IEC 11172-3 §2.4.2.7.
//
// A granule's 576 quantised coefficients are laid out as
//
//   [0, 2 * big_values)          pairs (x, y), one table per region
//   [2 * big_values, 576)        the count1 region, values in -1/0/1
//
// MPEG-1 `table_select` is a four-bit field, so only tables 0..15 are reachable,
// and none of them has an escape (linbits are zero for every MPEG-1 table — the
// tables that use escapes are MPEG-2's 16..31, which this field cannot select).
// The practical consequence shapes the quantiser: a coefficient must never
// exceed the chosen table's extent, and the largest extent available is 15.
//
// Tables 1..3 only reach 1 or 2, tables 5..6 reach 3, 7..9 reach 5, 10..12 reach
// 7 and 13/15 reach 15, so the pair magnitudes decide which tables are legal.

///|
/// Failures of the big_values writer.
pub suberror HuffmanError {
  /// A coefficient does not fit the selected table.
  Unrepresentable(Int32)
  /// The pair index is outside the granule.
  BadRegion(Int32)
}

///|
/// Number of symbols each table stores, and the stride of `huffman_codes`.
pub const HuffmanSymbols : Int32 = 256

///|
/// `(length << 16) | code` for a pair, or zero when the table cannot express it.
fn huffman_entry(table : Int32, x : Int32, y : Int32) -> Int32 {
  if table < 1 || table > 15 || x < 0 || x > 15 || y < 0 || y > 15 {
    return 0
  }
  huffman_codes[table * HuffmanSymbols + x * 16 + y]
}

///|
/// Largest coefficient `table` can represent (0 for the empty tables).
pub fn table_extent(table : Int32) -> Int32 {
  if table < 0 || table > 15 {
    return 0
  }
  huffman_table_extent[table]
}

///|
/// Extra bits a table appends when a coefficient reaches 15. Always zero for
/// MPEG-1 tables; kept explicit so the writer cannot silently assume it.
pub fn table_linbits(table : Int32) -> Int32 {
  if table < 0 || table > 15 {
    return 0
  }
  huffman_linbits[table]
}

///|
/// Bits a pair costs in `table`, or -1 when the pair is not representable.
pub fn pair_cost(table : Int32, x : Int32, y : Int32) -> Int32 {
  let entry = huffman_entry(table, x.abs(), y.abs())
  if entry == 0 {
    return -1
  }
  let length = entry >> 16
  let mut cost = length
  let linbits = table_linbits(table)
  if linbits != 0 {
    if x.abs() == 15 {
      cost = cost + linbits
    }
    if y.abs() == 15 {
      cost = cost + linbits
    }
  }
  if x != 0 {
    cost = cost + 1
  }
  if y != 0 {
    cost = cost + 1
  }
  cost
}

///|
/// Write one pair, returning the number of bits written (including the two sign
/// bits). Sign is one bit per non-zero coefficient, and one means negative.
pub fn write_pair(
  w : @bits.BitWriter,
  table : Int32,
  x : Int32,
  y : Int32,
) -> Int32 raise HuffmanError {
  let entry = huffman_entry(table, x.abs(), y.abs())
  if entry == 0 {
    raise Unrepresentable(x * 16 + y)
  }
  let length = entry >> 16
  let code = entry & 0xFFFF
  w.write_bits(code.to_int64(), length)
  let mut bits = length
  let linbits = table_linbits(table)
  if linbits != 0 {
    if x.abs() == 15 {
      w.write_bits(0L, linbits)
      bits = bits + linbits
    }
    if y.abs() == 15 {
      w.write_bits(0L, linbits)
      bits = bits + linbits
    }
  }
  if x != 0 {
    w.write_bit(if x < 0 { 1 } else { 0 })
    bits = bits + 1
  }
  if y != 0 {
    w.write_bit(if y < 0 { 1 } else { 0 })
    bits = bits + 1
  }
  bits
}

///|
/// Number of pairs a granule must code as big_values.
///
/// The count1 region may only carry -1/0/1, so big_values has to cover every
/// coefficient whose magnitude is 2 or more. Coefficients of +-1 beyond that
/// point are cheaper in count1 (four mask bits for four values) than as pairs
/// (at least two bits each plus signs), so the boundary stops at the last
/// "big" coefficient instead of the last non-zero one.
pub fn big_values_needed(values : Array[Int32]) -> Int32 {
  let mut last = 0
  for index = 0; index < values.length(); index = index + 1 {
    let magnitude = if values[index] < 0 {
      -values[index]
    } else {
      values[index]
    }
    if magnitude > 1 {
      last = index + 1
    }
  }
  let pairs = (last + 1) / 2
  (pairs + 1) / 2 * 2
}

///|
/// Largest magnitude in `[start, stop)`.
pub fn region_peak(values : Array[Int32], start : Int32, stop : Int32) -> Int32 {
  let mut peak = 0
  for index = start; index < stop && index < values.length(); index = index + 1 {
    let magnitude = if values[index] < 0 {
      -values[index]
    } else {
      values[index]
    }
    if magnitude > peak {
      peak = magnitude
    }
  }
  peak
}

///|
/// Bits needed to code `[0, 2 * big_values)` with `table`.
pub fn big_values_cost(
  values : Array[Int32],
  table : Int32,
  big_values : Int32,
) -> Int32 {
  let mut bits = 0
  let mut pair = 0
  while pair < big_values {
    let x = values[pair * 2]
    let y = values[pair * 2 + 1]
    let cost = pair_cost(table, x, y)
    if cost < 0 {
      return -1
    }
    bits = bits + cost
    pair = pair + 1
  }
  bits
}

///|
/// Cheapest legal table for the pairs in `[0, 2 * big_values)`.
///
/// Ties go to the lower table number so the choice is deterministic. Returns 0
/// when there is nothing to code and -1 when no table can express the values.
pub fn choose_table(values : Array[Int32], big_values : Int32) -> Int32 {
  if big_values == 0 {
    return 0
  }
  let peak = region_peak(values, 0, big_values * 2)
  let mut best = -1
  let mut best_cost = -1
  for table = 1; table <= 15; table = table + 1 {
    if table_extent(table) < peak {
      continue
    }
    let cost = big_values_cost(values, table, big_values)
    if cost < 0 {
      continue
    }
    if best_cost < 0 || cost < best_cost {
      best = table
      best_cost = cost
    }
  }
  best
}

///|
/// Exact bits for one granule: big_values pairs, then the count1 tail.
pub fn granule_cost(
  values : Array[Int32],
  table : Int32,
  big_values : Int32,
) -> Int32 {
  let head = big_values_cost(values, table, big_values)
  if head < 0 {
    return -1
  }
  let tail_start = big_values * 2
  let mut cost = head + (576 - tail_start)
  for index = tail_start; index < values.length(); index = index + 1 {
    if values[index] != 0 {
      cost = cost + 1
    }
  }
  cost
}

///|
/// Side information for one granule coded with a big_values region.
///
/// The same table is written to all three `table_select` fields: the region
/// boundaries are then irrelevant to the decoder, which keeps the encoder from
/// depending on the scalefactor band table until stage 1's scalefactor work
/// lands. `region0_count` and `region1_count` are written as zero, which is
/// legal and leaves the whole pair list on `table_select0` where it fits.
pub fn GranuleInfo::big_values(
  part2_3_length : Int32,
  big_values : Int32,
  global_gain : Int32,
  table : Int32,
) -> GranuleInfo {
  GranuleInfo::scaled(part2_3_length, big_values, global_gain, table, 0)
}

///|
/// Side information for one granule whose main data starts with scalefactors.
///
/// `scalefac_compress` selects the `slen1`/`slen2` widths of the 21
/// scalefactors; zero means no scalefactor bits. The Huffman tables remain the
/// same in all three regions, so `region0_count` and `region1_count` stay zero
/// and the decoder simply keeps the single selected table across the pair list.
pub fn GranuleInfo::scaled(
  part2_3_length : Int32,
  big_values : Int32,
  global_gain : Int32,
  table : Int32,
  scalefac_compress : Int32,
) -> GranuleInfo {
  {
    part2_3_length,
    big_values,
    global_gain,
    scalefac_compress,
    window_switching_flag: 0,
    block_type: 0,
    mixed_block_flag: 0,
    table_select0: table,
    table_select1: table,
    table_select2: table,
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

///|
/// Side information for one short-window granule.
///
/// A pure short block transmits no region boundaries: the switched-window
/// side-info form carries `table_select0`, `table_select2` and three subblock
/// gains instead. The encoder still uses one table across the whole pair list,
/// so both selects are the same and the gains are zero.
pub fn GranuleInfo::short(
  part2_3_length : Int32,
  big_values : Int32,
  global_gain : Int32,
  table : Int32,
  scalefac_compress : Int32,
) -> GranuleInfo {
  {
    part2_3_length,
    big_values,
    global_gain,
    scalefac_compress,
    window_switching_flag: 1,
    block_type: 2,
    mixed_block_flag: 0,
    table_select0: table,
    table_select1: table,
    table_select2: table,
    subblock_gain0: 0,
    subblock_gain1: 0,
    subblock_gain2: 0,
    region0_count: 8,
    region1_count: 63,
    preflag: 0,
    scalefac_scale: 0,
    count1table_select: 1,
  }
}

///|
/// Side information for a start or stop granule. These are long-block
/// coefficient layouts under a switching window, so they keep the long
/// scalefactor transmission but set `window_switching_flag` and `block_type`.
pub fn GranuleInfo::switched_long(
  part2_3_length : Int32,
  big_values : Int32,
  global_gain : Int32,
  table : Int32,
  scalefac_compress : Int32,
  block_type : Int32,
) -> GranuleInfo {
  {
    part2_3_length,
    big_values,
    global_gain,
    scalefac_compress,
    window_switching_flag: 1,
    block_type,
    mixed_block_flag: 0,
    table_select0: table,
    table_select1: table,
    table_select2: table,
    subblock_gain0: 0,
    subblock_gain1: 0,
    subblock_gain2: 0,
    region0_count: 7,
    region1_count: 63,
    preflag: 0,
    scalefac_scale: 0,
    count1table_select: 1,
  }
}

///|
/// Write a full granule's Huffman data, returning the exact bit count.
pub fn write_granule(
  w : @bits.BitWriter,
  values : Array[Int32],
  table : Int32,
  big_values : Int32,
) -> Int32 raise HuffmanError {
  if values.length() != 576 {
    raise BadRegion(values.length())
  }
  if big_values * 2 > 576 || big_values * 2 % 4 != 0 {
    // The count1 region is coded in quads, so it has to start on a multiple of
    // four; callers use `big_values_needed`, which always returns an even pair
    // count.
    raise BadRegion(big_values)
  }
  let mut bits = 0
  for pair = 0; pair < big_values; pair = pair + 1 {
    bits = bits + write_pair(w, table, values[pair * 2], values[pair * 2 + 1])
  }
  let tail_start = big_values * 2
  if tail_start >= 576 {
    // A granule can spend its whole length in big_values; there is then no
    // count1 region at all, and the writer must not be called with nothing.
    return bits
  }
  let tail = Array::make(576 - tail_start, 0)
  for index = tail_start; index < 576; index = index + 1 {
    tail[index - tail_start] = values[index]
  }
  let tail_bits = write_count1(w, tail) catch {
    (_ : Count1Error) => raise BadRegion(tail_start)
  }
  bits + tail_bits
}
