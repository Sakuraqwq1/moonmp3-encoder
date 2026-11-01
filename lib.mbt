// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// This is the one entry point most callers need: give it interleaved samples
/// in the -32768..32767 range plus the stream parameters, and it returns a
/// complete MP3 byte stream (CBR, 128 kbps, 44100 Hz in v1).
///
/// In 0.1.x the samples are not coded yet: the result is a structurally valid
/// stream whose main data decodes to silence. MDCT, quantisation and Huffman
/// coding replace that payload in the next release.
pub fn encode(
  samples : Array[Int32],
  sample_rate : Int32,
  channels : Int32,
) -> Bytes raise @mp3.EncodeError {
  @mp3.encode(samples, sample_rate, channels)
}

///|
/// Version of the `moonmp3-encoder` module.
/// Keep in sync with the `version` field in `moon.mod`.
pub fn version() -> String {
  "0.1.1"
}
