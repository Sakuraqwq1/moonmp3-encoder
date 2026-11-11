// moonmp3-encoder — pure MoonBit MP3 encoder.
// Copyright 2026 Sakuraqwq1
// Licensed under the Apache License, Version 2.0.

// Count1 table A of ISO/IEC 11172-3 Table B.7, packed as
// `(length << 16) | code`. The symbol is the four-bit non-zero mask in
// coefficient order. Symbol zero is the one-bit code `1` used to terminate the
// remaining all-zero tail.
//
// Source: hajimehoshi/go-mp3, internal/huffman/huffman.go, decoder table 32.
//   git blob  abc30058a5cb0e8a75ea40aed2aa88dd02f2c96e
//   file      sha256 6ffbac45b10aabb6cd1a5e37736743ec84ddb8c145fbdd22b2638f1a66cb6b1d
//   licence   Apache License 2.0
// The decoder-side binary tree was expanded by tools/huffman_tables.py. Its
// complete-prefix-code checks cover all 16 symbols, code collisions and a Kraft
// sum of exactly 1; the white-box tests repeat those checks on this array.

///|
/// `(length << 16) | code` for each four-coefficient non-zero mask.
let count1_table_a : Array[Int32] = [
  65537, 262149, 262148, 327685, 262150, 393221, 327684, 393220, 262151, 327683,
  327686, 393216, 327687, 393218, 393219, 393217,
]
