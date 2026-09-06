# D-progress-886 — Type checker: T0126 rejects a `for` loop over a non-iterable single-type-param generic (#6720)

**Status:** shipped

**Context.** D-progress-818 broadened `SFor`'s single-type-parameter generic
element-typing fallback (`typechecker_stmts.l`) to type the loop element for
ANY single-param generic, not just the literal name `List` — motivated by
the extern phantom-type-param collection idiom (`extern type
JHttpStringCollection[T] = "java.util.Collection"`, `Set[T]`, etc., #6565).
That widening also silently typed the loop element for a genuinely
non-iterable single-param generic that merely happens to have one type
parameter — a Lyric-native `Option[T]`-shaped union is the concrete case —
with zero diagnostics. Codegen's index-loop fallback
(`emitCollectionForMsil`'s `case _` in `msil/codegen.l`, which assumes
`.Count`/`get_Item`) then fails at runtime with a cast or member-lookup
exception instead of the build failing at compile time. Raised as a
non-blocking SUGGESTION during review of PR #6717 (which shipped
D-progress-818).

**Fix.** Added `symTableIsExternTypeId(tbl, id): Bool`
(`typechecker_symbols.l`) — a linear scan (once per `for` statement, not per
element access, so no side index is warranted) checking whether a `TypeId`
belongs to a registered `DKExternType`. `SFor`'s single-param-generic
fallback now only fires when the type is `List`/`MapKeyCollection`/
`MapValueCollection` (unchanged) OR the type is a genuine `DKExternType`
(covers `Set[T]`, `JHttpStringCollection[T]`, and any other extern
phantom-type-param collection). Any other single-param generic — a
Lyric-native union/record/opaque that happens to have one type parameter —
now emits a new diagnostic, **T0126**, at the `for`-loop site, mirroring
`SWhile`'s condition-type check in the same file.

**Verification.** New self-tests in `typechecker_self_test.l`: a `for` over
a non-iterable single-param union (`Box[T]`) emits T0126; same for a
non-iterable single-param record (`Wrap[T]`); a `for` over an extern
single-param collection (`Set[T]`) does NOT emit T0126 (regression guard for
the #6565 motivating case D-progress-818 shipped). Full
`typechecker_self_test.l` suite passes with no regressions.
