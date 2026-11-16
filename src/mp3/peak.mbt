// moonmp3-encoder — pure MoonBit MP3 encoder.
// SPDX-License-Identifier: Apache-2.0

// Measure how the selected quantised coefficients reconstruct before emitting
// side information. This operates on encoder plans, without parsing MP3 data.

///|
priv struct PeakMonitor {
  overlap : Array[Double]
  history : Array[Double]
  mut history_start : Int32
  mut peak : Double
}

///|
fn PeakMonitor::new() -> PeakMonitor {
  {
    overlap: Array::make(GranulePcm, 0.0),
    history: Array::make(1024, 0.0),
    history_start: 0,
    peak: 0.0,
  }
}

///|
let synthesis_matrix : Array[Double] = {
  let matrix = Array::make(64 * SubbandCount, 0.0)
  for row = 0; row < 64; row = row + 1 {
    for band = 0; band < SubbandCount; band = band + 1 {
      matrix[row * SubbandCount + band] = @math.cos(
        @math.PI / 64.0 * (16 + row).to_double() * (2 * band + 1).to_double(),
      )
    }
  }
  matrix
}

///|
fn reconstructed_lines(plan : GranulePlan, short : Bool) -> Array[Double] {
  let gain = @math.pow(2.0, (plan.gain.to_double() - 210.0) / 4.0)
  let scales = plan.scalefactors.map(sf => {
    gain * @math.pow(2.0, -0.5 * sf.to_double())
  })
  let lines = Array::make(GranulePcm, 0.0)
  for index = 0; index < GranulePcm; index = index + 1 {
    let field = if short {
      short_scalefactor_of_line(index)
    } else {
      scalefactor_band_of_line(index)
    }
    let scale = if field < scales.length() { scales[field] } else { gain }
    let value = plan.values[index]
    let magnitude = dequant_levels[value.abs()] * scale
    lines[index] = if value < 0 { -magnitude } else { magnitude }
  }
  lines
}

///|
fn PeakMonitor::observe(
  self : PeakMonitor,
  plan : GranulePlan,
  block_type : Int32,
) -> Unit {
  let short = block_type == BlockTypeShort
  let lines = reconstructed_lines(plan, short)
  if !short {
    for band = 1; band < SubbandCount; band = band + 1 {
      for i = 0; i < 8; i = i + 1 {
        let lo = band * LongBlockLines - 1 - i
        let hi = band * LongBlockLines + i
        let below = lines[lo]
        let above = lines[hi]
        lines[lo] = below * antialias_cosine[i] - above * antialias_sine[i]
        lines[hi] = above * antialias_cosine[i] + below * antialias_sine[i]
      }
    }
  }
  let subbands = Array::make(GranulePcm, 0.0)
  let block = Array::make(LongBlockSamples, 0.0)
  for band = 0; band < SubbandCount; band = band + 1 {
    block.fill(0.0)
    if short {
      for window = 0; window < 3; window = window + 1 {
        for line = 0; line < ShortBlockLines; line = line + 1 {
          let value = lines[short_huffman_index(band, window, line)]
          for i = 0; i < ShortBlockSamples; i = i + 1 {
            let position = 6 + window * 6 + i
            block[position] = block[position] +
              value *
              short_mdct_cosines[line * ShortBlockSamples + i] *
              short_window[i]
          }
        }
      }
    } else {
      for i = 0; i < LongBlockSamples; i = i + 1 {
        let mut sum = 0.0
        for line = 0; line < LongBlockLines; line = line + 1 {
          sum = sum +
            lines[band * LongBlockLines + line] *
            long_mdct_cosines[line * LongBlockSamples + i]
        }
        block[i] = sum * block_windows[block_type * LongBlockSamples + i]
      }
    }
    for i = 0; i < LongBlockLines; i = i + 1 {
      let index = band * LongBlockLines + i
      let sample = block[i] + self.overlap[index]
      subbands[index] = if band % 2 != 0 && i % 2 != 0 {
        -sample
      } else {
        sample
      }
      self.overlap[index] = block[LongBlockLines + i]
    }
  }
  for time = 0; time < LongBlockLines; time = time + 1 {
    self.synthesis_step(subbands, time)
  }
}

///|
fn PeakMonitor::synthesis_step(
  self : PeakMonitor,
  subbands : Array[Double],
  time : Int32,
) -> Unit {
  // A ring replaces the 960-sample history shift at every filterbank step.
  let start = (self.history_start + 960) & 1023
  self.history_start = start
  for row = 0; row < 64; row = row + 1 {
    let mut sum = 0.0
    for band = 0; band < SubbandCount; band = band + 1 {
      sum = sum +
        synthesis_matrix[row * SubbandCount + band] *
        subbands[band * LongBlockLines + time]
    }
    self.history[start + row] = sum
  }
  for sample = 0; sample < StepSamples; sample = sample + 1 {
    let mut sum = 0.0
    for row = 0; row < 16; row = row + 1 {
      let tap = row / 2 * 128 + row % 2 * 96 + sample
      sum = sum +
        self.history[(start + tap) & 1023] *
        analysis_window[row * StepSamples + sample]
    }
    self.peak = self.peak.max(sum.abs())
  }
}
