# Method calls dispatch to the callee the checker resolved, across packages too (#8098, #8099)

Review follow-up to #7828/#7827 (D168).

**Dot-named or own method (#8098).** `resolveMethodCallPick` prefers a
candidate taking exactly the written arguments, and its candidates include
D037 dot-named functions of the receiver's type. The backends were told only
the resolved parameter count, and only when it differed from the written
count, so with a record method `m(self, x, y = 2)` and `func O.m(o, x)`,
`o.m(1)` resolved to the dot-named function while MSIL's bare `O.m` method
key, the JVM's `O#m` signature and native's `implDirect` lookup bound the
record method. `SymbolTable.methodCallArities` now also records a call the
checker resolved to a dot-named function, as `-1 - count`
(`Lyric.Parser.methodCallTarget` decodes it), and each backend takes the
dot-named function for such a call: MSIL through its `<Type>.<m>/<count>`
function token, the JVM by declining the type's method signature, native by
trying the dot-named function's key first. A bare call to a sibling method
resolved to a dot-named function is lowered as `self.m(...)` on MSIL and the
JVM.

**Generic impls (#8099).** `synthesizeDefaultThunks` and
`Lyric.ContractMeta.reprForImplHead` skip an `impl` with type parameters
(`Lyric.Parser.implIsGeneric`): its methods' heads named type parameters the
rendered `impl Sized for Box {}` head does not declare, so the contract did
not re-parse. A consumer passes such an argument (T0042 otherwise).

**Name encoding.** `thunkTypeKey` now spells an array's length, a value type
argument and a range subtype's bounds (`thunkExprKey`), so overloads that
differ only there get distinct thunks. A default is not exported when its
parameter's type names a type or value generic parameter anywhere (the head
of a path such as `T.Item`, an array length, a value type argument, a range
bound), or when the default reads a value generic parameter.

**Specialised generics of another package.** A body specialised from another
package's generic carries that package's spans, which the consumer's check
never saw, so the backends dispatched its method calls by the written count:
`viaGeneric(o, "s")` for a library's `pub func viaGeneric[T](o: in Ov, t: in
T): Int { o.m(1) }` called `m(x: String)` instead of `m(x: Int, y: Int = 2)`
(wrong result on dotnet, a VerifyError on the JVM), in the same build and
from a restored package alike. `Lyric.Mono` now reports every specialisation
of another package's generic (`MonoResult.foreignSpecs`), and
`Lyric.Pipeline.foreignMethodCallArities` re-checks, in the declaring
package's scope, one specialisation of each generic whose body calls a
method with a defaulted parameter or a name its owner declares more than
once, recording what the checker resolves under `<origin>|<siteKey>`; MSIL,
the JVM (`originScopedExternTypes`) and native (`Ctx.curOrigin`) look such a
body's calls up there.

docs/01 lists protected types among the exceptions (no T0162 check, no
exported defaults).

Tests: `method_default_args_self_test.l` (both targets) gains a record
method beside a dot-named function of another arity, both ways round, with
and without omitted defaults and through bare sibling calls;
`llvm_stdlib_self_test.l` the same dispatch on native (all arguments
written: native fills no method default yet, and a bare sibling call does
not lower there at all); `typechecker_self_test.l` the recorded encoding;
`contract_meta_self_test.l` the generic-impl contract, array-length,
value-argument and range-bound spellings, and the unexported defaults;
`restored_default_args_self_test.l` the generic impl (both targets), the
restored dot-named dispatch (both targets), and the cross-package
specialised generic in a two-package build (both targets) and restored
(dotnet; a restored generic function is not callable on the JVM yet).
