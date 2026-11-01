// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Layer III side information: the per-grule header that tells the decoder how
// the frame's main data is laid out. ISO/IEC 11172-3 §3-Annex B, Table B-8
// (the MPEG-1 audio_data layout). Side info is 17 bytes in mono and 32 bytes
// otherwise; the frame's main data follows immediately after it.

///|
/// Layer III side information for one granule of one channel.
pub(all) struct GranuleInfo {
  /// Length in bits of the scalefactor (part 2) plus Huffman (part 3) data.
  part2_3_length : Int32
  /// Number of Huffman code pairs in the "big values" region, times two.
  big_values : Int32
  /// Quantiser step size, in steps of 0.25 dB.
  global_gain : Int32
  /// Which scalefactor bands are coded, and with what precision.
  scalefac_compress : Int32
  /// 1 when the granule uses window switching (short or mixed blocks).
  window_switching_flag : Int32
  /// 0 long, 1 start, 3 short (2 is reserved); only with window switching.
  block_type : Int32
  /// Long-block scalefactor bands below the switched window region.
  mixed_block_flag : Int32
  /// Huffman table for region 0.
  table_select0 : Int32
  /// Huffman table for region 1.
  table_select1 : Int32
  /// Huffman table for region 2 (or the second short-block region).
  table_select2 : Int32
  /// Gain offset for short-block subblock 0.
  subblock_gain0 : Int32
  /// Gain offset for short-block subblock 1.
  subblock_gain1 : Int32
  /// Gain offset for short-block subblock 2.
  subblock_gain2 : Int32
  /// One less than the number of scalefactor bands in region 0.
  region0_count : Int32
  /// One less than the number of scalefactor bands in region 1.
  region1_count : Int32
  /// High-frequency amplification of scalefactors (MPEG-1 only).
  preflag : Int32
  /// Scalefactor step size: 0 short (0.5 dB), 1 long (1.0 dB).
  scalefac_scale : Int32
  /// Huffman table for the count1 region: 0 selects table A.
  count1table_select : Int32
}

///| Side information that decodes to digital silence: no scalefactors, no

///|
/// Huffman data, no big values. A frame made of this plus an empty reservoir
/// carries 1152 zero samples and still parses everywhere.
pub fn GranuleInfo::silent() -> GranuleInfo {
  {
    part2_3_length: 0,
    big_values: 0,
    global_gain: 0,
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

///|
/// Write the side information of one frame.
///
/// `scfsi` holds one 4-bit scalefactor selector per channel and `granules`
/// holds `2 * channels` entries ordered granule-major: index
/// `granule * channels + channel`. The writer ends byte aligned, which the
/// spec guarantees because the field total is 136 bits in mono and 256 bits
/// otherwise.
pub fn write_side_info(
  w : @bits.BitWriter,
  channels : Int32,
  main_data_begin : Int32,
  scfsi : Array[Int32],
  granules : Array[GranuleInfo],
) -> Unit {
  w.write_bits(main_data_begin.to_int64(), 9)
  w.write_bits(0L, if channels == 1 { 5 } else { 3 })
  for ch = 0; ch < channels; ch = ch + 1 {
    w.write_bits(scfsi[ch].to_int64(), 4)
  }
  for gr = 0; gr < 2; gr = gr + 1 {
    for ch = 0; ch < channels; ch = ch + 1 {
      let g = granules[gr * channels + ch]
      w.write_bits(g.part2_3_length.to_int64(), 12)
      w.write_bits(g.big_values.to_int64(), 9)
      w.write_bits(g.global_gain.to_int64(), 8)
      w.write_bits(g.scalefac_compress.to_int64(), 4)
      w.write_bits(g.window_switching_flag.to_int64(), 1)
      if g.window_switching_flag == 0 {
        w.write_bits(g.table_select0.to_int64(), 5)
        w.write_bits(g.table_select1.to_int64(), 5)
        w.write_bits(g.table_select2.to_int64(), 5)
        w.write_bits(g.region0_count.to_int64(), 4)
        w.write_bits(g.region1_count.to_int64(), 3)
      } else {
        w.write_bits(g.block_type.to_int64(), 2)
        w.write_bits(g.mixed_block_flag.to_int64(), 1)
        w.write_bits(g.table_select0.to_int64(), 5)
        w.write_bits(g.table_select2.to_int64(), 5)
        w.write_bits(g.subblock_gain0.to_int64(), 3)
        w.write_bits(g.subblock_gain1.to_int64(), 3)
        w.write_bits(g.subblock_gain2.to_int64(), 3)
      }
      w.write_bits(g.preflag.to_int64(), 1)
      w.write_bits(g.scalefac_scale.to_int64(), 1)
      w.write_bits(g.count1table_select.to_int64(), 1)
    }
  }
}
