#!/usr/bin/env python3
"""Cross-test a delivered analysis against the *verified* decoder.

spec_filterbank.py self-tests by round-tripping through its own synthesis. That proves
self-consistency, not correctness: an analysis and synthesis pair can be wrong in
compensating ways. The real decoder is known here (tools/decoder_ref.py agrees with
libsndfile at 127.5 dB), so feed the delivered analysis' subband output into the
real decoder's remaining stages (frequency inversion -> cosine matrix -> U build ->
512-tap window) and compare with the input.

Judged on white noise, because a tone probe cannot tell a filterbank from a phase
rotation.
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import decoder_ref as DR  # noqa: E402
import spec_filterbank as SF  # noqa: E402


def decode_subband(subband: np.ndarray) -> np.ndarray:
    """Subband matrix (32, steps) -> time samples, using the verified decoder."""
    steps = subband.shape[1]
    values = subband.T.copy()  # (steps, 32)
    for t in range(steps):
        if t % 2 == 1:
            for sb in range(1, 32, 2):
                values[t, sb] = -values[t, sb]
    v = np.zeros(1024)
    output = []
    for t in range(steps):
        output.extend(DR.synthesis_step(values[t], v))
    return np.array(output)


def score(samples: np.ndarray, subband: np.ndarray, skip: int = 8 * 576) -> tuple:
    rebuilt = decode_subband(subband)
    n = min(rebuilt.size, samples.size) - skip - 576
    reference = samples[skip:skip + n]
    best = (0, -1e18)
    for delay in range(0, 1400):
        if skip + delay + n > rebuilt.size:
            break
        chunk = rebuilt[skip + delay:skip + delay + n]
        value = np.dot(chunk, reference) ** 2 / max(np.dot(chunk, chunk) * np.dot(reference, reference), 1e-18)
        if value > best[1]:
            best = (delay, value)
    chunk = rebuilt[skip + best[0]:skip + best[0] + n]
    gain = np.dot(chunk, reference) / max(np.dot(chunk, chunk), 1e-18)
    residual = reference - gain * chunk
    snr = 10 * np.log10(np.dot(reference, reference) / max(np.dot(residual, residual), 1e-30))
    return float(snr), int(best[0]), float(gain)


window, _ = SF.load_tables()
COUNT = 576 * 40
rng = np.random.default_rng(11)
noise = rng.standard_normal(COUNT)

print("delivered analyze() -> verified decoder, white noise")
results = {}
for inversion in (True, False):
    subband = SF.analyze(noise, window, matrix="spec", layer3_inversion=inversion)
    snr, delay, gain = score(noise, subband)
    results[inversion] = snr
    print(f"  spec, layer3_inversion={inversion!s:5s}: {snr:7.2f} dB  delay {delay}  gain {gain:.5f}")

report = DR.score(DR.shipped_analysis, 0.0, noise=True)
print(f"  shipped analysis.mbt for reference: {report['snr_db']:7.2f} dB")

# The gate: with the Layer III inversion on, the delivered analysis has to be the
# inverse of the real decoder. Without it, it must NOT be, which is what proves the
# inversion is load-bearing rather than cosmetic.
ok = results[True] >= 40.0 and results[False] < 20.0
print("ok: the delivered analysis is the decoder's inverse" if ok else "FAIL: not the inverse")
raise SystemExit(0 if ok else 1)