# D-progress-998 — Contracts on the core stdlib

**Status:** shipped

Implements #7252, apart from the `Char.fromInt` surrogate precondition (see
below).

## Decisions

- **Cross-target divergence is settled in shared Lyric, or by a
  precondition, never left to the host:**
  - **`encodeUtf8`:** a lone surrogate becomes U+FFFD on the JVM as it
    already did on .NET.
  - **`signDouble(NaN)`:** returns 0 on every target.
  - **`zeroPad`:** sign-aware (`zeroPad(-7, 3) == "-07"`).
  - **`nextIntRange`/`secureNextIntRange`:** the JVM kernels compute the
    range width in `Long`.
  - **Duration constructors:** reject `NaN` and values beyond native's
    signed-nanosecond range.
  - **`fromEpochMillis`/`fromEpochSeconds`:** accept the range all three
    targets can represent (±~292 years), with new `tryFromEpochMillis` and
    `tryFromEpochSeconds` as the Option form.
  - **`addMonths`/`addYears`:** take .NET's bounds.
- **`tryDecodeBase64` rejects non-canonical padding bits:** a token has
  exactly one accepted encoding.
- **`Option`/`Result` query helpers are `@pure`:** so contracts can call
  them. `unwrapResult*`/`unwrapOption` use `requires: isOk(r)` /
  `isSome(o)` instead of a bare panic.
- **Silent clamps and wraps become preconditions:**
  - `repeat` and `take`/`drop` take a negative count;
  - `substring` checks `start + count` without overflow;
  - `absInt`/`absLong` reject MinValue;
  - `maxInt` requires a non-empty slice;
  - `formatFixed` requires `decimals` in 0..100;
  - `regex` timeouts must fit the host's milliseconds;
  - `codepointToString` requires a scalar value.
- **Postconditions on lengths and ranges,** for proofs and documentation:
  - hex, base64 and digest lengths;
  - `uuidToString` returns 36 characters;
  - padding width;
  - sort output length and order (O(n) `isAscending*` checks on O(n log n)
    sorts);
  - iterator lengths;
  - persistent-collection and set sizes;
  - random ranges;
  - `charAt`/`first`/`last`/`split` shape.
- **`@runtime_checked`** is written explicitly on `core`, `collections`,
  `set`, `sort`, `iter`, `parse`, `encoding`, `hash`, `secure_random`,
  `uuid` and `time`.

## Not done

- **`Char.fromInt` still accepts surrogates.** `Std.Xml`, `Std.Yaml` and
  lyric-auth deliberately build astral characters one surrogate half at a
  time, so a precondition would break working code. Settling whether
  `Char` is a UTF-16 code unit or a scalar value is left on #7252.
- **A bare `longToInt(n)` still lowers to an unchecked truncation on both
  backends and bypasses the new contract (#7465).** The contract applies
  to a qualified `Math.longToInt(n)`.
- **Explicit type arguments.** Contract clauses such as
  `isNone[Char](result)` spell out the type argument until #7466 is fixed.
