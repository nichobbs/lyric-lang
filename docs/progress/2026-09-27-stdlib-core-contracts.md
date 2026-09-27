# 2026-09-27 — Contracts on the core stdlib

D-progress-998, #7252.

- **Cross-target fixes:**
  - lone surrogates in `encodeUtf8` become U+FFFD on the JVM, as on .NET;
  - `signDouble(NaN)` returns 0 everywhere;
  - `zeroPad` handles negative numbers;
  - the JVM's wide `nextIntRange` no longer overflows;
  - the Duration and epoch constructors share one range on every target,
    with new `tryFromEpochMillis`/`tryFromEpochSeconds`.
- **Canonical base64:** `tryDecodeBase64` rejects non-canonical padding.
- **Preconditions** replace silent clamps, wraps and panics in:
  - `repeat`, `take`/`drop` and `substring`;
  - `absInt`/`absLong` and `maxInt`;
  - `unwrap*`;
  - `formatFixed`, `codepointToString` and the regex timeouts.
- **Postconditions** on encoding, digest, UUID, padding, sort, iterator,
  collection, random and string-access results.
- **Tests:** `random_tests.l` is new and runs on dotnet and the JVM in CI.
