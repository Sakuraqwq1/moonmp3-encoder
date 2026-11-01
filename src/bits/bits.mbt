// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// MSB-first bit writer. An MP3 frame's side information and main data form a
/// continuous bit stream, so every field (including the ones that are not byte
/// aligned) goes through here. Bits accumulate MSB-first into bytes, matching
/// the bit order the Layer III spec requires.
pub struct BitWriter {
  buffer : @buffer.Buffer
  mut current : Int32
  mut filled : Int32
}

///|
/// A fresh writer with an empty buffer.
pub fn BitWriter::new() -> BitWriter {
  BitWriter::{
    buffer: @buffer.Buffer::Buffer(size_hint=8192),
    current: 0,
    filled: 0,
  }
}

///|
/// Append a single bit.
pub fn BitWriter::write_bit(self : BitWriter, bit : Int32) -> Unit {
  self.current = (self.current << 1) | (bit & 1)
  self.filled = self.filled + 1
  if self.filled == 8 {
    self.buffer.write_byte(self.current.to_byte())
    self.current = 0
    self.filled = 0
  }
}

///|
/// Append the low `count` bits of `value`, most significant first.
pub fn BitWriter::write_bits(
  self : BitWriter,
  value : Int64,
  count : Int32,
) -> Unit {
  // Whole bytes go straight to the buffer when the writer is aligned; the
  // per-bit path costs a method call each and main data is mostly bytes.
  let mut remaining = count
  let mut shift = count
  while remaining >= 8 && self.filled == 0 {
    shift = shift - 8
    self.buffer.write_byte(((value >> shift) & 0xFFL).to_byte())
    remaining = remaining - 8
  }
  let mut index = remaining - 1
  while index >= 0 {
    self.write_bit(((value >> index) & 1L).to_int())
    index = index - 1
  }
}

///|
/// Number of bits written so far.
pub fn BitWriter::bit_length(self : BitWriter) -> Int32 {
  self.buffer.length() * 8 + self.filled
}

///|
/// Pad with zero bits until the stream is byte aligned.
pub fn BitWriter::align(self : BitWriter) -> Unit {
  while self.filled != 0 {
    self.write_bit(0)
  }
}

///|
/// Finish the stream and return the bytes written. The writer is unusable
/// afterwards; make a new one for the next frame.
pub fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.align()
  self.buffer.to_bytes()
}
