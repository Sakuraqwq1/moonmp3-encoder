// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// The CLI exists so the encoder can be exercised on any machine without a
// file system binding: payloads travel as base64, the way the surrounding
// MoonBit audio tooling does it.

///|
fn main {
  let args = @env.args()
  let command = if args.length() > 1 { args[1] } else { "selftest" }
  if command == "selftest" {
    run_selftest()
  } else if command == "silent" {
    run_silent(args)
  } else if command == "tone" {
    run_tone(args)
  } else if command == "sine" {
    run_sine(args)
  } else if command == "encode" {
    run_encode(args)
  } else if command == "lines" {
    run_lines(args)
  } else if command == "version" {
    println(@encoder.version())
  } else {
    println("unknown command")
    println("  selftest   emit one second of silence, print the MP3 as base64")
    println("  silent     emit n samples of silence, print the MP3 as base64")
    println(
      "  sine       encode a generated sine (frames freqs amp_pct channels)",
    )
    println(
      "  encode     encode interleaved int16 PCM given as base64 (pcm channels)",
    )
    println("  lines      debug: dump one granule's 576 analysis lines")
    println(
      "  tone       debug: fixed count1 spectrum (frames lines gain channels)",
    )
    println("  version    print the module version")
  }
}

///|
/// Self check: one second of stereo silence at 44.1 kHz, encoded and printed.
/// The decoder-side verification lives in tools/verify.py.
fn run_selftest() -> Unit {
  let rate = 44100
  let channels = 2
  let samples = Array::make(rate * channels, 0)
  let mp3 = @encoder.encode(samples, rate, channels) catch {
    (_ : @mp3.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println("rate=\{rate} channels=\{channels} samples=\{rate}")
  println("bytes=\{mp3.length()}")
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
}

///|
/// Emit `n` samples per channel of digital silence. The verification harness
/// uses this until real audio coding lands: what it checks today is that the
/// frame grid is exact and the stream decodes to the right length.
fn run_silent(args : Array[String]) -> Unit {
  let count = parse_count(args, 2, 44100)
  let channels = parse_count(args, 3, 1)
  if channels != 1 && channels != 2 {
    println("ERROR: channels must be 1 or 2")
    return
  }
  let samples = Array::make(count * channels, 0)
  let mp3 = @encoder.encode(samples, 44100, channels) catch {
    (_ : @mp3.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println("rate=44100 channels=\{channels} samples=\{count}")
  println("bytes=\{mp3.length()}")
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
}

///|
/// Emit a fixed-spectrum count1 stream for bitstream debugging. This is not
/// the PCM encoder; it exists so the main-data path can be tested on its own.
fn run_tone(args : Array[String]) -> Unit {
  let frames = parse_count(args, 2, 4)
  let lines = parse_lines(args, 3, "12")
  if lines.is_empty() {
    println("ERROR: no spectral line selected")
    return
  }
  for line in lines {
    if line < 0 || line >= 576 {
      println("ERROR: line must be in 0..575")
      return
    }
  }
  let gain = parse_count(args, 4, 210)
  let channels = parse_count(args, 5, 1)
  let spectrum = Array::make(576, 0)
  for line in lines {
    spectrum[line] = 1
  }
  let mp3 = @mp3.encode_count1_spectrum(frames, channels, spectrum, gain) catch {
    (_ : @mp3.Count1Error) => {
      println("ERROR: tone encode failed")
      return
    }
  }
  println(
    "rate=44100 channels=\{channels} samples=\{frames * 1152} lines=\{format_lines(lines)} gain=\{gain}",
  )
  println("bytes=\{mp3.length()}")
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
}

///|
/// Generate and encode a sine, so the whole PCM path can be exercised without
/// shipping a payload through the command line. `freqs` is a comma-separated
/// list: `sine 16 440 50 1` is a mono 440 Hz tone at half scale, and
/// `sine 16 440,660 50 2` puts 440 Hz on the left and 660 Hz on the right.
fn run_sine(args : Array[String]) -> Unit {
  let frames = parse_count(args, 2, 16)
  let freqs = parse_lines(args, 3, "440")
  let amplitude = parse_count(args, 4, 50)
  let channels = parse_count(args, 5, 1)
  if freqs.is_empty() {
    println("ERROR: no frequency given")
    return
  }
  if amplitude < 0 || amplitude > 100 {
    println("ERROR: amplitude is a percentage in 0..100")
    return
  }
  let count = frames * 1152
  let samples = Array::make(count * channels, 0)
  let scale = amplitude.to_double() / 100.0 * 32767.0
  for index = 0; index < count; index = index + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      let frequency = freqs[if channel < freqs.length() {
          channel
        } else {
          freqs.length() - 1
        }]
      let phase = 2.0 *
        @math.PI *
        frequency.to_double() *
        index.to_double() /
        44100.0
      samples[index * channels + channel] = (scale * @math.sin(phase))
        .round()
        .to_int()
    }
  }
  let mp3 = @encoder.encode(samples, 44100, channels) catch {
    (_ : @mp3.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println(
    "rate=44100 channels=\{channels} samples=\{count} freqs=\{format_lines(freqs)} amplitude=\{amplitude}",
  )
  println("bytes=\{mp3.length()}")
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
}

///|
/// Encode interleaved little-endian int16 PCM supplied as base64.
///
/// The command line caps the payload at roughly 0.2 s of mono audio, which is
/// enough to check frequency and channel routing; `sine` exists for anything
/// longer because it needs no payload at all.
fn run_encode(args : Array[String]) -> Unit {
  if args.length() < 3 {
    println("ERROR: encode needs a base64 PCM payload")
    return
  }
  let channels = parse_count(args, 3, 1)
  if channels != 1 && channels != 2 {
    println("ERROR: channels must be 1 or 2")
    return
  }
  let payload = @base64.decode(args[2][:]) catch {
    (_ : @base64.Malformed) => {
      println("ERROR: payload is not valid base64")
      return
    }
  }
  if payload.length() % (2 * channels) != 0 {
    println("ERROR: payload is not a whole number of interleaved samples")
    return
  }
  let count = payload.length() / 2
  let samples = Array::make(count, 0)
  for index = 0; index < count; index = index + 1 {
    let low = payload[index * 2].to_int()
    let high = payload[index * 2 + 1].to_int()
    let value = low | (high << 8)
    samples[index] = if value >= 32768 { value - 65536 } else { value }
  }
  let mp3 = @encoder.encode(samples, 44100, channels) catch {
    (_ : @mp3.EncodeError) => {
      println("ERROR: encode failed")
      return
    }
  }
  println(
    "rate=44100 channels=\{channels} samples=\{count / channels} bytes=\{mp3.length()}",
  )
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
}

///|
/// Generate `count` interleaved samples of a sine at `amplitude` (a 0..1 scale),
/// repeating the frequency list across the channels.
fn sine_samples(
  freqs : Array[Int32],
  amplitude : Double,
  channels : Int32,
  count : Int32,
) -> Array[Int32] {
  let samples = Array::make(count * channels, 0)
  let scale = amplitude * 32767.0
  for index = 0; index < count; index = index + 1 {
    for channel = 0; channel < channels; channel = channel + 1 {
      let frequency = freqs[if channel < freqs.length() {
          channel
        } else {
          freqs.length() - 1
        }]
      let phase = 2.0 *
        @math.PI *
        frequency.to_double() *
        index.to_double() /
        44100.0
      samples[index * channels + channel] = (scale * @math.sin(phase))
        .round()
        .to_int()
    }
  }
  samples
}

///|
/// Debug: dump the 576 frequency lines of one granule of a generated sine.
///
/// This is the numerical reference hook for tools/analysis_ref.py: the Python
/// side recomputes the same filterbank and MDCT independently and compares the
/// values one by one. `lines <freq> <amp_pct> <frames> <granule> <channel>`.
fn run_lines(args : Array[String]) -> Unit {
  let freq = parse_count(args, 2, 440)
  let amplitude = parse_count(args, 3, 50)
  let frames = parse_count(args, 4, 3)
  let target = parse_count(args, 5, 4)
  let channel = parse_count(args, 6, 0)
  if frames < 1 || target < 0 || target >= frames * 2 {
    println("ERROR: granule out of range")
    return
  }
  let count = frames * 1152
  let samples = sine_samples([freq], amplitude.to_double() / 100.0, 1, count)
  let analyser = @mp3.ChannelAnalysis::new()
  let pcm = Array::make(576, 0.0)
  let mut lines : Array[Double] = []
  for granule = 0; granule <= target; granule = granule + 1 {
    for index = 0; index < 576; index = index + 1 {
      pcm[index] = samples[granule * 576 + index].to_double() / 32768.0
    }
    lines = analyser.granule(pcm) catch {
      (_ : @mp3.AnalysisError) => {
        println("ERROR: analysis failed")
        return
      }
    }
  }
  let _ = channel
  println("granule=\{target} freq=\{freq} amplitude=\{amplitude} lines=576")
  let rendered : Array[String] = []
  for value in lines {
    rendered.push(value.to_string())
  }
  println("LINESBEGIN")
  println(rendered.join(","))
}

///|
/// Read `args[index]` as a comma-separated list of spectral line indices, or
/// `fallback` when absent. `tone 4 12 210 1` and `tone 4 12,13 210 1` are both
/// accepted; the two-line form is what the frequency probe needs to resolve
/// neighbouring MDCT bins.
fn parse_lines(
  args : Array[String],
  index : Int32,
  fallback : String,
) -> Array[Int32] {
  let text = if index < args.length() { args[index] } else { fallback }
  let out : Array[Int32] = []
  for part in text.split(",") {
    if part.is_empty() {
      continue
    }
    let value = @string.parse_int(part) catch { (_ : Error) => -1 }
    out.push(value)
  }
  out
}

///|
/// Render a line list back into its comma-separated form for the echo line.
fn format_lines(lines : Array[Int32]) -> String {
  lines.map(fn(line) { line.to_string() }).join(",")
}

///|
/// Read `args[index]` as a non-negative integer, or `fallback` when absent.
fn parse_count(args : Array[String], index : Int32, fallback : Int32) -> Int32 {
  if index >= args.length() {
    return fallback
  }
  @string.parse_int(args[index]) catch {
    (_ : Error) => fallback
  }
}
