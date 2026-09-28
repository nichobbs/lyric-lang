# `X.toNat()` ships as a checked conversion on `--target dotnet`

`Int`/`Long`/`Byte`/`Char`/`Double` receivers gained a `.toNat()` conversion
method, closing a gap catalogued in nichobbs/cloud-agents'
`docs/lyric/gotchas.md`: calling `.toNat()` compiled but threw an
"unsupported method" runtime error, since neither the type checker nor the
MSIL codegen recognized the method name.

## Root cause

`.toNat()` fell through the Band-1 (#1901) numeric-conversion intrinsic path
on both ends: `typechecker_exprs.l`'s `numericConvTarget` had no `"toNat"`
entry (so type-checking deferred/accepted the call leniently rather than
resolving it to a `PtNat` target), and `codegen.l`'s numeric-conversion
dispatch block had no matching case either, so codegen fell through to the
generic unresolved-method runtime-throw stub. `Nat.toInt()` (the reverse
direction, receiver-side) happens to already work by accident: `Nat` erases
to the same MSIL type as `Long` (`MLong`), so a `Nat` receiver's `.toInt()`
call is indistinguishable from a `Long` receiver's at the erased-type
dispatch codegen sees.

## Fix

Modeled directly on the existing `.toChar()` checked conversion (the only
other conversion method that can fail): `.toNat()` is now a genuine checked
conversion rather than a bit-reinterpreting cast, since `Nat` is documented
as a non-negative `Long` (§2.1) and silently accepting a negative source
value would violate that invariant.

- `typechecker_exprs.l`: `numericConvTarget` maps `"toNat"` to `PtNat`.
- `codegen.l`: the numeric-conversion dispatch gained a `toNat` case; new
  `emitCheckedToNatMsil`/`toNatRangeMessage` emit the negativity check.
  `Byte`/`Char` receivers are always non-negative and convert unchecked;
  `Int`/`Long`/`Double` receivers are range-checked and throw
  `OverflowException` with message `toNat: value must be non-negative` on a
  negative value. The `Double` branch truncates toward zero first (matching
  `.toInt()`/`.toLong()`), so `-0.5` is accepted (truncates to `0`) while
  `-1.5` is rejected; the comparison is `value > -1.0` (mirroring
  `emitRangeCheckedToCharMsil`'s existing pattern) so NaN, which compares
  false against everything via `cgt`, correctly routes to the failure
  branch rather than being silently accepted.

This closes only the `X.toNat()` (target-side) gap. Conversion methods
*called on* a `Nat`/`UInt`/`ULong` receiver, and conversions *targeting*
`UInt`/`ULong`, remain unimplemented as their own intrinsic path — see
`docs/01-language-reference.md` §4.1's updated parenthetical. Codegen for
`.toNat()` is MSIL-only, matching the scope of the originating gotcha.
`numericConvTarget` is target-independent front-end code, though, so
`.toNat()` now type-checks on `--target jvm` too — it just has no matching
JVM codegen dispatch, so it fails cleanly at build time with `error[J008]`
rather than compiling and crashing at runtime. Filed as #7661. `--target
native` is unaffected (it never reaches this numeric-conversion dispatch
path for `.toNat()` at all).

## Tests

New file `lyric-compiler/lyric/int_to_nat_self_test.l` (2 cases: `toNat
accepts every non-negative source value`, `toNat rejects negative source
values`), covering all five receiver types plus the `0` boundary, the
`-0.5`-truncates-to-`0` case, and NaN — kept out of
`conv_methods_self_test.l` deliberately: that file runs on BOTH
`--target dotnet` and `--target jvm` in CI, and this fix is dotnet-only.
`--target jvm` rejects `.toNat()` cleanly at BUILD time instead
(`error[J008]: method 'toNat' cannot be called on a primitive-typed
receiver` — `Jvm.Codegen` has no `toNat` arm), so folding the cases in
there would fail the JVM CI leg with a build error, not just a test
failure. Wired into `.github/workflows/ci.yml`'s
small "BuildInfo dotnet batch" (`--target dotnet` only, alongside the
`buildinfo_self_test.l`/`range_subtype_self_test.l` steps already reserved
there to stay off the already-at-cap adjacent batches, #5933/#5967).
2/2 pass (`lyric test lyric-compiler/lyric/int_to_nat_self_test.l`); the
existing `conv_methods_self_test.l` suite (20/20) re-verified unchanged.
Manually verified end-to-end against a freshly built `./bin/lyric` with a
standalone repro program exercising all five receiver types' success and
failure paths before folding the cases into the self-test.

## Docs

Updated `docs/01-language-reference.md` §4.1 and
`book/chapters/appendix-b-quick-reference.md`'s numeric-conversions
paragraph to document `.toNat()` and correct the stale
"conversion methods on unsigned Nat/UInt/ULong not yet implemented"
claim.
