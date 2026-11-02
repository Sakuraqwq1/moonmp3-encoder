// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The analysis side of the encoder: the 32-band polyphase filterbank of
// ISO/IEC 11172-3 §2.4.3.1 and the 36-point long-block MDCT of §2.4.2.2.
//
// Everything here is double precision and deliberately unoptimised. The
// filterbank is the one place where a sign or an index error still decodes to
// *something* audible, so each stage is checked against an independent Python
// reference (tools/analysis_ref.py) and against the decoder itself; see
// docs/tooling.md.

///|
/// Failures reported by the analysis stages.
pub suberror AnalysisError {
  /// A filterbank step was not fed exactly 32 samples.
  BadStepLength(Int32)
  /// A granule was not fed exactly 576 samples.
  BadGranuleLength(Int32)
  /// A long-block MDCT was not given exactly 36 samples.
  BadBlockLength(Int32)
}

///|
/// Number of subbands produced by the polyphase filterbank.
pub const SubbandCount : Int32 = 32

///|
/// PCM samples consumed per filterbank step: one sample per subband.
pub const StepSamples : Int32 = 32

///|
/// Taps of the prototype window, four per subband.
pub const WindowTaps : Int32 = 512

///|
/// Subband samples per granule: 576 PCM samples / 32 subbands.
pub const LinesPerGranule : Int32 = 18

///|
/// PCM samples in one granule of one channel.
pub const GranulePcm : Int32 = 576

///|
/// Length of a long-block MDCT, in subband samples.
pub const LongBlockSamples : Int32 = 36

///|
/// Frequency lines a long block produces.
pub const LongBlockLines : Int32 = 18

///|
/// Subband samples consumed by one short-window transform.
pub const ShortBlockSamples : Int32 = 12

///|
/// Frequency lines a short-window transform produces.
pub const ShortBlockLines : Int32 = 6

///|
/// MPEG-1 Layer III block types in side information order.
pub const BlockTypeLong : Int32 = 0

///|
pub const BlockTypeStart : Int32 = 1

///|
pub const BlockTypeShort : Int32 = 2

///|
pub const BlockTypeStop : Int32 = 3

///|
/// Sine window of the long block. ISO/IEC 11172-3 §2.4.2.2 uses
/// `sin(pi/36 (n + 0.5))` for the 36-sample long-block window.
pub fn long_block_window(index : Int32) -> Double {
  @math.sin(@math.PI / 36.0 * (index.to_double() + 0.5))
}

///|
/// Sine window of one 12-sample short block.
pub fn short_block_window(index : Int32) -> Double {
  @math.sin(@math.PI / 12.0 * (index.to_double() + 0.5))
}

///|
/// Window of a start block: long rising half, a flat bridge into the short
/// block's first half, then the 6-sample short falling half.
pub fn start_block_window(index : Int32) -> Double {
  if index < 18 {
    long_block_window(index)
  } else if index < 24 {
    1.0
  } else if index < 30 {
    @math.sin(@math.PI / 12.0 * (index.to_double() - 18.0 + 0.5))
  } else {
    0.0
  }
}

///|
/// Window of a stop block, the reverse of a start block.
pub fn stop_block_window(index : Int32) -> Double {
  if index < 6 {
    0.0
  } else if index < 12 {
    @math.sin(@math.PI / 12.0 * (index.to_double() - 6.0 + 0.5))
  } else if index < 18 {
    1.0
  } else {
    long_block_window(index)
  }
}

///|
/// Window selected by a block type.
pub fn block_window(block_type : Int32, index : Int32) -> Double {
  if block_type == BlockTypeStart {
    start_block_window(index)
  } else if block_type == BlockTypeStop {
    stop_block_window(index)
  } else {
    long_block_window(index)
  }
}

///|
/// Filterbank matrix element `(subband, tap)`: `cos((2 subband + 1)(tap - 16)
/// pi / 64)`. Precomputing the 32x64 matrix turns the per-step cost into plain
/// multiplies; without it every step would need 2048 cosines.
///
/// `tap - 16` is not a rewriting of `16 + tap`: the two differ by
/// `(2m + 1) pi / 2`, which is not a multiple of `pi`, so they are different
/// matrices. `16 + tap` is the *synthesis* matrix; using it on the analysis
/// side makes the modulation double-sideband, mirrors every odd subband inside
/// its own band, and leaves the encoder unable to invert the decoder. On white
/// noise through the verified decoder this form reconstructs at 84 dB and the
/// synthesis form at 0.01 dB; see docs/handoff-2026-11-02-night.md.
pub fn matrix_element(subband : Int32, tap : Int32) -> Double {
  @math.cos(
    (2.0 * subband.to_double() + 1.0) *
    (tap.to_double() - 16.0) *
    (@math.PI / 64.0),
  )
}

///|
/// Scale that turns the checked-in `analysis_window` table into the analysis
/// window of ISO/IEC 11172-3 Table C.1.
///
/// `analysis_window` is the *synthesis* table `D`: its peak is 1.144989014, the
/// value at index 256 that `tools/window_table.py` checks against the upstream
/// blob. The analysis coefficients are `C = D / 32` (peak 0.035780907), which is
/// why the window is scaled here instead of the generated table being cut down:
/// the table stays exactly what its provenance check verifies.
const AnalysisWindowScale : Double = 0.03125

///|
/// State of the 32-band polyphase analysis filterbank for one channel.
///
/// The filterbank is a sliding window: it needs the 512 most recent input
/// samples, newest first, and shapes each step out of them. `history` is kept
/// as a plain array and is mutated in place, so the struct itself never has to
/// be reassigned; `step` is the one mutable scalar, and only its parity is read.
pub struct AnalysisFilterbank {
  /// 512 most recent input samples, `history[0]` newest.
  history : Array[Double]
  /// 32x64 matrix of `matrix_element`, row-major by subband.
  matrix : Array[Double]
  /// Steps taken so far; its parity is the Layer III odd-sample sign.
  mut step : Int32
}

///|
/// A filterbank with an empty 512-sample history, ready for the first step.
pub fn AnalysisFilterbank::new() -> AnalysisFilterbank {
  let matrix = Array::make(SubbandCount * 64, 0.0)
  for subband = 0; subband < SubbandCount; subband = subband + 1 {
    for tap = 0; tap < 64; tap = tap + 1 {
      matrix[subband * 64 + tap] = matrix_element(subband, tap)
    }
  }
  AnalysisFilterbank::{
    history: Array::make(WindowTaps, 0.0),
    matrix,
    step: 0,
  }
}

///|
/// Feed one step of 32 PCM samples, oldest first, and return the 32 subband
/// samples that step produces.
///
/// In matrix form the analysis filterbank is
///
/// ```text
/// S[m] = sum(n = 0..511) x[n] C[n] cos((2m + 1)(n mod 64 - 16) pi / 64)
/// ```
///
/// so this windows the 512-sample history, sums the eight 64-sample blocks
/// column by column and applies the 32x64 cosine matrix. ISO 11172-3 reaches
/// the same sum through a mirror-symmetric folding of the windowed samples;
/// that folding is only an optimisation of this sum, and a wrong one produces
/// an encoder that runs, decodes and leaks four decibels into every
/// neighbouring band, so the sum is written out directly here.
///
/// Layer III orientation: a real-valued filterbank samples band `m` with a
/// carrier at the band edge, so the raw sum has the odd bands mirrored inside
/// themselves. The decoder undoes that after its inverse MDCT (minimp3's
/// `L3_change_sign`, ISO 11172-3 §2.4.2.3); the encoder has to apply the same
/// `(-1)^n` to odd bands before the MDCT, or the mirror survives the round trip.
/// Measured through the verified decoder: with the flip 84 dB, without it 1.2
/// dB, so this is load-bearing and not a cosmetic sign convention.
pub fn AnalysisFilterbank::step(
  self : AnalysisFilterbank,
  samples : Array[Double],
) -> Array[Double] raise AnalysisError {
  if samples.length() != StepSamples {
    raise BadStepLength(samples.length())
  }
  let history = self.history
  for index = WindowTaps - 1; index >= StepSamples; index = index - 1 {
    history[index] = history[index - StepSamples]
  }
  for index = 0; index < StepSamples; index = index + 1 {
    history[index] = samples[StepSamples - 1 - index]
  }
  let summed = Array::make(64, 0.0)
  for block = 0; block < 8; block = block + 1 {
    for offset = 0; offset < 64; offset = offset + 1 {
      let index = block * 64 + offset
      summed[offset] = summed[offset] +
        history[index] * analysis_window[index] * AnalysisWindowScale
    }
  }
  let subbands = Array::make(SubbandCount, 0.0)
  for subband = 0; subband < SubbandCount; subband = subband + 1 {
    let mut sum = 0.0
    for offset = 0; offset < 64; offset = offset + 1 {
      sum = sum + summed[offset] * self.matrix[subband * 64 + offset]
    }
    subbands[subband] = sum
  }
  if self.step % 2 == 1 {
    for subband = 1; subband < SubbandCount; subband = subband + 2 {
      subbands[subband] = -subbands[subband]
    }
  }
  self.step = self.step + 1
  subbands
}

///|
/// Long-block MDCT: 36 subband samples in, 18 frequency lines out.
///
/// `X[k] = sum(n = 0..35) x[n] w[n] cos(pi/72 (2n + 19)(2k + 1))` with the
/// 36-point sine window of §2.4.2.2. Line `k` is centred on `(k + 0.5)` times
/// the 38.28125 Hz line spacing of an 1152-sample granule; the same mapping is
/// what docs/line-frequencies.md measures.
pub fn mdct_long(block : Array[Double]) -> Array[Double] raise AnalysisError {
  if block.length() != LongBlockSamples {
    raise BadBlockLength(block.length())
  }
  let windowed = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < LongBlockSamples; index = index + 1 {
    windowed[index] = block[index] * long_block_window(index)
  }
  let lines = Array::make(LongBlockLines, 0.0)
  for line = 0; line < LongBlockLines; line = line + 1 {
    let mut sum = 0.0
    for index = 0; index < LongBlockSamples; index = index + 1 {
      sum = sum +
        windowed[index] *
        @math.cos(
          @math.PI /
          72.0 *
          (2.0 * index.to_double() + 19.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    lines[line] = sum
  }
  lines
}

///|
/// One 36->18 transform with the window of a long, start or stop block.
pub fn mdct_switched_long(
  block : Array[Double],
  block_type : Int32,
) -> Array[Double] raise AnalysisError {
  if block.length() != LongBlockSamples {
    raise BadBlockLength(block.length())
  }
  if block_type == BlockTypeShort {
    raise BadBlockLength(block.length())
  }
  let windowed = Array::make(LongBlockSamples, 0.0)
  for index = 0; index < LongBlockSamples; index = index + 1 {
    windowed[index] = block[index] * block_window(block_type, index)
  }
  let lines = Array::make(LongBlockLines, 0.0)
  for line = 0; line < LongBlockLines; line = line + 1 {
    let mut sum = 0.0
    for index = 0; index < LongBlockSamples; index = index + 1 {
      sum = sum +
        windowed[index] *
        @math.cos(
          @math.PI /
          72.0 *
          (2.0 * index.to_double() + 19.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    lines[line] = sum
  }
  lines
}

///|
/// Short-block MDCT: 12 subband samples in, six frequency lines out.
///
/// The transform is the same DCT-IV with N=12. In one 36-sample block the
/// three windows start at offsets 6, 12 and 18, which is what lets a start
/// window's last six samples overlap the first short window and a stop window's
/// first six samples overlap the last one.
pub fn mdct_short(block : Array[Double]) -> Array[Double] raise AnalysisError {
  if block.length() != ShortBlockSamples {
    raise BadBlockLength(block.length())
  }
  let windowed = Array::make(ShortBlockSamples, 0.0)
  for index = 0; index < ShortBlockSamples; index = index + 1 {
    windowed[index] = block[index] * short_block_window(index)
  }
  let lines = Array::make(ShortBlockLines, 0.0)
  for line = 0; line < ShortBlockLines; line = line + 1 {
    let mut sum = 0.0
    for index = 0; index < ShortBlockSamples; index = index + 1 {
      sum = sum +
        windowed[index] *
        @math.cos(
          @math.PI /
          24.0 *
          (2.0 * index.to_double() + 7.0) *
          (2.0 * line.to_double() + 1.0),
        )
    }
    lines[line] = sum
  }
  lines
}

///|
/// Gain the decoder's synthesis applies to the lines an encoder writes.
///
/// The decoder's inverse MDCT is the untransposed kernel of `mdct_long`, and
/// overlap-adding consecutive blocks scales a subband sample by `36 / 4 = 9`
/// (the `N / 4` of a sine-windowed MDCT pair). The synthesis filterbank itself is
/// unity gain for the subband stream it is given, so a line coefficient of 1.0
/// comes back as a 9 times larger sample stream.
///
/// Dividing the analysis output by that is what puts the encoder's lines on the
/// scale of the `xr` values §2.4.2.7 requantises, and it is why one unit
/// coefficient at `global_gain = 210` decodes to a peak near 1.0. Measured on
/// white noise against the verified decoder (`tools/decoder_ref.py --score
/// --noise`): the fitted gain is 1.00000 at 84 dB with this constant, and 32
/// times off without it, because the analysis window is `D / 32` (Table C.1)
/// while the lines have to land in the synthesis units of Table D.
pub const SynthesisGain : Double = 9.0

///|
/// Synthesis gain of the 12-sample short transform: `N / 4 = 3`.
pub const ShortSynthesisGain : Double = 3.0

///|
/// One channel of long-block analysis: the filterbank plus the 18 subband
/// samples per subband that the previous granule leaves behind, which is the
/// first half of the next granule's MDCT input.
pub struct ChannelAnalysis {
  filterbank : AnalysisFilterbank
  /// 32 subbands x 18 samples, subband-major, from the previous granule.
  carry : Array[Double]
}

///|
/// A channel analyser positioned at the start of a stream, with zero history.
pub fn ChannelAnalysis::new() -> ChannelAnalysis {
  ChannelAnalysis::{
    filterbank: AnalysisFilterbank::new(),
    carry: Array::make(SubbandCount * LinesPerGranule, 0.0),
  }
}

///|
/// Turn 576 PCM samples, in the same -1..1 scale the decoder produces, into the
/// 576 frequency lines of one granule, ordered subband-major for long blocks.
///
/// The 18 samples of the previous granule are prepended, so consecutive
/// granules overlap by half a block exactly as §2.4.2.2 requires. The result is
/// divided by the transform's synthesis gain, so the lines are already in the
/// units the decoder's requantisation expects. For a pure short block the result
/// is already in the `[sfb][window][line]` order Huffman coding requires; for
/// long/start/stop blocks it is the usual frequency order and receives the
/// decoder's antialias pre-compensation.
pub fn ChannelAnalysis::granule_block(
  self : ChannelAnalysis,
  pcm : Array[Double],
  block_type : Int32,
) -> Array[Double] raise AnalysisError {
  if pcm.length() != GranulePcm {
    raise BadGranuleLength(pcm.length())
  }
  let fresh = Array::make(SubbandCount * LinesPerGranule, 0.0)
  let hop = Array::make(StepSamples, 0.0)
  for step = 0; step < LinesPerGranule; step = step + 1 {
    for index = 0; index < StepSamples; index = index + 1 {
      hop[index] = pcm[step * StepSamples + index]
    }
    let subbands = self.filterbank.step(hop)
    for subband = 0; subband < SubbandCount; subband = subband + 1 {
      fresh[subband * LinesPerGranule + step] = subbands[subband]
    }
  }
  let block = Array::make(LongBlockSamples, 0.0)
  let lines = Array::make(576, 0.0)
  for subband = 0; subband < SubbandCount; subband = subband + 1 {
    for index = 0; index < LinesPerGranule; index = index + 1 {
      block[index] = self.carry[subband * LinesPerGranule + index]
      block[index + LinesPerGranule] = fresh[subband * LinesPerGranule + index]
    }
    if block_type == BlockTypeShort {
      let window_block = Array::make(ShortBlockSamples, 0.0)
      for window = 0; window < 3; window = window + 1 {
        for index = 0; index < ShortBlockSamples; index = index + 1 {
          window_block[index] = block[6 + window * 6 + index]
        }
        let spectrum = mdct_short(window_block)
        for line = 0; line < ShortBlockLines; line = line + 1 {
          lines[short_huffman_index(subband, window, line)] = spectrum[line] /
            ShortSynthesisGain
        }
      }
    } else {
      let spectrum = mdct_switched_long(block, block_type)
      for line = 0; line < LongBlockLines; line = line + 1 {
        lines[subband * LongBlockLines + line] = spectrum[line] / SynthesisGain
      }
    }
  }
  if block_type != BlockTypeShort {
    antialias_compensation(lines)
  }
  for index = 0; index < fresh.length(); index = index + 1 {
    self.carry[index] = fresh[index]
  }
  lines
}

///|
/// Long-block granule analysis; kept as the stable entry point for callers and
/// tests that do not schedule window switching.
pub fn ChannelAnalysis::granule(
  self : ChannelAnalysis,
  pcm : Array[Double],
) -> Array[Double] raise AnalysisError {
  self.granule_block(pcm, BlockTypeLong)
}

///|
/// Largest absolute value in a line buffer.
pub fn peak_absolute(values : Array[Double]) -> Double {
  let mut peak = 0.0
  for value in values {
    let magnitude = value.abs()
    if magnitude > peak {
      peak = magnitude
    }
  }
  peak
}

///|
/// ISO/IEC 11172-3 Table B.9: the cosine and sine of the eight antialias
/// rotations the decoder applies to the boundary lines of adjacent subbands.
let antialias_cosine : Array[Double] = [
  0.857493, 0.881742, 0.949629, 0.983315, 0.995518, 0.999161, 0.999899, 0.999993,
]

///|
/// ISO/IEC 11172-3 Table B.9: the sine terms of the same eight rotations.
let antialias_sine : Array[Double] = [
  -0.514496, -0.471732, -0.313377, -0.181913, -0.094574, -0.040966, -0.014199, -0.003700,
]

///|
/// Inverse of the decoder's antialias stage, applied to the lines of one granule.
///
/// Before its inverse MDCT, the decoder rotates the top eight lines of every
/// subband together with the bottom eight of the next one (§2.4.2.3, the
/// "antialias" butterflies of Table B.9). That stage is normative, so every
/// decoder applies it; an analysis that produces the decoder's subband stream
/// exactly, and therefore its lines exactly, would have those lines rotated on
/// the way out and lose the band boundaries. The encoder's job is the inverse
/// rotation, which is the transpose here because each butterfly is orthogonal.
///
/// This one is easy to forget because it is invisible in the subband domain.
/// Measured through the verified decoder on white noise with no quantisation:
/// without this stage 11.55 dB, with it 84.47 dB, at the same 1057-sample delay
/// and the same fitted gain of 1.00000 — the whole difference is the band edges,
/// which is why a filterbank that scores 84 dB at 440 Hz can still score 11 dB
/// against the real decoder.
fn antialias_compensation(lines : Array[Double]) -> Unit {
  for subband = 1; subband < SubbandCount; subband = subband + 1 {
    for index = 0; index < 8; index = index + 1 {
      let lower = 18 * subband - 1 - index
      let upper = 18 * subband + index
      let below = lines[lower]
      let above = lines[upper]
      lines[lower] = below * antialias_cosine[index] +
        above * antialias_sine[index]
      lines[upper] = above * antialias_cosine[index] -
        below * antialias_sine[index]
    }
  }
}
