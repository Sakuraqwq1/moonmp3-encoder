// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Whitebox tests for MPEG-1 Layer III sample rates (32k, 44.1k, 48k)
// and bitrates (14 standard bitrates 32..320 kbps).

///|
test "rates : sample rate indices match ISO/IEC 11172-3 Table 3-B.2.c" {
  assert_eq(sample_rate_index(44100), 0)
  assert_eq(sample_rate_index(48000), 1)
  assert_eq(sample_rate_index(32000), 2)
  assert_eq(sample_rate_index(22050), -1)
  assert_eq(sample_rate_index(16000), -1)
  assert_eq(sample_rate_index(0), -1)
}

///|
test "rates : bitrate indices match ISO/IEC 11172-3 Table 3-B.2.b" {
  let bitrates = [
    32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000,
    224000, 256000, 320000,
  ]
  for idx = 0; idx < bitrates.length(); idx = idx + 1 {
    let bps = bitrates[idx]
    let expected_idx = idx + 1
    assert_eq(bitrate_index(bps), expected_idx)
    assert_eq(bitrate_of_index(expected_idx), bps)
  }
  // kbps values accepted as well
  assert_eq(bitrate_index(128), 9)
  assert_eq(bitrate_index(320), 14)
  assert_eq(bitrate_index(0), -1)
  assert_eq(bitrate_index(15000), -1)
  assert_eq(bitrate_index(400000), -1)
}

///|
test "rates : scalefactor band Table B.8.a (32 kHz) strictly monotonic to 576" {
  let rate = SampleRate32000
  assert_eq(scalefactor_band_start(0, rate~), 0)
  let mut prev = 0
  for band = 0; band < LongScalefactorBandCount; band = band + 1 {
    let start = scalefactor_band_start(band, rate~)
    let stop = scalefactor_band_end(band, rate~)
    let width = scalefactor_band_width(band, rate~)
    assert_true(start == prev)
    assert_true(stop > start)
    assert_true(width == stop - start)
    prev = stop
  }
  // Band 20 ends at 550; band 21 covers 550..576 (width 26)
  assert_eq(scalefactor_band_end(20, rate~), 550)
  assert_eq(scalefactor_band_start(21, rate~), 550)
  assert_eq(scalefactor_band_end(21, rate~), 576)
  assert_eq(scalefactor_band_width(21, rate~), 26)
  assert_eq(scalefactor_band_of_line(549, rate~), 20)
  assert_eq(scalefactor_band_of_line(550, rate~), 21)
  assert_eq(scalefactor_band_of_line(575, rate~), 21)
}

///|
test "rates : scalefactor band Table B.8.b (44.1 kHz) strictly monotonic to 576" {
  let rate = SampleRate44100
  assert_eq(scalefactor_band_start(0, rate~), 0)
  let mut prev = 0
  for band = 0; band < LongScalefactorBandCount; band = band + 1 {
    let start = scalefactor_band_start(band, rate~)
    let stop = scalefactor_band_end(band, rate~)
    let width = scalefactor_band_width(band, rate~)
    assert_true(start == prev)
    assert_true(stop > start)
    assert_true(width == stop - start)
    prev = stop
  }
  // Band 20 ends at 418; band 21 covers 418..576 (width 158)
  assert_eq(scalefactor_band_end(20, rate~), 418)
  assert_eq(scalefactor_band_start(21, rate~), 418)
  assert_eq(scalefactor_band_end(21, rate~), 576)
  assert_eq(scalefactor_band_width(21, rate~), 158)
  assert_eq(scalefactor_band_of_line(417, rate~), 20)
  assert_eq(scalefactor_band_of_line(418, rate~), 21)
  assert_eq(scalefactor_band_of_line(575, rate~), 21)
}

///|
test "rates : scalefactor band Table B.8.c (48 kHz) strictly monotonic to 576" {
  let rate = SampleRate48000
  assert_eq(scalefactor_band_start(0, rate~), 0)
  let mut prev = 0
  for band = 0; band < LongScalefactorBandCount; band = band + 1 {
    let start = scalefactor_band_start(band, rate~)
    let stop = scalefactor_band_end(band, rate~)
    let width = scalefactor_band_width(band, rate~)
    assert_true(start == prev)
    assert_true(stop > start)
    assert_true(width == stop - start)
    prev = stop
  }
  // Band 20 ends at 384; band 21 covers 384..576 (width 192)
  assert_eq(scalefactor_band_end(20, rate~), 384)
  assert_eq(scalefactor_band_start(21, rate~), 384)
  assert_eq(scalefactor_band_end(21, rate~), 576)
  assert_eq(scalefactor_band_width(21, rate~), 192)
  assert_eq(scalefactor_band_of_line(383, rate~), 20)
  assert_eq(scalefactor_band_of_line(384, rate~), 21)
  assert_eq(scalefactor_band_of_line(575, rate~), 21)
}

///|
test "rates : padding is strictly 0 for 32k and 48k across all 14 bitrates" {
  let bitrates = [
    32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000,
    224000, 256000, 320000,
  ]
  for rate in [32000, 48000] {
    for bitrate in bitrates {
      let sizer = FrameSizer::new(bitrate, rate)
      for frame = 0; frame < 10; frame = frame + 1 {
        let size = sizer.next_frame_size()
        let pad = sizer.padding_of(size)
        assert_eq(pad, 0)
        let expected_size = 144 * bitrate / rate
        assert_eq(size, expected_size)
      }
    }
  }
}

///|
test "rates : frame byte accumulation exact formula for 44.1k" {
  let sizer = FrameSizer::new(128000, 44100)
  let mut total = 0
  for frame = 1; frame <= 100; frame = frame + 1 {
    let size = sizer.next_frame_size()
    total = total + size
    let expected = (frame.to_int64() * 144L * 128000L / 44100L).to_int()
    assert_eq(total, expected)
  }
}
