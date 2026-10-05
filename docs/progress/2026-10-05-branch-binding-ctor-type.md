# An unannotated `if`/`match` binding builds every branch at its type (#8108)

`val r = match o { case Some(x) -> x; case None -> Ok(value = d) }`, with
`o: Option[Result[Int, String]]`, built the `Ok` branch on `--target dotnet`
as `Result_Ok<int, object>`: `Ok(...)` fixes the value type but not the
error type, and nothing gave the branch the binding's type. The IL was
unverifiable (`StackUnexpected` at the join; `ilverify-required` caught it
in the verifier's own `coerceMonadTerm`), and a later `match` on the value
never recognised it ("match not exhaustive"). The JVM erases generics and
was unaffected.

The type checker now records the checked type of an unannotated `val`,
`var` or `let` whose initializer is an `if` or `match` of a closed generic
type as the binding's annotation (`recordLocalBranchType`, through the
existing `localBindingTypeSites` → `Lyric.Mono` path that function-valued
bindings use), so every branch is lowered with it as its construction
context, as an annotated binding's already is.

Verified by `lyric-compiler/lyric/branch_binding_ctor_type_self_test.l`
(5 tests, dotnet and JVM; in the compiler, JVM-generics and ILVerify
self-test lists), which fails 4/5 on dotnet without the fix, and by the
ILVerify gate over the whole self-hosted closure.
