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
  } else if command == "version" {
    println(@encoder.version())
  } else {
    println("unknown command")
    println("  selftest   emit one second of silence, print the MP3 as base64")
    println("  silent     emit n samples of silence, print the MP3 as base64")
    println(
      "  tone       debug: fixed count1 spectrum (frames line gain channels)",
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
  let line = parse_count(args, 3, 12)
  let gain = parse_count(args, 4, 210)
  let channels = parse_count(args, 5, 1)
  if line < 0 || line >= 576 {
    println("ERROR: line must be in 0..575")
    return
  }
  let spectrum = Array::make(576, 0)
  spectrum[line] = 1
  let mp3 = @mp3.encode_count1_spectrum(frames, channels, spectrum, gain) catch {
    (_ : @mp3.Count1Error) => {
      println("ERROR: tone encode failed")
      return
    }
  }
  println(
    "rate=44100 channels=\{channels} samples=\{frames * 1152} line=\{line} gain=\{gain}",
  )
  println("bytes=\{mp3.length()}")
  println("MP3BEGIN")
  println(@base64.encode(mp3[:]))
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
