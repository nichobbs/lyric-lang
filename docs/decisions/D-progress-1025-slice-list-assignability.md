# D-progress-1025 — Type checker: `slice[T]` and `List[T]` are no longer mutually assignable (#7545)

**Status:** shipped

**Context.** `docs/01-language-reference.md` §2.7 has always documented the
conversion between `slice[T]` and `List[T]` as explicit —
`xs.toList()`/`ys.toArray()` — and never describes an implicit path between
them. Despite that, `Lyric.TypeChecker`'s `argSatisfiesParam`
(`typechecker_exprs.l`) carried a blanket exemption: any `slice[T]`-typed
argument satisfied a `List[T]`-typed parameter, field, or `val`/`var`/`let`
binding whenever the element types matched, with a comment claiming "the
emitter treats the two as the same runtime type." That was never true on
either backend: MSIL lowers `slice[T]` to a CLR `T[]` and `List[T]` to
`System.Collections.Generic.List<T>`; the JVM lowers `slice[T]` to a real
`Object[]` array and `List[T]` to `java.util.ArrayList`. A genuine
`slice[T]`-typed *value* (a variable, a function's return, `.toArray()`'s
result, …) admitted through this exemption crashed at the call boundary —
`InvalidCastException` on `--target dotnet`, a class-verifier `VerifyError`
on `--target jvm` — since neither backend inserts a conversion for a case
the checker told it was already assignable.

The gap was latent until #7524 (2026-09-27, `docs/progress/2026-09-27-jvm-
static-type-recovery.md`) made an *un-annotated* list literal
(`val xs = [1, 2, 3]`) consistently keep the erased `slice[T]` runtime
representation on the JVM backend too (it previously silently kept an
`ArrayList` there, which happened to match `List[T]`'s own representation and
masked the checker bug by accident). After #7524, the same slice-typed local
reliably hit the crash the moment it flowed into a `List[T]`-expected
position on either target.

**Decision.**

1. `argSatisfiesParam`'s slice→List exemption is removed. `slice[T]` and
   `List[T]` are now mutually exclusive except for `typeEquiv`: a genuine
   `slice[T]`-typed value never satisfies a `List[T]`-typed parameter, field,
   binding, assignment target, or return type, and vice versa (no such
   exemption ever existed in that direction). This is a straightforward
   enforcement of the already-documented §2.7 semantics, not a new rule.
   `argSatisfiesParam` is the single function all of these call/return/bind/
   assign checks route through (`typechecker_exprs.l`,
   `typechecker_stmts.l`), so the fix lives there once rather than being
   special-cased per call site.

2. **New sub-decision, since the spec is silent on it:** a bracket literal
   (`[...]`) used directly where a `List[T]` is expected is typed *as*
   `List[T]`, not `slice[T]` — both when it initialises a `List[T]`-annotated
   `val`/`var`/`let` binding or assignment target (`inferExprExpected`'s new
   `EList` arm, `typechecker_exprs.l`) and when it is passed as a
   constructor field argument or ordinary call argument
   (`listLiteralArgSatisfiesParam`, gated on the argument EXPRESSION itself
   being an `EList` node, never on its already-inferred type). This is sound
   because a literal's runtime shape isn't fixed by the checker's inferred
   type at all: both backends' own `EList` codegen already builds whichever
   representation the surrounding declared/parameter type calls for
   (MSIL's `collExpectTop`/`MConcreteList` vs `MArray` dispatch; the JVM's
   ArrayList-by-default literal lowering, left untouched when the target is
   already `List[T]` and converted via `.toArray()` only when the target is
   `slice[T]`) — independent of what type the checker assigns the literal
   expression. A real `slice[T]` *value* can never take this path, since it
   is gated on the argument being a literal `EList` node, so the crash this
   entry fixes cannot reopen through it. This lets
   `val xs: List[Int] = [1, 2, 3]`, `R(items = [1, 2, 3])`, and
   `f([1, 2, 3])` (for a `List[Int]`-typed field/parameter) keep type-checking
   exactly as before, with no `.toList()` needed — matching what codegen
   already produced correctly for the literal case — while a `slice[T]`
   variable or expression passed to the same position is now rejected and
   must call `.toList()` (or `.toArray()` for the reverse).

3. Diagnostics: every existing type-mismatch diagnostic that can now fire on
   a slice/List mismatch (T0041 list-literal-element, T0043 call argument,
   T0060/T0061/T0062 val/var/let binding, T0063 assignment, T0065/T0070
   return, T0104 constructor field) is reused as-is — this is a stricter
   application of an existing check family, not a new error category — but
   each message now appends a `sliceListConversionHint` suffix
   (`" (use .toList() to convert the slice to a List)"` /
   `" (use .toArray() to convert the List to a slice)"`) whenever the
   mismatch is specifically this shape, pointing directly at the documented
   §2.7 conversion.

**Verification.** `lyric-compiler/lyric/typechecker_self_test.l` gains cases
for: a `slice[T]`-typed value rejected as a `List[T]` call argument, field,
binding, and return; a `List[T]`-typed value rejected as a `slice[T]`
argument; a list literal still accepted (and correctly typed as `List[T]`)
in a binding, a constructor field, and a plain call argument; and
`.toList()`/`.toArray()` accepted at each of those positions. All 588 (now
more) `typechecker_self_test.l` cases pass, plus
`scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh`,
`scripts/ci/native-backend-self-tests.sh`,
`scripts/ci/jvm-ecosystem-suites.sh`, every `lyric-*/lyric.toml` and
`examples/*/lyric.toml` test suite on `--target dotnet`, and every ci.yml
`--target jvm` self-test file.

**Scope note.** The literal-contextual-typing widening (point 2) covers
`val`/`var`/`let` bindings, plain assignment, constructor field arguments
(named and positional, generic and non-generic constructors), and ordinary
function-call arguments (both the direct-signature and function-value-typed
call paths). It does not cover a bracket literal in `return` position
against a `List[T]`-declared return type — that position never had the old
exemption either (it type-checks through `typeAssignable`, which never grew
the slice→List carve-out `argSatisfiesParam` had), so `return [1, 2, 3]`
against a `List[T]` return has always required an explicit `.toList()` and
this entry does not change that pre-existing, spec-consistent behaviour.
