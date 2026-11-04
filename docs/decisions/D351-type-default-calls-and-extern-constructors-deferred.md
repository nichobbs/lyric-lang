# D351 - Typing `default()`; extern constructor results deferred to host subtyping (docs/70 phase 3a, D338, D342, #8613)

**Status:** accepted; second slice of the non-callee silent `TyError` sites.

## Decision

1. **`default()`** has the type its context expects (docs/01): where the
   checker has an expected type that is not a hole (annotated `val`/`var`,
   argument, return), `inferExprExpectedCore` returns it before `inferExpr`
   runs, so no silent `TyError` is created at all. A user function named
   `default` is an ordinary call and is not affected (a test pins it). With no
   expected type the call stays untyped (31 sites -> 0 on the compiler and
   stdlib closure); the no-context form becomes the "cannot infer" diagnostic
   with the I0001 switch.
2. **`T.new(args)` on an `extern type T` is not typed here.** The first version
   of this entry typed it as `T`; CI showed it exposes code that relied on the
   silent `TyError`: `JByteArrayInputStream.new(bytes)` returned where its host
   base class `JInputStream` is declared (`lyric-grpc` JVM kernel), and
   `JString.new(...)` where `String` is declared (`Std.FileHost`). The checker
   has no extern subtyping (the only upcast is `externAsObject`, to the root),
   and an extern alias of the host `String` is not Lyric's `String`.
   Typing constructors needs host-hierarchy assignability through
   `Jvm.AutoFfi`/`Jvm.ClassReader` (superclass chain) and `Msil.MetadataReader`
   (base types and interfaces), the same metadata docs/70 5.3 names for extern
   members. That is its own slice (issue linked from #8613); until it lands the
   28 `.new` sites stay in the census.

## Census delta (`LYRIC_TYERR_CENSUS=1 ./scripts/bootstrap.sh --stage 2`)

| | D342 | now |
|---|---|---|
| non-callee | 386 | 355 |

Remaining non-callee: 241 call results (extern `.new` 28, host methods `.clear`
22, `.Dispose` 8, `.add` 6 and other extern calls), 102 member reads (extern
properties, a few `.length`/`.count`) and 12 others (5 operators, 3 `if`, 3
`index`, 1 `match`). Next: host-hierarchy assignability for extern types, then
extern members and constructors through host metadata, then the operators.
