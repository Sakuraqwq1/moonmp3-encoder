#!/usr/bin/env python3
"""Self-tests for the Python-side encoder lab.

These tests cover the tools, not the encoder: fixture generation, frame
parsing, strict-mode warning behaviour, and SNR delay alignment. They are
fast, use only synthetic audio, and never require a LAME reference file.

Run:
    python tools/selftest.py
"""

from __future__ import annotations

import hashlib
import io
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest

import numpy as np

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import gen_fixtures
import check_release
import mp3dump
import mp3lab
import snr
import spectrum


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moonmp3-fixtures-")
        cls.first = os.path.join(cls.tmp.name, "one")
        cls.second = os.path.join(cls.tmp.name, "two")
        cls.manifest = gen_fixtures.build(cls.first, gen_fixtures.SEED)
        gen_fixtures.build(cls.second, gen_fixtures.SEED)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_expected_fixture_set(self):
        names = [entry["name"] for entry in self.manifest["fixtures"]]
        self.assertEqual(len(names), 10)
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("sine440_mono_1s", names)
        self.assertIn("impulse_stereo_500ms", names)
        for entry in self.manifest["fixtures"]:
            self.assertTrue(os.path.isfile(os.path.join(self.first, entry["wav"])))
            self.assertTrue(os.path.isfile(os.path.join(self.first, entry["pcm"])))
            self.assertGreater(entry["frames"], 0)
            self.assertGreater(entry["channels"], 0)

    def test_generation_is_deterministic(self):
        with open(os.path.join(self.first, "manifest.json"), "rb") as handle:
            first = handle.read()
        with open(os.path.join(self.second, "manifest.json"), "rb") as handle:
            second = handle.read()
        self.assertEqual(first, second)
        self.assertEqual(
            hashlib.sha256(first).hexdigest(),
            hashlib.sha256(second).hexdigest(),
        )

    def test_pcm_matches_wav(self):
        entry = next(e for e in self.manifest["fixtures"] if e["name"] == "sine440_mono_1s")
        import soundfile as sf

        wav, _ = sf.read(os.path.join(self.first, entry["wav"]), always_2d=True, dtype="int16")
        raw = np.fromfile(os.path.join(self.first, entry["pcm"]), dtype="<i2")
        self.assertEqual(raw.tobytes(), wav.reshape(-1).tobytes())


class Mp3DumpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moonmp3-dump-")
        cls.stereo = mp3lab.encode_silence(44100, 2)
        cls.mono = mp3lab.encode_silence(4096, 1)
        cls.stereo_path = os.path.join(cls.tmp.name, "stereo.mp3")
        cls.mono_path = os.path.join(cls.tmp.name, "mono.mp3")
        with open(cls.stereo_path, "wb") as handle:
            handle.write(cls.stereo)
        with open(cls.mono_path, "wb") as handle:
            handle.write(cls.mono)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_stereo_frame_grid(self):
        report = mp3dump.analyze(self.stereo_path)
        self.assertEqual(report["warnings"], [])
        self.assertEqual(report["summary"]["frames"], 39)
        self.assertEqual(report["summary"]["bytes"], 16300)
        self.assertTrue(report["summary"]["constant_bitrate"])
        self.assertEqual(report["summary"]["bitrates"], [128000])
        self.assertEqual(report["summary"]["channels"], [2])
        self.assertEqual(report["frames"][0]["header"]["size"], 417)
        self.assertEqual(report["frames"][1]["header"]["size"], 418)
        self.assertEqual(report["frames"][0]["header"]["side_size"], 32)
        self.assertEqual(report["frames"][0]["side_info"]["main_data_begin"], 0)

    def test_mono_frame_grid(self):
        report = mp3dump.analyze(self.mono_path)
        self.assertEqual(report["warnings"], [])
        expected_frames = (4096 + 1151) // 1152
        expected_bytes = expected_frames * 144 * 128000 // 44100
        self.assertEqual(report["summary"]["frames"], expected_frames)
        self.assertEqual(report["summary"]["bytes"], expected_bytes)
        self.assertEqual(report["frames"][0]["header"]["side_size"], 17)
        self.assertEqual(report["summary"]["channels"], [1])

    def test_json_is_serialisable(self):
        report = mp3dump.analyze(self.stereo_path)
        encoded = json.dumps(report)
        self.assertEqual(json.loads(encoded)["summary"]["frames"], 39)

    def test_truncated_stream_warns(self):
        path = os.path.join(self.tmp.name, "truncated.mp3")
        with open(path, "wb") as handle:
            handle.write(self.stereo[:-100])
        report = mp3dump.analyze(path)
        self.assertTrue(report["warnings"])
        self.assertLess(report["summary"]["frames"], 39)

    def test_strict_cli_exit_code(self):
        path = os.path.join(self.tmp.name, "garbage.mp3")
        with open(path, "wb") as handle:
            handle.write(b"not an mp3 stream")
        proc = subprocess.run(
            [sys.executable, os.path.join(TOOLS, "mp3dump.py"), path, "--strict", "--first", "0"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("no sync", proc.stdout)

    def test_reserved_bitrate_is_rejected(self):
        header = b"\xff\xfb\xf0\x00"
        self.assertIsNone(mp3dump.parse_header(header, 0))


class SnrTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moonmp3-snr-")
        cls.manifest = gen_fixtures.build(cls.tmp.name, gen_fixtures.SEED)
        cls.sine = os.path.join(cls.tmp.name, "sine440_mono_1s.wav")
        import soundfile as sf

        cls.reference, cls.rate = sf.read(cls.sine, always_2d=True, dtype="float32")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _write(self, name, data):
        import soundfile as sf

        path = os.path.join(self.tmp.name, name)
        sf.write(path, data, self.rate, subtype="PCM_16")
        return path

    def test_identical_signal(self):
        report = snr.measure(self.sine, self.sine)
        self.assertEqual(report["delay_samples"], 0)
        self.assertTrue(math.isinf(report["overall_snr_db"]))
        self.assertEqual(report["per_channel"][0]["max_abs_error"], 0.0)

    def test_delay_is_detected_and_removed(self):
        delayed = np.vstack([np.zeros((123, 1), dtype=self.reference.dtype), self.reference])
        path = self._write("delayed.wav", delayed)
        report = snr.measure(self.sine, path)
        self.assertEqual(report["delay_samples"], 123)
        self.assertTrue(math.isinf(report["overall_snr_db"]))

    def test_noise_gives_finite_snr(self):
        rng = np.random.default_rng(7)
        noisy = self.reference + rng.normal(0, 0.05, self.reference.shape).astype(self.reference.dtype)
        path = self._write("noisy.wav", noisy)
        report = snr.measure(self.sine, path)
        self.assertTrue(10.0 < report["overall_snr_db"] < 25.0, report)
        self.assertLess(report["per_channel"][0]["correlation"], 1.0)

    def test_stereo_channels_are_independent(self):
        path = os.path.join(self.tmp.name, "sine440_stereo_1s.wav")
        report = snr.measure(path, path)
        self.assertEqual(report["channels"], 2)
        self.assertTrue(math.isinf(report["overall_snr_db"]))
        self.assertEqual(len(report["per_channel"]), 2)

    def test_channel_mismatch_is_rejected(self):
        stereo = os.path.join(self.tmp.name, "sine440_stereo_1s.wav")
        with self.assertRaises(mp3lab.ToolError):
            snr.measure(stereo, self.sine)


class SpectrumTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moonmp3-spectrum-")
        gen_fixtures.build(cls.tmp.name, gen_fixtures.SEED)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _path(self, name):
        return os.path.join(self.tmp.name, name)

    def test_sine_dominant_frequency(self):
        report = spectrum.analyze(self._path("sine440_mono_1s.wav"), 0, 3, 4096)
        self.assertAlmostEqual(report["dominant_hz"], 440.0, delta=1.0)

    def test_stereo_channels_are_not_swapped(self):
        left = spectrum.analyze(self._path("sine440_stereo_1s.wav"), 0, 3, 4096)
        right = spectrum.analyze(self._path("sine440_stereo_1s.wav"), 1, 3, 4096)
        self.assertAlmostEqual(left["dominant_hz"], 440.0, delta=1.0)
        self.assertAlmostEqual(right["dominant_hz"], 660.0, delta=1.0)

    def test_multitone_peaks(self):
        report = spectrum.analyze(self._path("multitone_mono_1s.wav"), 0, 3, 4096)
        frequencies = sorted(peak["frequency_hz"] for peak in report["peaks"])
        for expected, measured in zip((440.0, 880.0, 1320.0), frequencies):
            self.assertAlmostEqual(measured, expected, delta=2.0)

    def test_silence_has_no_peak(self):
        report = spectrum.analyze(self._path("silence_mono_1s.wav"), 0, 3, 4096)
        self.assertEqual(report["peaks"], [])
        self.assertIsNone(report["dominant_hz"])


class FixedSpectrumTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="moonmp3-count1-")
        cls.payload = mp3lab.extract_payload(
            mp3lab.run_cli("tone", "4", "12", "206", "1")
        )
        cls.path = os.path.join(cls.tmp.name, "line12.mp3")
        with open(cls.path, "wb") as handle:
            handle.write(cls.payload)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_frame_structure(self):
        report = mp3dump.analyze(self.path)
        self.assertEqual(report["warnings"], [])
        self.assertEqual(report["summary"]["frames"], 4)
        self.assertEqual(report["summary"]["bytes"], len(self.payload))
        self.assertTrue(report["summary"]["constant_bitrate"])
        for frame in report["frames"]:
            # Nine-bit offset: every frame must point inside the decoder's window.
            self.assertGreaterEqual(frame["side_info"]["main_data_begin"], 0)
            self.assertLessEqual(frame["side_info"]["main_data_begin"], 511)
            for granule in frame["side_info"]["granules"]:
                self.assertEqual(granule["part2_3_length"], 9)
                self.assertEqual(granule["big_values"], 0)
                self.assertEqual(granule["count1table_select"], 0)

    def test_decodes_to_a_fixed_tone(self):
        data, rate = mp3lab.decode_mp3(self.payload)
        self.assertEqual(rate, 44100)
        self.assertEqual(data.shape, (4608, 1))
        peak = float(abs(data).max())
        self.assertGreater(peak, 0.3)
        self.assertLess(peak, 0.6)
        report = spectrum.analyze(self.path, 0, 5, 4096)
        self.assertIsNotNone(report["dominant_hz"])
        self.assertAlmostEqual(report["dominant_hz"], 459.375, delta=15.0)


class AnalysisTests(unittest.TestCase):
    """The PCM path: filterbank, MDCT, quantiser and the decoded result."""

    def test_matches_the_numpy_reference(self):
        import analysis_ref

        for freq in (440, 1000):
            report = analysis_ref.compare(freq, 50, 6)
            self.assertLess(report["relative_error"], 1e-12, report)

    def test_reference_properties(self):
        import analysis_ref

        self.assertEqual(analysis_ref.self_check(), 0)

    def test_generated_sine_decodes_at_its_own_frequency(self):
        # The dominant frequency of the decoded stream has to stay within one
        # MDCT line (38.28125 Hz) of the input, including in the odd subbands
        # where the analysis has to undo its own spectral reversal.
        for freq in (440, 1000, 3000, 8000):
            payload = mp3lab.extract_payload(
                mp3lab.run_cli("sine", "16", str(freq), "50", "1")
            )
            with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
                handle.write(payload)
                path = handle.name
            try:
                report = spectrum.analyze(path, 0, 5, 8192)
            finally:
                os.unlink(path)
            self.assertIsNotNone(report["dominant_hz"], freq)
            self.assertAlmostEqual(report["dominant_hz"], freq, delta=38.3, msg=freq)

    def test_stereo_channels_stay_separate(self):
        payload = mp3lab.extract_payload(
            mp3lab.run_cli("sine", "16", "440,660", "50", "2")
        )
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
            handle.write(payload)
            path = handle.name
        try:
            left = spectrum.analyze(path, 0, 3, 8192)
            right = spectrum.analyze(path, 1, 3, 8192)
        finally:
            os.unlink(path)
        self.assertAlmostEqual(left["dominant_hz"], 440.0, delta=38.3)
        self.assertAlmostEqual(right["dominant_hz"], 660.0, delta=38.3)

    def test_gain_stays_inside_the_side_info_field(self):
        payload = mp3lab.extract_payload(
            mp3lab.run_cli("sine", "4", "440", "100", "1")
        )
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as handle:
            handle.write(payload)
            path = handle.name
        try:
            report = mp3dump.analyze(path)
        finally:
            os.unlink(path)
        self.assertEqual(report["warnings"], [])
        for frame in report["frames"]:
            # Main data flows through the bit reservoir: a frame points back at
            # where its own data begins, and the nine-bit field caps that at the
            # 511-byte window the decoder keeps.
            self.assertGreaterEqual(frame["side_info"]["main_data_begin"], 0)
            self.assertLessEqual(frame["side_info"]["main_data_begin"], 511)
            capacity = (frame["header"]["size"] - 4 - frame["header"]["side_size"]) * 8
            reachable = frame["side_info"]["main_data_begin"] * 8 + capacity
            for granule in frame["side_info"]["granules"]:
                self.assertGreaterEqual(granule["global_gain"], 0)
                self.assertLessEqual(granule["global_gain"], 255)
                # big_values counts pairs, so it is even and cannot exceed 288.
                self.assertEqual(granule["big_values"] % 2, 0)
                self.assertLessEqual(granule["big_values"], 288)
                self.assertEqual(granule["count1table_select"], 0)
                # Every MPEG-1 table reaches at most 15 and uses no escapes.
                for table in granule["table_select"]:
                    self.assertTrue(table in (0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15), table)
                # Table A needs only its one-bit all-zero code after the last
                # non-zero count1 quadruple. No granule may claim more than what
                # the decoder can reach at this frame (the borrowed bytes plus
                # this frame's area, shared by the two granules of the channel).
                self.assertGreaterEqual(granule["part2_3_length"], 1)
                self.assertLessEqual(granule["part2_3_length"], reachable // 2)

    def test_big_values_lifts_the_sine_above_twenty_db(self):
        # The stage-1 quality floor: a steady tone has to decode at its own
        # frequency and at least 20 dB above the quantisation noise.
        import snr

        frames = 39
        payload = mp3lab.extract_payload(mp3lab.run_cli("sine", str(frames), "440", "50", "1"))
        count = frames * 1152
        index = np.arange(count)
        reference = np.round(0.5 * 32767 * np.sin(2 * np.pi * 440 * index / 44100.0))
        with tempfile.TemporaryDirectory(prefix="moonmp3-bv-") as folder:
            reference_path = os.path.join(folder, "ref.wav")
            candidate_path = os.path.join(folder, "cand.mp3")
            import soundfile as sf

            sf.write(reference_path, reference.astype(np.int16), 44100, subtype="PCM_16")
            with open(candidate_path, "wb") as handle:
                handle.write(payload)
            # The encoder's delay is the constant 1057 samples; searching for it
            # by correlation on a periodic probe locks onto a neighbouring period
            # and measures the alignment instead (16.2 dB here against 22.1 dB at
            # the true delay), so the delay is given rather than searched.
            report = snr.measure(reference_path, candidate_path, delay=1057)
        self.assertGreaterEqual(report["overall_snr_db"], 20.0)
        self.assertGreaterEqual(report["per_channel"][0]["correlation"], 0.99)


class BoundaryMatrixTests(unittest.TestCase):
    """Stage 2's boundary matrix: block edges, full scale, transients, decoders."""

    def _encode_pcm(self, samples, channels):
        import base64

        payload = base64.b64encode(
            np.clip(np.round(samples), -32768, 32767).astype(np.int16).tobytes()
        )
        return mp3lab.extract_payload(mp3lab.run_cli("encode", payload.decode(), str(channels)))

    def test_block_edges_1151_1152_1153(self):
        # One sample either side of the 1152-sample frame is where an off-by-one
        # in the frame count shows up as a wrong decoded length or a wrong
        # frequency, so all three are checked for both channel counts.
        # libsndfile cannot open a one-frame stream, so the boundary is probed at
        # the second frame (2*1152 +- 1); the one-frame case is covered by mp3dump.
        for count in (2 * 1152 - 1, 2 * 1152, 2 * 1152 + 1):
            for channels in (1, 2):
                index = np.arange(count)
                tone = np.zeros((count, channels))
                for channel in range(channels):
                    freq = 440.0 + 220.0 * channel
                    tone[:, channel] = 0.5 * 32767 * np.sin(2 * np.pi * freq * index / 44100.0)
                payload = self._encode_pcm(tone.reshape(-1), channels)
                data, rate = mp3lab.decode_mp3(payload)
                self.assertEqual(rate, 44100)
                self.assertEqual(data.shape[1], channels)
                expected = ((count + 1151) // 1152) * 1152
                self.assertEqual(data.shape[0], expected)
                self.assertLess(float(np.max(np.abs(data))), 1.30)

    def test_full_scale_and_impulse_stay_finite(self):
        for percent in (99, 100):
            payload = mp3lab.extract_payload(
                mp3lab.run_cli("sine", "16", "440", str(percent), "1")
            )
            data, _ = mp3lab.decode_mp3(payload)
            self.assertTrue(np.all(np.isfinite(data)), percent)
            self.assertLess(float(np.max(np.abs(data))), 2.0, percent)
        impulse = np.zeros(4096)
        impulse[2048] = 32767.0
        payload = self._encode_pcm(impulse, 1)
        data, _ = mp3lab.decode_mp3(payload)
        self.assertTrue(np.all(np.isfinite(data)))
        self.assertGreater(float(np.max(np.abs(data))), 0.01)

    def test_near_full_scale_does_not_overshoot(self):
        # The near-full-scale headroom reserve must keep the decoded peak at or
        # below 1.0, so a mastered 0 dBFS stream cannot clip on decode.
        for percent in (99, 100):
            payload = mp3lab.extract_payload(
                mp3lab.run_cli("sine", "16", "440", str(percent), "1")
            )
            data, _ = mp3lab.decode_mp3(payload)
            self.assertLessEqual(
                float(np.max(np.abs(data))), 1.00, percent
            )
            if percent == 100:
                # Target 0.87 attenuates a 100% full-scale input by ~1.2 dB.
                # Verify that level loss does not exceed 1.3 dB.
                decoded_rms = float(np.sqrt(np.mean(data[1057:16 * 1152, 0] ** 2)))
                expected_rms = 1.0 / np.sqrt(2.0)
                loss_db = 20.0 * np.log10(expected_rms / decoded_rms)
                self.assertLessEqual(loss_db, 1.3)
                self.assertGreaterEqual(loss_db, 0.0)

    def test_transient_switches_to_short_windows(self):
        # An isolated impulse must trigger start/short/stop window switching, and
        # the resulting stream must still decode cleanly in two decoders.
        import base64

        impulse = np.zeros(7938)
        impulse[4000] = 0.9
        payload = self._encode_pcm(impulse, 1)
        report = mp3dump.analyze(
            self._write_mp3("impulse", payload)
        )
        self.assertEqual(report["warnings"], [])
        block_types = [
            (g["window_switching"], g["block_type"])
            for f in report["frames"]
            for g in f["side_info"]["granules"]
        ]
        self.assertIn((1, 2), block_types)
        self.assertIn((1, 1), block_types)
        self.assertIn((1, 3), block_types)
        data, _ = mp3lab.decode_mp3(payload)
        self.assertTrue(np.all(np.isfinite(data)))
        import crossdecode

        agreed = crossdecode.compare(payload)
        self.assertTrue(agreed["agree"], agreed)

    def _write_mp3(self, name, payload):
        folder = tempfile.mkdtemp(prefix="moonmp3-impulse-")
        path = os.path.join(folder, f"{name}.mp3")
        with open(path, "wb") as handle:
            handle.write(payload)
        return path

    def test_decoder_model_reproduces_libsndfile(self):
        # tools/decoder_ref.py models the decoder chain stage by stage. If it ever
        # stops matching the real decoder, every closed-loop measurement built on
        # it becomes meaningless, so the model itself is gated here.
        import decoder_ref

        agreement = decoder_ref.verify()
        self.assertGreaterEqual(agreement, 40.0, agreement)
    def test_two_decoders_agree(self):
        import crossdecode

        payload = mp3lab.extract_payload(mp3lab.run_cli("sine", "16", "440,660", "50", "2"))
        report = crossdecode.compare(payload)
        self.assertTrue(report["agree"], report)
        self.assertEqual(report["rate"]["mpg123"], report["rate"]["ffmpeg"])
        for entry in report["per_channel"]:
            self.assertGreaterEqual(entry["correlation"], 0.9999, entry)
            self.assertAlmostEqual(
                entry["dominant_hz"]["mpg123"], entry["dominant_hz"]["ffmpeg"], delta=1.0
            )

class CliTests(unittest.TestCase):
    def test_cli_reports_version(self):
        output = mp3lab.run_cli("version")
        self.assertTrue(output.strip().startswith("0."), output)

    def test_release_preflight(self):
        report = check_release.check()
        self.assertTrue(report["ok"], report["checks"])
        self.assertEqual(report["blocking"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
