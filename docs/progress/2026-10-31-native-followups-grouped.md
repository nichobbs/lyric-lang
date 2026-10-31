# Native follow-ups: Map equality and hashing, ULong plan, invariant boundary test, bare enum cases (#8600, #8601, #8652, #8637, #8656, #8691)

One grouped change for six follow-up issues. Per issue:

## #8600 native `==` on `List`/`Map`/`Set` (fixed for `Map`; `Set` does not exist on native)

`List` was already element-wise since #8643. The remaining gap was `Map`: it fell
to the pointer compare in `emitValueEqN` and the binary-operator path. `==` and
`!=` on a `Map` now go through `lyric_map_equal` (new, `lyric-rt`): equal sizes,
then every key of one found in the other (through the other map's own hash and
equality) with a value the compiler-synthesised slot equality accepts (reuses
`ensureMapKeyEq`, so a `Double` value follows D172). `emitValueEqN` has the same
arm, so a record field of `Map` type compares by contents.

Hashing: a `List` or `Map` was hashed as a pointer by `emitValueHashN`, so a
record holding one could compare equal and hash apart. `lyric_list_hash`
(ordered) and `lyric_map_hash` (order-independent sum of entry hashes) back new
arms, so such a record works as a `Map` key. A `List`/`Map` used directly as a
key is still rejected (`isStructuredKeyNType`), as before.

Files: `lyric-rt/src/lyric_collections.c`, `lyric-rt/include/lyric_rt.h`,
`lyric-compiler/lyric/llvm_codegen.l`. Test: `llvm_collections_self_test.l`
("== on maps and hashing of list and map fields", ASan).

## #8601 JVM `__lyricKeyHash` for `Set`/`Map` of `Double` (already fixed)

Fixed by #8643 (`HashSet`/`HashMap` arms in `emitKeyHashHashed`, covered by a
JVM case in `hash_jvm_self_test.l`). Verified on `main` and closed with a comment.

## #8652 structural `toString` gaps (items 3 and 5 fixed; 1, 2 and 4 not)

- Item 3: a bare enum case with no expected type had no checked type
  (`val z: String = Green` was accepted and `println(Green)` printed the
  ordinal on dotnet and native). `resolveExprPath` now types a bare
  `DKEnumCase` as its enum when no other symbol shares the case name. Files:
  `typechecker_exprs.l`. Tests: a case in `structural_tostring_self_test.l`
  (all targets) and a reject fixture under `testdata/reject/`.
- Item 5: a statement-level `s += p` was a `SAssign`, which `anyExprInFile`
  never offered to the `mayRenderStructure` predicate, so a bundle whose only
  stringification was that statement did not link `Std.String` on the JVM and
  native. `anyInStmt` now offers a statement `SAssign` to the predicate as the
  `EAssign` it would be in expression position. File: `ast_map.l`.
- Items 1 (`array[N, T]` rendering), 2 (generics declared in another package)
  and 4 (a union case named `Unit` on the JVM, reproduced: any `Unit`-returning
  call in a package declaring such a case fails with a stackmap underflow) are
  not fixed; they stay open on the issue with the findings.

## #8637 ULong on native (not fixed)

Large: the backend lowers from the AST with no signedness on an `NI64`, so
`ULong` needs either a new IR type or a checker site table for unsigned
operators. See the plan on the issue.

## #8656 native test for the invariant boundary (added)

`llvm_invariant_boundary_self_test.l` builds `examples/invariant-boundary`'s two
packages plus an entry package as a native project and runs it once per case (a
native panic ends the process): valid values cross every boundary, and a broken
`in` argument, result, `inout` parameter and the declaring package's own `inout`
panic with `InvariantViolated`. Added to `make test-native` and
`scripts/ci/native-backend-self-tests.sh`.

## #8691 native stdlib check cache for packages with lowering sites (closed, not worth it)

Measured per the issue: a warm native build of a program importing `Std.Linalg`
and `Std.Parallel` (so `Std.Buffer`, `Std.Linalg` and `Std.ParallelHost`, all
reported `uncacheable`) takes 1.65 to 1.72 s against 1.50 to 1.74 s for one that
imports none of them, a difference inside the run-to-run noise (at most 0.2 s of
a build dominated by clang). A serialiser for `SourceFile` or the site tables is
not justified.
