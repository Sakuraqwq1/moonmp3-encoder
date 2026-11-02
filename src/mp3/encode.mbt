// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The public entry point. Frame layout, side information and CBR sizing are the
// stable 0.1.x assets; the payload that used to be zero is now a real
// PCM -> filterbank -> MDCT -> count1 chain.

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
  /// A granule could not be analysed (internal length invariant broken).
  AnalysisFailed(Int32)
  /// A granule could not be quantised (internal length invariant broken).
  QuantizationFailed(Int32)
}

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// Each granule is analysed with the 32-band polyphase filterbank and the
/// 36-point long-block MDCT, quantised to the count1 range (-1/0/1) and written
/// with the count1 Huffman table. `big_values` is therefore always zero and no
/// scalefactors are transmitted: the whole granule is a unit-coefficient sparse
/// spectrum plus one `global_gain`.
///
/// This is the first audible stage, not the final quality stage. A steady tone
/// comes out at the right frequency and a recognisable amplitude; broadband
/// material is coarse, because one bit per line cannot carry a dense spectrum.
/// The big_values tables, scalefactor bands and the rate-control loop replace it
/// later without touching this frame layout.
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
  let side_bits = if channels == 1 { 136 } else { 256 }
  let sizer = FrameSizer::new(Bitrate128kbps, sample_rate)
  let analysis : Array[ChannelAnalysis] = []
  for channel = 0; channel < channels; channel = channel + 1 {
    analysis.push(ChannelAnalysis::new())
  }
  let pcm = Array::make(GranulePcm, 0.0)
  let out = @buffer.Buffer::Buffer(size_hint=8192)
  for frame = 0; frame < nframes; frame = frame + 1 {
    let size = sizer.next_frame_size()
    let padding = sizer.padding_of(size)
    // Each granule gets an equal share of the frame's main-data budget. Without
    // it a dense stereo spectrum would overrun the frame and the stream would
    // stop parsing, which is exactly the failure this encoder must not have.
    let budget_per_granule = (size * 8 - 32 - side_bits) / (2 * channels)
    let nonzero_limit = budget_per_granule - LinesPerGranuleCount
    let payloads : Array[Array[Int32]] = []
    let granules : Array[GranuleInfo] = []
    for granule = 0; granule < 2; granule = granule + 1 {
      for channel = 0; channel < channels; channel = channel + 1 {
        let start = frame * FrameSamples + granule * GranulePcm
        for index = 0; index < GranulePcm; index = index + 1 {
          let absolute = start + index
          pcm[index] = if absolute < per_channel {
            samples[absolute * channels + channel].to_double() / 32768.0
          } else {
            0.0
          }
        }
        let lines = analysis[channel].granule(pcm) catch {
          (_ : AnalysisError) => raise AnalysisFailed(frame)
        }
        let (gain, quantized) = quantize_count1_fitting(lines, nonzero_limit) catch {
          (_ : QuantizeError) => raise QuantizationFailed(frame)
        }
        payloads.push(quantized)
        granules.push(GranuleInfo::count1(count1_cost(quantized), gain))
      }
    }
    let w = @bits.BitWriter::new()
    write_header(w, BitrateIndex128, SampleRateIndex44100, mode, padding)
    let scfsi = Array::make(channels, 0)
    write_side_info(w, channels, 0, scfsi, granules)
    for index = 0; index < payloads.length(); index = index + 1 {
      let _ = write_count1(w, payloads[index]) catch {
        (_ : Count1Error) => raise QuantizationFailed(frame)
      }
    }
    let stuffed = size * 8 - w.bit_length()
    if stuffed < 0 {
      raise AnalysisFailed(frame)
    }
    w.write_bits(0L, stuffed)
    let bytes = w.finish()
    for index = 0; index < bytes.length(); index = index + 1 {
      out.write_byte(bytes[index])
    }
  }
  out.to_bytes()
}
