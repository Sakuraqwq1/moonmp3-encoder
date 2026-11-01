// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

///|
/// Failures the encoder can report.
pub suberror EncodeError {
  /// v1 emits 44100 Hz only; other rates are planned for later versions.
  UnsupportedSampleRate(Int32)
  /// v1 emits mono and stereo only.
  UnsupportedChannels(Int32)
  /// The sample count is not a whole number of frames for the channel count.
  NotInterleaved(Int32)
  /// No samples were supplied.
  EmptyInput
}

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// v1 is a structural milestone: the frames, side information and CBR sizing
/// are real and the output decodes everywhere, but the main data is still
/// zero, so the stream carries silence regardless of the input samples. The
/// MDCT, quantiser and Huffman stages land next and will replace the zero
/// payload without touching this frame layout.
pub fn encode(
  samples : Array[Int32],
  sample_rate : Int32,
  channels : Int32,
) -> Bytes raise EncodeError {
  if sample_rate != SampleRate44100 {
    raise UnsupportedSampleRate(sample_rate)
  }
  if channels != 1 && channels != 2 {
    raise UnsupportedChannels(channels)
  }
  if samples.length() == 0 {
    raise EmptyInput
  }
  if samples.length() % channels != 0 {
    raise NotInterleaved(samples.length())
  }
  let per_channel = samples.length() / channels
  let nframes = (per_channel + FrameSamples - 1) / FrameSamples
  let mode = if channels == 1 { ModeMono } else { ModeStereo }
  let sizer = FrameSizer::new(Bitrate128kbps, sample_rate)
  let out = @buffer.Buffer::Buffer(size_hint=8192)
  for _frame = 0; _frame < nframes; _frame = _frame + 1 {
    let size = sizer.next_frame_size()
    let padding = sizer.padding_of(size)
    let w = @bits.BitWriter::new()
    write_header(w, BitrateIndex128, SampleRateIndex44100, mode, padding)
    // Silent main data: an empty bit reservoir and granules that decode to
    // zero. Every remaining byte in the frame is ancillary stuffing.
    let scfsi = Array::make(channels, 0)
    let granules = Array::make(2 * channels, GranuleInfo::silent())
    write_side_info(w, channels, 0, scfsi, granules)
    let stuffing_bits = size * 8 - w.bit_length()
    w.write_bits(0L, stuffing_bits)
    let frame = w.finish()
    for index = 0; index < frame.length(); index = index + 1 {
      out.write_byte(frame[index])
    }
  }
  out.to_bytes()
}
