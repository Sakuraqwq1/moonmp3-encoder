// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Fixed-spectrum streams for the first bitstream vertical slice. This is not
// the PCM encoder: it emits the same 576-coefficient spectrum in every
// granule, which makes it possible to test Huffman coding, side information,
// frame assembly and an independent decoder without the analysis filterbank.

///|
/// Encode a fixed 576-line count1 spectrum into a sequence of MP3 frames.
///
/// Each value must be -1, 0 or 1. Every granule and every channel carries the
/// same spectrum and global gain. `main_data_begin` is always zero and no
/// scalefactors are transmitted, so each granule is self-contained.
pub fn encode_count1_spectrum(
  frames : Int32,
  channels : Int32,
  spectrum : Array[Int32],
  global_gain : Int32,
) -> Bytes raise Count1Error {
  if frames <= 0 {
    raise BadFrames(frames)
  }
  if channels != 1 && channels != 2 {
    raise BadChannels(channels)
  }
  if global_gain < 0 || global_gain > 255 {
    raise BadGain(global_gain)
  }
  if spectrum.length() != 576 {
    raise BadLength(spectrum.length())
  }
  let granule_bits = count1_bits(spectrum)
  let side_bits = if channels == 1 { 136 } else { 256 }
  let required_bits = 32 + side_bits + granule_bits * 2 * channels
  let sizer = FrameSizer::new(Bitrate128kbps, SampleRate44100)
  let out = @buffer.Buffer::Buffer(size_hint=8192)
  for _frame = 0; _frame < frames; _frame = _frame + 1 {
    let size = sizer.next_frame_size()
    if required_bits > size * 8 {
      raise FrameOverflow(required_bits)
    }
    let padding = sizer.padding_of(size)
    let mode = if channels == 1 { ModeMono } else { ModeStereo }
    let w = @bits.BitWriter::new()
    write_header(w, BitrateIndex128, SampleRateIndex44100, mode, padding)
    let scfsi = Array::make(channels, 0)
    let granules = Array::make(
      2 * channels,
      GranuleInfo::count1(granule_bits, global_gain),
    )
    write_side_info(w, channels, 0, scfsi, granules)
    for _gr = 0; _gr < 2; _gr = _gr + 1 {
      for _ch = 0; _ch < channels; _ch = _ch + 1 {
        let _ = write_count1(w, spectrum)
      }
    }
    w.write_bits(0L, size * 8 - w.bit_length())
    let frame = w.finish()
    for index = 0; index < frame.length(); index = index + 1 {
      out.write_byte(frame[index])
    }
  }
  out.to_bytes()
}
