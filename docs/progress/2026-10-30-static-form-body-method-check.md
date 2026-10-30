# A static-form call of a body method is argument-checked (#8104)

`T.m(x, args)` where `m` is a method declared in the body of `T` (and the
package declares no dot-named `T.m`) is checked against the method's signature
with the receiver as the first argument. Before, a call whose arguments the
method could not take (`Acc.add(a)` for `func add(self: in Acc, k: in Int)`)
resolved to nothing, was not checked, and failed later: an internal compiler
error in codegen on some builds and `InvalidProgramException` at run time on
others. It is now T0042 (count) or T0043 (type), as for `a.add(...)`.

The fix is in `typeQualifiedDotSig`
(`lyric-compiler/lyric/type_checker/typechecker_exprs.l`): when neither a
dot-named function nor an applicable body method takes the call, it falls back
to the type's body method of that name, with the receiver put back as the
first parameter, so the mismatch is reported against a real signature.
Regression test: `static-form call of a body method is argument-checked
(#8104)` in `typechecker_self_test.l`.

Other items of #8104 were already fixed on main: the dot-named form (test
`a type-qualified call T.m(x, args) is checked like x.m(args)`), protected-type
overloads (T0209), and native bare sibling calls inside a record method
(verified: a program calling a sibling method by its bare name prints the right
value on `--target native`).
