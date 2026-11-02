// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The main-data bit reservoir of ISO/IEC 11172-3 §2.4.3.4.
//
// Main data is not a per-frame payload: it is one continuous bit stream cut into
// the frames' main-data areas, and a frame's `main_data_begin` says how many
// bytes *before* its own area its data begins. A frame therefore spends bytes
// that an earlier frame left unused, which is what lets a loud granule borrow
// from quiet neighbours; the decoder only has to keep the last 511 bytes, which
// is why the field is nine bits wide.
//
// The encoder writes the stream first and fills the areas afterwards, so it
// needs one frame of lookahead: when frame `f`'s area is written, frame `f+1`'s
// granules have to be in the reservoir already, because the area may contain
// them.

///|
/// A growable MSB-first bit buffer that keeps the whole main-data stream.
pub struct MainDataReservoir {
  /// One byte per eight bits, MSB first; the tail is zero padded.
  bytes : Array[Byte]
  /// Valid bits in `bytes`.
  mut length : Int32
  /// Bits already written into frame areas.
  mut placed : Int32
}

///|
/// An empty reservoir.
pub fn MainDataReservoir::new() -> MainDataReservoir {
  MainDataReservoir::{ bytes: Array::make(0, b'\x00'), length: 0, placed: 0, }
}

///|
/// Bits held in the reservoir beyond the areas already written.
pub fn MainDataReservoir::pending(self : MainDataReservoir) -> Int32 {
  self.length - self.placed
}

///|
/// Bits written into frame areas so far.
pub fn MainDataReservoir::placed(self : MainDataReservoir) -> Int32 {
  self.placed
}

///|
/// Append one bit.
pub fn MainDataReservoir::push(self : MainDataReservoir, bit : Int32) -> Unit {
  if self.length % 8 == 0 {
    self.bytes.push(b'\x00')
  }
  if (bit & 1) != 0 {
    let index = self.length / 8
    let mask = (1 << (7 - self.length % 8)).to_byte()
    self.bytes[index] = (self.bytes[index].to_int() | mask.to_int()).to_byte()
  }
  self.length = self.length + 1
}

///|
/// Append the low `count` bits of a packed MSB-first byte array.
pub fn MainDataReservoir::append(
  self : MainDataReservoir,
  bytes : Bytes,
  count : Int32,
) -> Unit {
  for index = 0; index < count; index = index + 1 {
    let value = bytes[index / 8].to_int()
    self.push(value >> (7 - index % 8))
  }
}

///|
/// Append `count` zero bits: the stream's unused space between frames.
pub fn MainDataReservoir::pad(self : MainDataReservoir, count : Int32) -> Unit {
  for index = 0; index < count; index = index + 1 {
    self.push(0)
  }
}

///|
/// Pad to the next byte boundary and return the new length.
pub fn MainDataReservoir::align(self : MainDataReservoir) -> Int32 {
  while self.length % 8 != 0 {
    self.push(0)
  }
  self.length
}

///|
/// Bit `index` of the stream, zero past the end.
pub fn MainDataReservoir::bit(self : MainDataReservoir, index : Int32) -> Int32 {
  if index < 0 || index >= self.length {
    return 0
  }
  let value = self.bytes[index / 8].to_int()
  (value >> (7 - index % 8)) & 1
}

///|
/// The eight bits starting at `index`, most significant first.
pub fn MainDataReservoir::byte_at(
  self : MainDataReservoir,
  index : Int32,
) -> Int32 {
  let mut value = 0
  for offset = 0; offset < 8; offset = offset + 1 {
    value = (value << 1) | self.bit(index + offset)
  }
  value
}

///|
/// Hand `count` bits of the stream to one frame's main-data area.
///
/// The area is a fixed number of bytes; whatever the stream does not have yet
/// reads as zero, which is exactly the padding the frame needs.
pub fn MainDataReservoir::take(
  self : MainDataReservoir,
  w : @bits.BitWriter,
  count : Int32,
) -> Unit {
  for index = 0; index < count; index = index + 8 {
    w.write_bits(self.byte_at(self.placed + index).to_int64(), 8)
  }
  self.placed = self.placed + count
}
