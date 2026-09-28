# Type checker: reject implicit slice[T]/List[T] assignability, both directions (#7545, D-progress-1025)

The self-hosted type checker (`lyric-compiler/lyric/type_checker/`)
accepted passing a `slice[T]`-typed value wherever a `List[T]` was
expected — a call argument, a constructor field, a `val`/`var`/`let`
binding, an assignment target, or a declared return type — via a blanket
exemption in `argSatisfiesParam` (`typechecker_exprs.l`). The two types
have distinct runtime representations on every backend (`T[]` vs
`List<T>` on `--target dotnet`, a real array vs `ArrayList` on
`--target jvm`), and neither backend inserts a conversion at the boundary,
so the exemption produced `InvalidCastException` on dotnet and a
class-verifier `VerifyError` on the JVM. #7524 (2026-09-27) made an
un-annotated list literal (`val xs = [1, 2, 3]`) consistently keep the
`slice[T]` runtime representation on the JVM backend too, which turned a
previously-latent gap into a routinely-hit one.

`docs/01-language-reference.md` §2.7 has always documented the conversion
between the two as explicit (`.toList()`/`.toArray()`); the fix enforces
that. The exemption is removed from `argSatisfiesParam`, the single
function every one of the call/return/bind/assign checks above routes
through. A new, narrower rule takes its place for the one case the removal
would otherwise have regressed: a bracket literal (`[...]`) used directly
where a `List[T]` is expected now types (and is built) as `List[T]` on the
spot — `inferExprExpected`'s new `EList` arm for bindings and assignment,
`listLiteralArgSatisfiesParam` for constructor-field and call arguments —
since both backends' own literal codegen already consults the surrounding
expected type to build the right representation, independent of what type
the checker infers for the literal expression standing alone. This keeps
`val xs: List[Int] = [1, 2, 3]`, `R(items = [1, 2, 3])`, and
`f([1, 2, 3])` (against a `List[Int]`-typed field/parameter) type-checking
with no `.toList()` needed, while a genuine `slice[T]`-typed *value* in
any of those positions is now rejected. Every affected diagnostic
(T0041/T0043/T0060/T0061/T0062/T0063/T0065/T0070/T0104) is reused as-is —
this tightens an existing check family rather than adding a new one — but
each message now appends a `sliceListConversionHint` suffix naming the
explicit `.toList()`/`.toArray()` fix when the mismatch is specifically
this shape.

See D-progress-1025 for the full design rationale, including why the
literal-typing widening is sound (gated on the argument EXPRESSION being
an `EList` node, never on its inferred type, so a real slice value can
never take that path) and the one position it deliberately does not cover
(`return [1, 2, 3]` against a `List[T]` return type — that position never
had the old exemption either, so this is pre-existing, unchanged
behaviour, not a new gap).

`docs/01-language-reference.md` §2.7 gained a paragraph describing this
non-assignability and the literal exception. `lyric-compiler/lyric/
typechecker_self_test.l` gained thirteen new cases covering both
directions of the rejection (call argument, constructor field, binding,
assignment, return), the `.toList()`/`.toArray()` conversions, the
diagnostic hint text, and every literal-acceptance case (binding,
constructor field, empty literal, plain call argument).

No call site anywhere in the compiler, the standard library, or any of the
30 ecosystem libraries/examples relied on the removed exemption for a
non-literal slice value — a full sweep (`make self-test NAME=typechecker`,
`scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh`,
`scripts/ci/native-backend-self-tests.sh`,
`scripts/ci/jvm-ecosystem-suites.sh`, `lyric test --manifest` for every
`lyric-*/lyric.toml` and `examples/*/lyric.toml` on `--target dotnet`, and
every ci.yml `--target jvm` self-test file) turned up zero regressions.
