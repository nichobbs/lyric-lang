# D351 - Typing extern constructors and `default()` (docs/70 phase 3a, D338, D342, #8613)

**Status:** accepted; second slice of the non-callee silent `TyError` sites.

## Decision

1. **`T.new(args)` on an `extern type T`** (docs/48) is a `T`: the member-call
   fallback (`untypedMemberCallResult`) resolves the receiver's single-segment
   path to a `DKExternType` symbol and returns `TyUser(id, name)`, the same
   type `rootExternObjectType` and the extern-type resolver build. Constructor
   argument checking against host metadata stays with the F0020-F0034
   family; this rule only gives the call its result type. 28 sites.
2. **`default()`** has the type its context expects (docs/01): where the
   checker has an expected type that is not a hole (annotated `val`/`var`,
   argument, return), `inferExprExpectedCore` returns it before `inferExpr`
   runs, so no silent `TyError` is created at all. A user function named
   `default` is an ordinary call and is not affected. With no expected type
   the call stays untyped (31 -> 0 on the compiler and stdlib closure; the
   no-context form is the T0224-style "cannot infer" diagnostic, still to do
   with the gate).

## Census delta (`LYRIC_TYERR_CENSUS=1 ./scripts/bootstrap.sh --stage 2`)

| | D342 | now |
|---|---|---|
| distinct silent sites | 10,856 | 10,803 |
| non-callee | 386 | 327 |

Remaining non-callee: 213 call results (host methods `.clear` 22, `.Dispose`
8, `.add` 6 and other extern calls), 102 member reads (extern properties, a few
`.length`/`.count`) and 12 others (5 operators, 3 `if`, 3 `index`, 1 `match`).
Next: extern member calls and properties through host metadata, then the
operators.
