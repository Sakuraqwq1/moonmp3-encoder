// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// `sample_rate` must be one of the three MPEG-1 standard rates — 32000, 44100
/// or 48000 Hz — and `bitrate~` one of the fourteen standard CBR bitrates,
/// 32..320 kbps. `bitrate~` defaults to 128 kbps, so the original three-argument
/// call `encode(samples, 44100, 1)` keeps working unchanged; pass it by label to
/// pick another bitrate: `encode(samples, 48000, 2, bitrate~ = 192)`. Both kbps
/// (`192`) and bit-per-second (`192000`) forms are accepted; anything outside
/// the standard table is rejected with `UnsupportedBitrate`.
///
/// Together that is 3 sample rates x 14 bitrates x mono/stereo = 84 standard
/// configurations, all of which are exercised end to end by
/// `python tools/rates.py`.
///
/// The samples really are coded: each granule goes through the 32-band
/// polyphase filterbank, long/short-block MDCT with transient window switching,
/// per-band scalefactor quantisation, big_values Huffman tables and a count1
/// tail that terminates an all-zero high-frequency region with a single bit.
/// Consecutive frames share the standard bit reservoir, and a continuous
/// headroom rule prevents near-full-scale inputs from clipping after decoding.
pub fn encode(
  samples : Array[Int32],
  sample_rate : Int32,
  channels : Int32,
  bitrate~ : Int32 = 128000,
) -> Bytes raise @mp3.EncodeError {
  @mp3.encode(samples, sample_rate, channels, bitrate~)
}

///|
/// Same as `encode`, with the bitrate as a positional argument:
/// `encode_at(samples, 44100, 2, 128000)`.
pub fn encode_at(
  samples : Array[Int32],
  sample_rate : Int32,
  channels : Int32,
  bitrate : Int32,
) -> Bytes raise @mp3.EncodeError {
  @mp3.encode_at(samples, sample_rate, channels, bitrate)
}

///|
/// Version of the `moonmp3-encoder` module.
/// Keep in sync with the `version` field in `moon.mod`.
pub fn version() -> String {
  "0.3.0"
}
