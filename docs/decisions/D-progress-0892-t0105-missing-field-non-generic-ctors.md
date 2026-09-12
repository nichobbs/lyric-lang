# D-progress-892 — Type checker: T0105 missing-required-field check generalized to non-generic record/opaque constructors (#6739)

**Status:** shipped

**Context.** `inferConstruction`'s `#3156` missing-field check (`T0105`) — added
so omitting a required, no-default record field is caught at type-check time
rather than reaching codegen — was scoped only to the `ctorIsGeneric(sym)`
branch. A **non-generic** record with a required field omitted from an
all-named-args construction (`Three(a = "x", b = "y")` for `record Three { a:
String; b: String; c: String }`) type-checked with zero diagnostics, and
codegen emitted a `newobj` sized for the args actually supplied — invalid IL,
crashing at runtime with `System.InvalidProgramException`. Found via a real
CI failure (#6547's `rest_json_roundtrip_self_test.l`, missing a `paths` field
after a record grew a third field) and confirmed via a minimal 3-required-
field repro (#6739 comment thread).

**Fix.** Extracted the `#3156` check into a shared `reportMissingCtorFields`
helper (fields, args, sym, span, diag) → `Bool`, called from BOTH the generic
and non-generic paths in `inferConstruction` (`typechecker_exprs.l`). Same
scoping as before: only fires when every supplied arg is named (no
positional args — mixed-mode under-application stays out of scope, unchanged
from the original `#3156` design).

**Regression found and fixed during this change.** A first pass of the
generalization broke an existing test (`"ctor unknown field"`,
`Point(z = 3)` for `record Point { x: Int; y: Int }`): every real field
("missing" by construction, since only the bogus `z` was supplied) fired
T0105 for `x` AND `y`, burying the actual defect — `T0101` ("no field 'z'")
— under two confusing, unrelated diagnostics, and the function returned
`TyError` before ever reaching the per-arg T0101 validation loop. Fixed by
adding a `hasUnknownName` guard alongside the existing `hasPositional` one:
the missing-field check now defers entirely to the ordinary per-arg T0101
validation whenever any supplied named arg doesn't match a real field.
This precise interaction (missing required fields + an unrelated unknown
field name, together) had no prior test coverage for either the generic or
non-generic path, so it was not caught by the existing suite before this
change made it reachable.

**JVM parity.** `Lyric.TypeChecker` is the single target-independent type
checker both `Msil.Bridge` and `Jvm.Bridge` call `checkFile`/
`checkWithImportedPackages` through (per CLAUDE.md's compiler-tree
overview) — this fix applies identically to both backends with no
per-target code.

**Verification.** New self-tests in `typechecker_self_test.l`: a non-generic
record missing a required field now emits `T0105`; a missing field WITH a
default is not reported; all-required-fields-supplied stays clean. Full
`typechecker_self_test.l` suite passes (425/425) after the `hasUnknownName`
fix, including the pre-existing `"ctor unknown field"` regression guard.
