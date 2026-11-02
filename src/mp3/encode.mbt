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
  /// Total `part2_3_length`: scalefactor bits plus Huffman bits.
  cost : Int32
  scalefactors : Array[Int32]
  scalefac_compress : Int32
  error : Double
}

///|
/// Price an already-quantised granule, including its scalefactors.
fn plan_from_values(
  values : Array[Int32],
  gain : Int32,
  scalefactors : Array[Int32],
  quantiser : GranuleQuantiser,
  block_type : Int32,
) -> GranulePlan {
  let big = big_values_needed(values)
  let table = choose_table(values, big)
  let huffman_cost = granule_cost(values, table, big)
  let short = block_type == BlockTypeShort
  let compress = if short {
    short_scalefactor_compress(scalefactors)
  } else {
    scalefactor_compress(scalefactors)
  }
  // The allocator only produces values the four-bit field can carry. A
  // negative result would mean a caller bypassed it, and the safe encoding is
  // "no scalefactors" rather than silently truncating 5-bit values into 4 bits.
  let safe_compress = if compress < 0 { 0 } else { compress }
  let scalefactor_bits = if short {
    short_scalefactor_bit_count(safe_compress)
  } else {
    scalefactor_bit_count(safe_compress)
  }
  let cost = huffman_cost + scalefactor_bits
  let error = if short {
    quantiser.error_scaled_short(values, gain, scalefactors, 0)
  } else {
    quantiser.error_scaled(values, gain, scalefactors, 0)
  }
  GranulePlan::{
    values,
    table,
    big_values: big,
    gain,
    cost,
    scalefactors,
    scalefac_compress: safe_compress,
    error,
  }
}

///|
/// Quantise one granule for a given gain and price it exactly.
fn plan_granule(
  lines : Array[Double],
  gain : Int32,
  block_type : Int32,
) -> GranulePlan {
  let quantiser = GranuleQuantiser::new_typed(lines, block_type)
  let values = quantiser.quantise(gain)
  let scalefactors = if block_type == BlockTypeShort {
    zero_short_scalefactors()
  } else {
    zero_scalefactors()
  }
  plan_from_values(values, gain, scalefactors, quantiser, block_type)
}

///|
/// Quantise one granule with explicit per-band scalefactors and price it.
fn plan_scaled(
  gain : Int32,
  scalefactors : Array[Int32],
  quantiser : GranuleQuantiser,
  block_type : Int32,
) -> GranulePlan {
  let values = if block_type == BlockTypeShort {
    quantiser.quantise_scaled_short(gain, scalefactors, 0)
  } else {
    quantiser.quantise_scaled(gain, scalefactors, 0)
  }
  plan_from_values(values, gain, scalefactors, quantiser, block_type)
}

///|
/// Rough bit price of one band under the table the unscaled plan chose.
///
/// The allocator only needs this to rank candidate bands; the winner is always
/// re-priced by `plan_scaled` before it is accepted. Pair costs include the
/// sign bits, and an unrepresentable pair gets a deliberately pessimistic
/// price so it cannot look free.
fn estimate_band_bits(
  values : Array[Int32],
  band : Int32,
  table : Int32,
) -> Int32 {
  let start = scalefactor_band_start(band)
  let stop = scalefactor_band_end(band)
  let mut bits = 0
  let mut index = start
  while index + 1 < stop {
    let cost = pair_cost(table, values[index], values[index + 1])
    bits = bits + (if cost < 0 { 32 } else { cost })
    index = index + 2
  }
  if index < stop {
    // All 44.1 kHz band boundaries are even, so this is only a guard against a
    // future table with an odd width.
    bits = bits + 8
  }
  bits
}

///|
/// Spend leftover frame bits on per-band scalefactors.
///
/// The unscaled plan fixes `global_gain`; each band may then be refined by a
/// scalefactor. Every candidate increment is ranked by the band's exact
/// reconstruction-error drop divided by its estimated bit increase, and is
/// accepted only after an exact whole-granule re-price proves it fits. This is
/// a greedy knapsack: the bands that buy the most error reduction per bit get
/// the headroom first, and a band that cannot fit is removed from the candidate
/// set instead of stalling the loop.
fn refine_scalefactors(
  budget : Int32,
  base : GranulePlan,
  quantiser : GranuleQuantiser,
  block_type : Int32,
) -> GranulePlan {
  if base.error <= 0.0 || base.cost >= budget {
    return base
  }
  if block_type == BlockTypeShort {
    // The short-window path stays on all-zero scalefactors for now: it is
    // decoded correctly as-is, and per-band refinement for the 36 short fields
    // is a follow-up that does not change the window-switching correctness.
    return base
  }
  let profile = LongScalefactorBandCount * 16
  let errors = Array::make(profile, 0.0)
  let estimates = Array::make(profile, 0)
  for band = 0; band < LongScalefactorBandCount; band = band + 1 {
    for scalefactor = 0; scalefactor < 16; scalefactor = scalefactor + 1 {
      let trial = zero_scalefactors()
      trial[band] = scalefactor
      let values = quantiser.quantise_scaled(base.gain, trial, 0)
      errors[band * 16 + scalefactor] = quantiser.band_error(
        values,
        base.gain,
        trial,
        0,
        band,
      )
      estimates[band * 16 + scalefactor] = estimate_band_bits(
        values,
        band,
        base.table,
      )
    }
  }
  let mut current = base
  let mut current_sf = copy_scalefactors(base.scalefactors)
  let blocked = Array::make(LongScalefactorBandCount, false)
  let mut trials = 0
  // Every accepted increment costs at least one bit, but the cap is what keeps
  // a dense granule from turning encoder time into an unbounded search.
  while trials < 64 {
    let mut chosen = -1
    let mut best_score = 0.0
    for band = 0; band < LongScalefactorBandCount; band = band + 1 {
      if blocked[band] {
        continue
      }
      let scalefactor = current_sf[band]
      // Group 1 (sfb 0..10) has up to four bits, group 2 (sfb 11..20) only up
      // to three. A value of 8..15 in group 2 has no `scalefac_compress`
      // encoding at all: `scalefactor_compress` returns -1 and the bitstream
      // would carry no scalefactors while the model assumed they were applied.
      let limit = if band < ScalefactorsInGroup1 { 15 } else { 7 }
      if scalefactor >= limit {
        continue
      }
      let drop = errors[band * 16 + scalefactor] -
        errors[band * 16 + scalefactor + 1]
      if drop <= 0.0 {
        continue
      }
      let extra = estimates[band * 16 + scalefactor + 1] -
        estimates[band * 16 + scalefactor]
      let score = if extra <= 0 {
        drop * 1000000.0
      } else {
        drop / extra.to_double()
      }
      if score > best_score {
        best_score = score
        chosen = band
      }
    }
    if chosen < 0 {
      break
    }
    let next_sf = copy_scalefactors(current_sf)
    next_sf[chosen] = next_sf[chosen] + 1
    let trial = plan_scaled(base.gain, next_sf, quantiser, block_type)
    trials = trials + 1
    if trial.cost <= budget && trial.error < current.error {
      current = trial
      current_sf = next_sf
    } else {
      // Raising this band either overflowed the budget or changed the Huffman
      // table in a way that made the result worse. Do not retry it; try the
      // next-best band with the same budget.
      blocked[chosen] = true
    }
  }
  current
}

///|
/// Unscaled plan, reusing the caller's precomputed powers.
fn plan_unscaled(
  gain : Int32,
  quantiser : GranuleQuantiser,
  block_type : Int32,
) -> GranulePlan {
  let values = quantiser.quantise(gain)
  let scalefactors = if block_type == BlockTypeShort {
    zero_short_scalefactors()
  } else {
    zero_scalefactors()
  }
  plan_from_values(values, gain, scalefactors, quantiser, block_type)
}

///|
/// Smallest gain whose exact bit cost fits `budget`, then per-band refinement.
///
/// Cost falls as the gain rises (coefficients get smaller, then zero), so a
/// binary search over the 8-bit field finds the least coarsening that fits. The
/// search always terminates on a fitting gain because a fully zeroed granule
/// costs 576 bits and every granule's share is larger than that.
///
/// The gain search deliberately runs with all scalefactors zero. Once it has
/// fixed the granule's gross step, `refine_scalefactors` spends whatever
/// headroom is left on the bands where an extra bit buys the most error
/// reduction. That separation keeps the search one-dimensional.
fn plan_with_budget(
  lines : Array[Double],
  budget : Int32,
  block_type : Int32,
) -> GranulePlan {
  let peak = peak_absolute(lines)
  if peak <= 0.0 {
    return plan_granule(lines, 0, block_type)
  }
  let quantiser = GranuleQuantiser::new_typed(lines, block_type)
  // The gain that puts the peak on the top level is the natural starting point,
  // but it is not always the best one: rounding the gain to an integer can leave
  // the loudest lines between levels. Scan a window around it and keep the
  // candidate with the smallest reconstruction error that still fits the budget.
  let centre = global_gain_for_peak(peak, MaxQuantLevel)
  let mut best = plan_unscaled(centre, quantiser, block_type)
  let mut best_error = best.error
  for offset = 0; offset <= 6; offset = offset + 1 {
    if offset == 0 {
      continue
    }
    let gain = centre + offset
    if gain < 0 || gain > 255 {
      continue
    }
    let candidate = plan_unscaled(gain, quantiser, block_type)
    if candidate.cost < 0 || candidate.cost > budget {
      continue
    }
    if candidate.error < best_error {
      best = candidate
      best_error = candidate.error
    }
  }
  if best.cost <= budget {
    return refine_scalefactors(budget, best, quantiser, block_type)
  }
  // Nothing in the window fitted; coarsen until it does. A fully zeroed granule
  // costs 576 bits, which every granule's share exceeds, so this terminates.
  let mut low = centre
  let mut high = 255
  while low < high {
    let mid = (low + high) / 2
    if plan_unscaled(mid, quantiser, block_type).cost <= budget {
      high = mid
    } else {
      low = mid + 1
    }
  }
  let chosen = plan_unscaled(low, quantiser, block_type)
  if chosen.cost <= budget {
    return refine_scalefactors(budget, chosen, quantiser, block_type)
  }
  // The bisection assumes the cost falls monotonically with the gain. That is
  // nearly true but not exactly — a broadband transient can make a mid gain cost
  // more than a coarser one — so walk upward to the first gain that really fits,
  // then fall back to the fully zeroed granule, which no budget can overflow.
  let mut gain = low + 1
  while gain <= 255 {
    let candidate = plan_unscaled(gain, quantiser, block_type)
    if candidate.cost <= budget {
      return refine_scalefactors(budget, candidate, quantiser, block_type)
    }
    gain = gain + 1
  }
  plan_unscaled(255, quantiser, block_type)
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
  headroom : Double,
  block_types : Array[Int32],
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
      let block_type = block_types[(frame * 2 + granule) * channels + channel]
      for index = 0; index < GranulePcm; index = index + 1 {
        let absolute = offset + index
        pcm[index] = if absolute < per_channel {
          samples[absolute * channels + channel].to_double() /
          32768.0 *
          headroom
        } else {
          0.0
        }
      }
      let lines = analysis[channel].granule_block(pcm, block_type) catch {
        (_ : AnalysisError) => raise AnalysisFailed(frame)
      }
      let plan = plan_with_budget(lines, share, block_type)
      if plan.cost > share {
        raise HuffmanFailed(frame)
      }
      let info = if block_type == BlockTypeShort {
        GranuleInfo::short(
          plan.cost,
          plan.big_values,
          plan.gain,
          plan.table,
          plan.scalefac_compress,
        )
      } else if block_type == BlockTypeLong {
        GranuleInfo::scaled(
          plan.cost,
          plan.big_values,
          plan.gain,
          plan.table,
          plan.scalefac_compress,
        )
      } else {
        GranuleInfo::switched_long(
          plan.cost,
          plan.big_values,
          plan.gain,
          plan.table,
          plan.scalefac_compress,
          block_type,
        )
      }
      granules.push(info)
      let scalefactor_bits = if block_type == BlockTypeShort {
        write_short_scalefactors(w, plan.scalefactors, plan.scalefac_compress)
      } else {
        write_scalefactors(w, plan.scalefactors, plan.scalefac_compress)
      }
      let huffman_bits = write_granule(
        w,
        plan.values,
        plan.table,
        plan.big_values,
      ) catch {
        (_ : HuffmanError) => raise HuffmanFailed(frame)
      }
      if scalefactor_bits + huffman_bits != plan.cost {
        raise HuffmanFailed(frame)
      }
      bits = bits + plan.cost
    }
  }
  reservoir.append(w.finish(), bits)
  FramePlan::{ size, padding, start, granules, }
}

///|
/// Headroom shared by every channel and granule of one encode call.
///
/// A small quantisation error can add in phase with a near-full-scale waveform
/// after IMDCT overlap and synthesis, so a stream with an already-correct mean
/// gain can still peak above 1.0. Near full scale, reserve a fixed 11 % of the
/// input's range before analysis; at lower levels the value is exactly 1.0 and
/// ordinary streams are bit-for-bit unchanged. Keeping this constant for the
/// whole call is important: a per-frame switch would itself become audible
/// amplitude modulation and would disturb the stereo balance.
pub fn encode_headroom(samples : Array[Int32]) -> Double {
  let mut peak = 0
  for sample in samples {
    if sample.abs() > peak {
      peak = sample.abs()
    }
  }
  let normalised = peak.to_double() / 32768.0
  let target = 0.87
  if normalised <= target {
    1.0
  } else {
    target / normalised
  }
}

///|
/// Detect transients and lay out a start / short / stop sequence per channel.
///
/// A granule is marked short when its peak energy jumps well above the running
/// average, the classic pre-echo cue. A run of short granules is framed by a
/// start before it and a stop after it, and short runs are padded to at least
/// one granule so a lone transient still gets its start and stop.
fn schedule_block_types(
  samples : Array[Int32],
  channels : Int32,
  nframes : Int32,
) -> Array[Int32] {
  let per_channel = samples.length() / channels
  let ngranules = nframes * 2
  let types = Array::make(ngranules * channels, BlockTypeLong)
  let granule_peak = Array::make(ngranules * channels, 0.0)
  let granule_rms = Array::make(ngranules * channels, 0.0)
  for granule = 0; granule < ngranules; granule = granule + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      let base = granule * GranulePcm
      let mut peak = 0.0
      let mut energy = 0.0
      for index = 0; index < GranulePcm; index = index + 1 {
        let absolute = base + index
        if absolute < per_channel {
          let value = samples[absolute * channels + channel].to_double() /
            32768.0
          if value.abs() > peak {
            peak = value.abs()
          }
          energy = energy + value * value
        }
      }
      let slot = granule * channels + channel
      granule_peak[slot] = peak
      granule_rms[slot] = @math.pow(energy / GranulePcm.to_double(), 0.5)
    }
  }
  for channel = 0; channel < channels; channel = channel + 1 {
    // Running RMS average over the preceding granules decides whether a
    // granule is an onset. The first granule has no history and stays long.
    let mut running = 0.0
    let mut seen = 0
    for granule = 0; granule < ngranules; granule = granule + 1 {
      let slot = granule * channels + channel
      if seen > 0 &&
        granule_rms[slot] > running / seen.to_double() * 3.0 + 0.000001 {
        let start_granule = if granule > 0 { granule - 1 } else { granule }
        types[start_granule * channels + channel] = BlockTypeStart
        types[slot] = BlockTypeShort
        if granule + 1 < ngranules {
          types[(granule + 1) * channels + channel] = BlockTypeStop
        }
        // Absorb the transient energy into the average so a single onset does
        // not mark every following granule as short.
        running = running + granule_rms[slot]
        seen = seen + 1
      }
      running = running + granule_rms[slot]
      seen = seen + 1
    }
  }
  types
}

///|
/// Encode interleaved signed 16-bit PCM as an MPEG-1 Layer III stream.
///
/// Each granule is analysed with the 32-band polyphase filterbank and an MDCT,
/// quantised to the magnitudes MPEG-1 tables can carry and written as a
/// big_values region plus a count1 tail, with per-band scalefactors. The
/// window scheduler may switch a granule to a short or start/stop window.
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
  let headroom = encode_headroom(samples)
  let nframes = (per_channel + FrameSamples - 1) / FrameSamples
  let block_types = schedule_block_types(samples, channels, nframes)
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
      frame, channels, per_channel, samples, headroom, block_types, analysis, pcm,
      sizer, reservoir, area_start,
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
