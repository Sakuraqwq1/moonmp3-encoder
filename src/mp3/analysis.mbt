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
/// Sine window of the long block. ISO/IEC 11172-3 §2.4.2.2 uses
/// `sin(pi/36 (n + 0.5))` for the 36-sample long-block window.
pub fn long_block_window(index : Int32) -> Double {
  @math.sin(@math.PI / 36.0 * (index.to_double() + 0.5))
}

///|
/// Filterbank matrix element `(subband, tap)`: `cos((16 + tap)(2 subband + 1)
/// pi / 64)`. Precomputing the 32x64 matrix turns the per-step cost into plain
/// multiplies; without it every step would need 2048 cosines.
pub fn matrix_element(subband : Int32, tap : Int32) -> Double {
  @math.cos(
    (16.0 + tap.to_double()) *
    (2.0 * subband.to_double() + 1.0) *
    (@math.PI / 64.0),
  )
}

///|
/// State of the 32-band polyphase analysis filterbank for one channel.
///
/// The filterbank is a sliding window: it needs the 512 most recent input
/// samples, newest first, and shapes each step out of them. `history` is kept
/// as a plain array and is mutated in place, so the struct itself never has to
/// be reassigned.
pub struct AnalysisFilterbank {
  /// 512 most recent input samples, `history[0]` newest.
  history : Array[Double]
  /// 32x64 matrix of `matrix_element`, row-major by subband.
  matrix : Array[Double]
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
  AnalysisFilterbank::{ history: Array::make(WindowTaps, 0.0), matrix, }
}

///|
/// Feed one step of 32 PCM samples, oldest first, and return the 32 subband
/// samples that step produces.
///
/// In matrix form the analysis filterbank is
///
/// ```text
/// S[m] = sum(n = 0..511) x[n] C[n] cos((16 + n mod 64)(2m + 1) pi / 64)
/// ```
///
/// so this windows the 512-sample history, sums the eight 64-sample blocks
/// column by column and applies the 32x64 cosine matrix. ISO 11172-3 reaches
/// the same sum through a mirror-symmetric folding of the windowed samples;
/// that folding is only an optimisation of this sum, and a wrong one produces
/// an encoder that runs, decodes and leaks four decibels into every
/// neighbouring band, so the sum is written out directly here.
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
      summed[offset] = summed[offset] + history[index] * analysis_window[index]
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
/// Gain the decoder's synthesis applies to the lines an encoder writes.
///
/// The untransposed inverse MDCT sums 18 cosine terms, which scales a block by
/// `18 / 2 = 9`, and the synthesis filterbank oversamples each subband by 32, so
/// a coefficient of 1.0 anywhere in the spectrum comes back as a 288 times
/// larger sample stream. Dividing the analysis output by that is what puts the
/// encoder's lines on the same scale as the `xr` values §2.4.2.7 requantises, and
/// it is why one unit coefficient at `global_gain = 210` decodes to a peak of
/// about 1.0. Measured against libsndfile over 100 Hz..8 kHz, the ratio of
/// decoded RMS to input RMS is 294.7..301.2 for the count1 slice, i.e. within
/// 3 % of this constant; the remaining spread is the one-bit quantiser's, not
/// the filterbank's.
pub const SynthesisGain : Double = 288.0

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
/// 576 frequency lines of one granule, ordered subband-major: line
/// `18 * subband + k` is the `k`-th MDCT line of `subband`.
///
/// The 18 samples of the previous granule are prepended, so consecutive
/// granules overlap by half a block exactly as §2.4.2.2 requires. The result is
/// divided by `SynthesisGain`, so the lines are already in the units the
/// decoder's requantisation expects.
pub fn ChannelAnalysis::granule(
  self : ChannelAnalysis,
  pcm : Array[Double],
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
  let lines = Array::make(SubbandCount * LongBlockLines, 0.0)
  for subband = 0; subband < SubbandCount; subband = subband + 1 {
    for index = 0; index < LinesPerGranule; index = index + 1 {
      block[index] = self.carry[subband * LinesPerGranule + index]
      block[index + LinesPerGranule] = fresh[subband * LinesPerGranule + index]
    }
    let spectrum = mdct_long(block)
    for line = 0; line < LongBlockLines; line = line + 1 {
      lines[subband * LongBlockLines + line] = odd_band_value(
          spectrum, subband, line,
        ) /
        SynthesisGain
    }
  }
  for index = 0; index < fresh.length(); index = index + 1 {
    self.carry[index] = fresh[index]
  }
  lines
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
/// One output line of a subband, after the pseudo-QMF reversal fix-up.
///
/// The analysis filterbank is a pseudo-QMF: every odd subband comes out
/// spectrally reversed inside its band. A 440 Hz tone in subband 0 lands where
/// it belongs, but the same tone in subband 1 lands at bin 10 instead of 8, and
/// 8000 Hz in subband 11 lands at bin 7 instead of 11. Real encoders inherit the
/// right orientation from the folding form of the filterbank; with the direct
/// sum it has to be undone explicitly.
///
/// The map is measured, not reasoned: `tools/odd_band.py` installs each
/// candidate, re-encodes a 1000 Hz and an 8000 Hz tone (both odd subbands) and
/// scores them against the decoder. A plain reversal wins; adding the half-bin
/// sign alternation that the reversed modulation seems to suggest still decodes
/// at the right frequency but drops the waveform from 16 dB to -1.5 dB, because
/// the alternation rotates the phase by half a line. Measured on 2026-11-02:
/// identity -2.8 dB, reverse + half-bin -1.7 dB, plain reversal +16.0 dB.
fn odd_band_value(
  spectrum : Array[Double],
  subband : Int32,
  line : Int32,
) -> Double {
  if subband % 2 == 0 {
    return spectrum[line]
  }
  spectrum[17 - line]
}
