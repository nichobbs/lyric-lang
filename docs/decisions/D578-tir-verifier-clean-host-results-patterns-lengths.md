# D578 - The verifier-clean builder: host results, short case patterns, generic lengths (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361, D575.

## Context

Outside the stdlib the wide census found 27 I0003 diagnostics in the compiler (`call-result-type` on extern calls and 8 `pattern-arity`), one in a self-test (`construct-field-type`) and one `assign-mutable`. I0003 has to be zero before I0002/I0003 can stop the build (docs/70 section 12.2), and a body the builder produced must be well formed, so each is a builder or verifier defect to fix at its root.

## Decision

- **Host results.** An extern call keeps the host's own result type in `HostMemberRef.ret` (a backend needs it to emit the call). When the checker typed the call as a Lyric type without checking the host result (D359), the call node has the host type and is wrapped in a conversion to the checker's type: `CvLiftNullable` for a host `String` the checker types `String?`, and the new `CvFromHost` for a host array typed as a slice or array, a host enum typed `Int`, `System.Single`/`java.lang.Float` typed `Float`, `System.Double`/`java.lang.Double` typed `Double`, and a host task (`System.Threading.Tasks.Task`, `CompletableFuture`, `Future`) typed as the built-in `Task[T]` (with the element types reconciled the same way). `CvFromHost` requires an operand of a host type (`convert-type`).
- **Short case patterns.** The checker accepts a case pattern with fewer sub-patterns than the case has fields, and every backend binds the leading fields and ignores the rest (`case A(p)` for `A(x, y)` binds `x`). The builder pads the missing trailing sub-patterns with wildcards, so the verifier's `pattern-arity` rule stays strict. Whether the checker should reject such a pattern is a language decision this change does not make; it is recorded on #8613.
- **Generic lengths.** Substituting a case field's `array[N, T]` length when the construction's argument is itself a value parameter of the enclosing function forwards that parameter (`ALParam`) instead of leaving the union's own.
- The wide census names the function (`Pkg::name(params)`) beside each I0003 example and shows up to six per rule.

## Measured

`scripts/ci/tir-census.sh --wide`: I0003 stdlib 0, compiler 27 -> 0, ecosystem 0, self-tests 2 -> 1 (the remaining `assign-mutable` is a self-test that writes a plain record field, fixed with the test on another branch). Bodies built: compiler 11,172 of 12,442. The `tir_build` (132) and `tir_verify` (27) self-tests pass.
