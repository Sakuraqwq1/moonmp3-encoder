// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The public entry point. Frame layout, side information and CBR sizing are the
// stable 0.1.x assets; the payload is a real
// PCM -> filterbank -> MDCT -> quantiser -> big_values/count1 chain.

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
  /// A granule could not be Huffman coded within the frame.
  HuffmanFailed(Int32)
}

///|
/// One granule, quantised and priced.
priv struct GranulePlan {
  values : Array[Int32]
  table : Int32
  big_values : Int32
  gain : Int32
  cost : Int32
}

///|
/// Quantise one granule for a given gain and price it exactly.
fn plan_granule(lines : Array[Double], gain : Int32) -> GranulePlan {
  let values = quantize_with_gain(lines, gain)
  let big = big_values_needed(values)
  let table = choose_table(values, big)
  let cost = granule_cost(values, table, big)
  GranulePlan::{ values, table, big_values: big, gain, cost, }
}

///|
/// Smallest gain whose exact bit cost fits `budget`.
///
/// Cost falls as the gain rises (coefficients get smaller, then zero), so a
/// binary search over the 8-bit field finds the least coarsening that fits. The
/// search always terminates on a fitting gain because a fully zeroed granule
/// costs 576 bits and every granule's share is larger than that.
fn plan_with_budget(lines : Array[Double], budget : Int32) -> GranulePlan {
  let peak = peak_absolute(lines)
  if peak <= 0.0 {
    return plan_granule(lines, 0)
  }
  let quantiser = GranuleQuantiser::new(lines)
  // The gain that puts the peak on the top level is the natural starting point,
  // but it is not always the best one: rounding the gain to an integer can leave
  // the loudest lines between levels. Scan a window around it and keep the
  // candidate with the smallest reconstruction error that still fits the budget.
  let centre = global_gain_for_peak(peak, MaxQuantLevel)
  let mut best = plan_granule(lines, centre)
  let mut best_error = quantiser.error(best.values, best.gain)
  for offset = 0; offset <= 6; offset = offset + 1 {
    if offset == 0 {
      continue
    }
    let gain = centre + offset
    if gain < 0 || gain > 255 {
      continue
    }
    let values = quantiser.quantise(gain)
    let big = big_values_needed(values)
    let table = choose_table(values, big)
    let cost = granule_cost(values, table, big)
    if cost < 0 || cost > budget {
      continue
    }
    let error = quantiser.error(values, gain)
    if error < best_error {
      best = GranulePlan::{ values, table, big_values: big, gain, cost, }
      best_error = error
    }
  }
  if best.cost <= budget {
    return best
  }
  // Nothing in the window fitted; coarsen until it does. A fully zeroed granule
  // costs 576 bits, which every granule's share exceeds, so this terminates.
  let mut low = centre
  let mut high = 255
  while low < high {
    let mid = (low + high) / 2
    if plan_granule(lines, mid).cost <= budget {
      high = mid
    } else {
      low = mid + 1
    }
  }
  let chosen = plan_granule(lines, low)
  if chosen.cost <= budget {
    return chosen
  }
  // The bisection assumes the cost falls monotonically with the gain. That is
  // nearly true but not exactly — a broadband transient can make a mid gain cost
  // more than a coarser one — so walk upward to the first gain that really fits,
  // then fall back to the fully zeroed granule, which no budget can overflow.
  let mut gain = low + 1
  while gain <= 255 {
    let candidate = plan_granule(lines, gain)
    if candidate.cost <= budget {
      return candidate
    }
    gain = gain + 1
  }
  plan_granule(lines, 255)
}

///|
/// One frame's granule data, before it is placed into a frame area.
priv struct FramePlan {
  /// Frame size in bytes, padding bit already included.
  size : Int32
  /// Padding bit of the header.
  padding : Int32
  /// Bit offset in the reservoir where this frame's granule data starts.
  start : Int32
  granules : Array[GranuleInfo]
}

///|
/// Analyse and plan one frame, and append its granule data to the reservoir.
///
/// `area_start_bits` is where this frame's main-data area will begin, which the
/// caller knows because areas are emitted in order. The reservoir may already
/// hold data for this frame from earlier areas; `start` records where it begins,
/// and the caller turns `area_start - start` into `main_data_begin`.
///
/// The budget is every bit the decoder can reach when this frame is decoded: the
/// unused bytes left by earlier frames (at most 511, the width of the field) plus
/// this frame's own area. A granule that does not need its share simply spends
/// less, which is what leaves the next frames something to borrow.
fn plan_frame(
  frame : Int32,
  channels : Int32,
  per_channel : Int32,
  samples : Array[Int32],
  analysis : Array[ChannelAnalysis],
  pcm : Array[Double],
  sizer : FrameSizer,
  reservoir : MainDataReservoir,
  area_start_bits : Int32,
) -> FramePlan raise EncodeError {
  let size = sizer.next_frame_size()
  let padding = sizer.padding_of(size)
  let side_bits = if channels == 1 { 136 } else { 256 }
  let capacity = size * 8 - 32 - side_bits
  // The stream has to start this frame's data on a byte boundary, because
  // `main_data_begin` counts whole bytes.
  let aligned = reservoir.align()
  let mut lag = area_start_bits / 8 - aligned / 8
  if lag > 511 {
    // The field cannot reach further back than the decoder's buffer; drop the
    // excess as unused space rather than write an out-of-range offset.
    reservoir.pad((lag - 511) * 8)
    lag = 511
  }
  if lag < 0 {
    raise AnalysisFailed(frame)
  }
  // After padding, the frame's data starts where the stream now ends.
  let start = reservoir.length
  let budget = (lag + capacity / 8) * 8
  let share = budget / (2 * channels)
  let granules : Array[GranuleInfo] = []
  let w = @bits.BitWriter::new()
  let mut bits = 0
  for granule = 0; granule < 2; granule = granule + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      let offset = frame * FrameSamples + granule * GranulePcm
      for index = 0; index < GranulePcm; index = index + 1 {
        let absolute = offset + index
        pcm[index] = if absolute < per_channel {
          samples[absolute * channels + channel].to_double() / 32768.0
        } else {
          0.0
        }
      }
      let lines = analysis[channel].granule(pcm) catch {
        (_ : AnalysisError) => raise AnalysisFailed(frame)
      }
      let plan = plan_with_budget(lines, share)
      if plan.cost > share {
        raise HuffmanFailed(frame)
      }
      granules.push(
        GranuleInfo::big_values(
          plan.cost,
          plan.big_values,
          plan.gain,
          plan.table,
        ),
      )
      let written = write_granule(w, plan.values, plan.table, plan.big_values) catch {
        (_ : HuffmanError) => raise HuffmanFailed(frame)
      }
      if written != plan.cost {
        raise HuffmanFailed(frame)
      }
      bits = bits + plan.cost
    }
  }
  reservoir.append(w.finish(), bits)
  FramePlan::{ size, padding, start, granules, }
}

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// Each granule is analysed with the 32-band polyphase filterbank and the
/// 36-point long-block MDCT, quantised to the magnitudes MPEG-1 tables can carry
/// and written as a big_values region plus a count1 tail. No scalefactors are
/// transmitted yet: one `global_gain` sets the scale for the whole granule.
///
/// Main data is one continuous bit stream cut into the frames' areas, so the whole
/// stream has to exist before any area is written: a frame's data may begin up to
/// 511 bytes before that frame's area, i.e. inside areas that are emitted earlier.
/// Hence two passes — analyse and plan every frame into the reservoir, then lay the
/// areas out. The input is already in memory, so the buffering costs no more than
/// the sample array does.
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
  let analysis : Array[ChannelAnalysis] = []
  for channel = 0; channel < channels; channel = channel + 1 {
    analysis.push(ChannelAnalysis::new())
  }
  let pcm = Array::make(GranulePcm, 0.0)
  let out = @buffer.Buffer::Buffer(size_hint=8192)
  let reservoir = MainDataReservoir::new()
  // Pass one: analyse, quantise and append, which fixes where every frame's data
  // lands in the stream.
  let plans : Array[FramePlan] = []
  let side_bits = if channels == 1 { 136 } else { 256 }
  let mut area_start = 0
  for frame = 0; frame < nframes; frame = frame + 1 {
    let plan = plan_frame(
      frame, channels, per_channel, samples, analysis, pcm, sizer, reservoir, area_start,
    )
    area_start = area_start + plan.size * 8 - 32 - side_bits
    plans.push(plan)
  }
  // Pass two: cut the stream into the areas, which follow one another at the
  // frame sizes the CBR sizer picked.
  for frame = 0; frame < nframes; frame = frame + 1 {
    let plan = plans[frame]
    let main_data_begin = reservoir.placed() / 8 - plan.start / 8
    if main_data_begin < 0 || main_data_begin > 511 {
      raise AnalysisFailed(frame)
    }
    let w = @bits.BitWriter::new()
    write_header(w, BitrateIndex128, SampleRateIndex44100, mode, plan.padding)
    let scfsi = Array::make(channels, 0)
    write_side_info(w, channels, main_data_begin, scfsi, plan.granules)
    let capacity = plan.size * 8 - 32 - side_bits
    reservoir.take(w, capacity)
    let bytes = w.finish()
    for index = 0; index < bytes.length(); index = index + 1 {
      out.write_byte(bytes[index])
    }
  }
  out.to_bytes()
}
