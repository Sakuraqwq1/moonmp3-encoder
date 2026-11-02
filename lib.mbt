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
/// The samples really are coded: each granule goes through the 32-band
/// polyphase filterbank, the long-block MDCT, a quantiser and the count1
/// Huffman table. A steady tone comes back at the right frequency and a
/// recognisable amplitude. Because every frequency line currently costs one
/// bit, a dense spectrum is coarse — the big_values tables, scalefactor bands
/// and rate-control loop are the next stage and will replace the quantiser
/// without changing this signature.
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
