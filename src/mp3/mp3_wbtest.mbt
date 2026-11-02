// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Whitebox tests: the frame header has exactly one legal encoding per
// parameter set, and the side information must land on 17/32 bytes exactly,
// so both are pinned against hand-computed bytes.

///|
test "header : stereo 128 kbps 44.1 kHz, no padding" {
  let w = @bits.BitWriter::new()
  write_header(w, BitrateIndex128, SampleRateIndex44100, ModeStereo, 0)
  let bytes = w.finish()
  assert_eq(bytes.length(), 4)
  assert_eq(bytes[0].to_int(), 0xFF)
  assert_eq(bytes[1].to_int(), 0xFB)
  assert_eq(bytes[2].to_int(), 0x90)
  assert_eq(bytes[3].to_int(), 0x00)
}

///|
test "header : mono sets the mode field" {
  let w = @bits.BitWriter::new()
  write_header(w, BitrateIndex128, SampleRateIndex44100, ModeMono, 0)
  let bytes = w.finish()
  assert_eq(bytes[3].to_int(), 0xC0)
}

///|
test "header : the padding bit is byte 2, bit 1" {
  let w = @bits.BitWriter::new()
  write_header(w, BitrateIndex128, SampleRateIndex44100, ModeStereo, 1)
  let bytes = w.finish()
  assert_eq(bytes[2].to_int(), 0x92)
}

///|
test "sizer : the frame grid is exact and never drifts" {
  let sizer = FrameSizer::new(Bitrate128kbps, SampleRate44100)
  let mut total = 0
  for frame = 0; frame < 49; frame = frame + 1 {
    let size = sizer.next_frame_size()
    assert_eq(size == 417 || size == 418, true)
    if frame == 0 {
      assert_eq(size, 417)
    }
    if frame == 1 {
      assert_eq(size, 418)
    }
    assert_eq(size, BaseFrameBytes + sizer.padding_of(size))
    total = total + size
  }
  // 49 frames of 128 kbps at 44.1 kHz are exactly 20480 bytes.
  assert_eq(total, 20480)
}

///|
test "sizer : the padding bit survives 200 frames" {
  let sizer = FrameSizer::new(Bitrate128kbps, SampleRate44100)
  let mut total = 0
  for frame = 0; frame < 200; frame = frame + 1 {
    let size = sizer.next_frame_size()
    let padding = sizer.padding_of(size)
    assert_eq(padding == 0 || padding == 1, true)
    assert_eq(size, BaseFrameBytes + padding)
    total = total + size
  }
  // floor(200 * 144 * 128000 / 44100) = floor(83591.8) = 83591 bytes.
  assert_eq(total, 83591)
}

///|
test "side info : mono is exactly 17 bytes" {
  let w = @bits.BitWriter::new()
  let scfsi = [0]
  let granules = [GranuleInfo::silent(), GranuleInfo::silent()]
  write_side_info(w, 1, 0, scfsi, granules)
  assert_eq(w.bit_length(), 136)
  let bytes = w.finish()
  assert_eq(bytes.length(), 17)
}

///|
test "side info : stereo is exactly 32 bytes" {
  let w = @bits.BitWriter::new()
  let scfsi = [0, 0]
  let granules = [
    GranuleInfo::silent(),
    GranuleInfo::silent(),
    GranuleInfo::silent(),
    GranuleInfo::silent(),
  ]
  write_side_info(w, 2, 0, scfsi, granules)
  assert_eq(w.bit_length(), 256)
  let bytes = w.finish()
  assert_eq(bytes.length(), 32)
}

///|
test "side info : all-zero granules serialise to zero bytes" {
  let w = @bits.BitWriter::new()
  let scfsi = [0]
  let granules = [GranuleInfo::silent(), GranuleInfo::silent()]
  write_side_info(w, 1, 0, scfsi, granules)
  let bytes = w.finish()
  for index = 0; index < bytes.length(); index = index + 1 {
    assert_eq(bytes[index].to_int(), 0)
  }
}

///|
test "encode : one second of stereo silence is 39 valid frames" {
  let samples = Array::make(44100 * 2, 0)
  let mp3 = encode(samples, SampleRate44100, 2)
  // 39 frames: floor(39 * 144 * 128000 / 44100) = 16300 bytes in total.
  assert_eq(mp3.length(), 16300)
  let mut frames = 0
  let mut offset = 0
  while offset + 4 <= mp3.length() {
    assert_eq(mp3[offset].to_int(), 0xFF)
    assert_eq(mp3[offset + 1].to_int(), 0xFB)
    let padding = (mp3[offset + 2].to_int() & 2) >> 1
    let size = BaseFrameBytes + padding
    frames = frames + 1
    offset = offset + size
  }
  assert_eq(frames, 39)
  assert_eq(offset, 16300)
}

///|
test "encode : rejects what v1 does not support" {
  assert_eq(rejects([0, 0, 0, 0], 48000, 2), true)
  assert_eq(rejects([0, 0, 0, 0], 44100, 3), true)
  assert_eq(rejects([], 44100, 1), true)
  assert_eq(rejects([1, 2, 3], 44100, 2), true)
  assert_eq(rejects([0, 0, 0, 0], 44100, 2), false)
}

///|
/// True when the encoder refuses these parameters.
fn rejects(samples : Array[Int32], rate : Int32, channels : Int32) -> Bool {
  try {
    let _ = encode(samples, rate, channels)
    false
  } catch {
    (_ : EncodeError) => true
  }
}

///|
test "count1 : zero quadruple is table-B code 1111" {
  let w = @bits.BitWriter::new()
  assert_eq(write_count1(w, [0, 0, 0, 0]), 4)
  let bytes = w.finish()
  assert_eq(bytes.length(), 1)
  assert_eq(bytes[0].to_int(), 0xF0)
}

///|
test "count1 : positive first coefficient emits code then sign zero" {
  let w = @bits.BitWriter::new()
  assert_eq(write_count1(w, [1, 0, 0, 0]), 5)
  let bytes = w.finish()
  assert_eq(bytes.length(), 1)
  assert_eq(bytes[0].to_int(), 0x70)
}

///|
test "count1 : negative first coefficient emits sign one" {
  let w = @bits.BitWriter::new()
  assert_eq(write_count1(w, [-1, 0, 0, 0]), 5)
  let bytes = w.finish()
  assert_eq(bytes.length(), 1)
  assert_eq(bytes[0].to_int(), 0x78)
}

///|
test "count1 : all four non-zero coefficients carry four sign bits" {
  let w = @bits.BitWriter::new()
  assert_eq(write_count1(w, [1, -1, 1, -1]), 8)
  let bytes = w.finish()
  assert_eq(bytes.length(), 1)
  assert_eq(bytes[0].to_int(), 0x05)
}

///|
test "count1 : rejects values outside -1/0/1 and partial quadruples" {
  assert_eq(rejects_count1([2, 0, 0, 0]), true)
  assert_eq(rejects_count1([0, 0, 0]), true)
}

///|
test "count1 spectrum : side info length matches the emitted bits" {
  let spectrum = Array::make(576, 0)
  spectrum[12] = 1
  let mp3 = encode_count1_spectrum(2, 1, spectrum, 210)
  assert_eq(mp3.length(), 835)
  // Header is four bytes. After main_data_begin/private/scfsi, part2_3_length
  // starts at side-info bit 18: six bits in byte 6 and six more in byte 7.
  let length = ((mp3[6].to_int() & 0x3F) << 6) | (mp3[7].to_int() >> 2)
  assert_eq(length, 577)
}

///|
test "count1 spectrum : stereo full-scale data cannot overflow a frame" {
  let spectrum = Array::make(576, 1)
  assert_eq(rejects_count1_spectrum(spectrum), true)
}

///|
fn rejects_count1(values : Array[Int32]) -> Bool {
  let w = @bits.BitWriter::new()
  try {
    let _ = write_count1(w, values)
    false
  } catch {
    (_ : Count1Error) => true
  }
}

///|
fn rejects_count1_spectrum(spectrum : Array[Int32]) -> Bool {
  try {
    let _ = encode_count1_spectrum(2, 2, spectrum, 210)
    false
  } catch {
    (_ : Count1Error) => true
  }
}
