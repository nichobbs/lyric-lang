# JVM: a package-private dot-named call's payload keeps its type in match and `?` bindings (#7631)

On `--target jvm`, `val p = Person.parse(s)?` followed by `p.name` failed
with `error[J007]: member 'name' cannot be resolved on an erased (statically
Object) receiver` whenever `Person.parse` was package-private. The direct
`match Person.parse(s) { case Ok(p) -> p.name }` failed the same way. A `pub`
function worked, and so did same-file free functions.

`?` never reaches JVM codegen: `Lyric.Propagate` rewrites it into a `match`
on the call. `Jvm.Codegen.scrutineeGenericArgs` recovered a type-associated
call's instantiation from the bare `funcSigs` key (`Person.parse`), but that
key is registered only for `pub`/`internal` functions (#6853); a
package-private function has only the scoped `<pkg>::Person.parse` keys. With
no instantiation, the `Ok`/`Some` payload was bound as erased `Object`. The
lookup now tries the calling package's scoped key before the bare key, the
same order `lowerMethodCall`'s dot-named dispatch already uses (#6664).

Verified by `lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l`, on
both targets. It covers `?` on `Result`- and `Option`-returning
package-private dot-named functions, the direct-match form, `?` on a
`@generate(Json)` record's synthesised `fromJson`, and `?` on same-file free
functions. On `--target jvm` the dot-named and `fromJson` cases fail with J007
before the fix. The test runs in `scripts/ci/jvm-generics-self-tests-batch.sh`
(JVM) and `scripts/ci/compiler-self-tests-batch.sh` (dotnet).
