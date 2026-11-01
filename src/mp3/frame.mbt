// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Frame headers and the CBR frame-size bookkeeping. ISO/IEC 11172-3 §3.3.2.

///| v1 encodes at a constant 128 kbps; its Layer III bitrate index.
pub const BitrateIndex128 : Int32 = 9

///| Output bitrate of v1, in bits per second.
pub const Bitrate128kbps : Int32 = 128000

///| The fixed output sample rate of v1, 44100 Hz.
pub const SampleRate44100 : Int32 = 44100

///| Layer III samplerate table index of 44100 Hz under MPEG-1.
pub const SampleRateIndex44100 : Int32 = 0

///| Samples carried by one Layer III frame, per channel.
pub const FrameSamples : Int32 = 1152

///| Unpadded frame size at 128 kbps / 44100 Hz, `floor(144 * bitrate /
/// samplerate)` bytes.
pub const BaseFrameBytes : Int32 = 417

///| Channel mode field: 00 stereo, 01 joint stereo, 10 dual, 11 mono.
pub const ModeStereo : Int32 = 0

///| The mono value of the channel mode field.
pub const ModeMono : Int32 = 3

///| Write the 4-byte MPEG-1 Layer III frame header.
///
/// Protection is always set (no CRC): the v1 coder carries no protected
/// frames, and every field the header still allows (private, mode extension,
/// copyright, original, emphasis) is written as zero.
pub fn write_header(
  w : @bits.BitWriter,
  bitrate_index : Int32,
  samplerate_index : Int32,
  mode : Int32,
  padding : Int32,
) -> Unit {
  w.write_bits(0x7FFL, 11)
  // frame sync, eleven set bits
  w.write_bits(0b11L, 2)
  // MPEG Version 1 (not 2 or 2.5)
  w.write_bits(0b01L, 2)
  // Layer III (not I or II)
  w.write_bits(1L, 1)
  // protection: 1 = no CRC follows
  w.write_bits(bitrate_index.to_int64(), 4)
  w.write_bits(samplerate_index.to_int64(), 2)
  w.write_bits(padding.to_int64(), 1)
  w.write_bits(0L, 1)
  // private bit
  w.write_bits(mode.to_int64(), 2)
  w.write_bits(0L, 2)
  // mode extension (unused by plain stereo and mono)
  w.write_bits(0L, 1)
  // copyright
  w.write_bits(0L, 1)
  // original
  w.write_bits(0L, 2)
  // emphasis
}

///| Exact frame-size bookkeeping for CBR output.
///
/// `144 * bitrate / samplerate` is not an integer at 44.1 kHz — 417.96 bytes
/// at 128 kbps — so the padding bit has to track the accumulated error. The
/// invariant is that after `n` frames the emitted byte total equals
/// `floor(n * 144 * bitrate / samplerate)`; this sizer derives each frame's
/// size from that total instead of guessing a padding pattern, so the average
/// bitrate is exactly 128 kbps and the frame grid never drifts.
pub struct FrameSizer {
  numer : Int64

  denom : Int64

  base : Int32

  mut emitted : Int32

  mut total : Int64
}

///| Track frame sizes for a CBR stream of `bitrate` bits per second at
/// `samplerate` samples per second.
pub fn FrameSizer::new(bitrate : Int32, samplerate : Int32) -> FrameSizer {
  let numer = 144L * bitrate.to_int64()
  FrameSizer::{
    numer,
    denom: samplerate.to_int64(),
    base: (numer / samplerate.to_int64()).to_int(),
    emitted: 0,
    total: 0,
  }
}

///| Size in bytes of the next frame, padding already included.
///
/// At 128 kbps / 44.1 kHz this is 417 for the first frame and 418 for almost
/// every one after it: 47 of every 49 frames carry the padding bit.
pub fn FrameSizer::next_frame_size(self : FrameSizer) -> Int32 {
  self.emitted = self.emitted + 1
  let target = (self.emitted.to_int64() * self.numer) / self.denom
  let size = target - self.total
  self.total = target
  size.to_int()
}

///| The padding bit value for a frame of `size` bytes.
pub fn FrameSizer::padding_of(self : FrameSizer, size : Int32) -> Int32 {
  size - self.base
}
