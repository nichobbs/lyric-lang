# 2026-09-28 — Exact-uniformity ranged draws for Std.Random/Std.SecureRandom on the JVM (#7487)

D-progress-1022, #7487.

`#7252` fixed a signed-Int32 overflow in the JVM kernels' `nextIntRange`
functions by widening the range computation to `Long` and reducing a
masked 63-bit `nextLong()` draw with `%`. Modulo reduction of a 63-bit
value against an arbitrary range is not exactly uniform (relative bias on
the order of `range / 2^63`) — negligible for `Std.Random`, but
`Std.SecureRandom.secureNextIntRange` documents exact uniformity for
security-sensitive draws (tokens, OTP digits), where that bias is a real
distinguishing weakness, not just noise.

- `lyric-stdlib/std/_kernel_jvm/random_host.l`'s `hostNextIntRange` and
  `lyric-stdlib/std/_kernel_jvm/secure_random_host.l`'s
  `hostSecureNextIntRange` now delegate to
  `java.util.random.RandomGenerator`'s default `nextInt(origin, bound)`
  (JDK 17+) instead of computing the range by hand. `java.util.Random` and
  `java.security.SecureRandom` both implement `RandomGenerator` and neither
  overrides this bounded overload, so the call dispatches through the
  interface's own unbiased rejection-sampling algorithm. This also
  subsumes #7252's overflow fix (the default implementation widens
  internally, so `min = Int.MinValue, max = Int.MaxValue` no longer needs
  a hand-rolled `Long` computation) and simplifies both kernels back down
  to a single expression.
- Verified the self-hosted JVM auto-FFI resolver (`Jvm.AutoFfi`,
  `lyric-compiler/jvm/auto_ffi.l`) already walks a class's transitively
  implemented interfaces (`findBestInstanceMethod` /
  `scoreInterfacesRec`) when resolving an instance method not declared on
  the receiver's own class, so `rng.nextInt(min, max)` against a
  `java.util.Random`-typed receiver resolves to `RandomGenerator`'s
  default method and emits `invokevirtual java/util/Random.nextInt(II)I`
  correctly with no resolver changes needed.
- Audited the other two targets for the same issue:
  - **.NET** (`lyric-stdlib/std/_kernel/random_host.l` /
    `secure_random_host.l`) already called `System.Random.Next(min, max)`
    and `RandomNumberGenerator.GetInt32(min, max)` directly — both are
    documented as exactly uniform (unbiased rejection sampling) since
    .NET 6 / their introduction — so no change was needed there.
  - **native** (`lyric-stdlib/std/_kernel_native/`) has no `random_host.l`
    or `secure_random_host.l` at all: `Std.Random`/`Std.SecureRandom` are
    not implemented on the native target today, so there is nothing to
    fix or audit there. This gap is pre-existing and out of scope for
    this change; tracked in #7667.
- Updated the public doc comments on `Std.Random.nextIntRange` and
  `Std.SecureRandom.secureNextIntRange` to state the exact-uniformity
  guarantee explicitly.
- `book/chapters/appendix-b-quick-reference.md`'s `Std.Sort` row now lists
  `isAscendingInts`/`isAscendingLongs`/`isAscendingStrings`, matching
  chapter 12 and `lyric-stdlib/std/sort.l`'s actual exports (unrelated
  drive-by fix requested alongside this issue).

## Tests

- `lyric-stdlib/tests/random_tests.l` gained
  `testNextIntRangeFullIntDomain`, `testNextIntRangeSingleValue`, and
  `testNextIntRangeInvalidRangePanics` — deterministic bounds/contract
  checks (full `Int` domain, a single-value range, and the `min >= max`
  panic), run on both dotnet and `--target jvm` in CI.
- `lyric-compiler/lyric/secure_random_self_test.l` gained the equivalent
  three cases for `secureNextIntRange`, run via `lyric test` on both
  dotnet and `--target jvm` in CI.
- Deliberately did not add a chi-square or other statistical uniformity
  test: bounding its false-failure probability near zero needs a large
  sample, and even then it can occasionally flake, while the bug this
  issue actually fixes (a `range / 2^63`-scale reduction bias) produces
  draws that are still always in bounds — a bounds/contract test is what
  is load-bearing here, and correctness of the fix rests on delegating to
  the JDK's own documented-unbiased `RandomGenerator.nextInt(origin,
  bound)` rather than on re-deriving uniformity locally.
- Ran locally (this session): `lyric-stdlib/tests/random_tests.l` on
  dotnet and `--target jvm`; `lyric-compiler/lyric/secure_random_self_test.l`
  on dotnet and `--target jvm` (6/6 passing on both);
  `bash scripts/ci/compiler-self-tests-batch.sh` (0 `not ok`);
  `bash scripts/ci/jvm-generics-self-tests-batch.sh` (0 `not ok`);
  `make -C lyric-rt` (native runtime still builds clean; confirms no
  native random kernel exists).
