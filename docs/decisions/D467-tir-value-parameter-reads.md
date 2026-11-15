# D467 - A value-generic parameter is read in the TIR by `XValueParam` (docs/70 §6.2, #8613)

**Status:** accepted (the model and verifier shipped; the builder follows).

## Context

About 14 bare names in `impl` methods of the ecosystem and compiler census are reads of a value-generic parameter (`N` of `N: Nat`). The TIR could name such a parameter in a type (`ArrayLen.ALParam`, `TLen`, a `TTypeParam` with `valueTy`) but had no expression for reading it as a value. The owner chose, between specialising value generics before the TIR (option A) and adding a value-generic parameter kind to the TIR (option B), option B.

## Decision

- `TExprKind.XValueParam(owner, index)` is the value of the value-generic parameter `index` of `owner`; the node's type is that parameter's `TTypeParam.valueTy` (`Nat` for `N: Nat`). The kinded parameter (`valueTy`) and the type-level reference (`ALParam`, `TLen`) already exist, so the model change is this one case.
- Value generics stay generic in package interfaces and in the TIR: a call instantiates them like type parameters, and monomorphisation (phase 3c) removes `XValueParam` together with the type parameters. They are not specialised before the TIR.
- `Lyric.Tir.Verify` rule `value-param`: the owner is the function being verified, the index is one of its generic parameters, that parameter is a value parameter (`valueTy` is set), and the node's type is its `valueTy`.
- The interface codec carries default-argument expressions only (`defaultCarriable`), and a default never reads a value parameter of its callee, so the codec has no tag for the case. `iface_dump` prints it.
- `llvm_tir.l` names it in the "expression kind it cannot lower" reason, so a native function that reads one falls back to the AST path until phase 3c.

## Not covered

The builder (`TTypeParam.valueTy` is still `None` everywhere, and a bare `N` in an `impl` method is still an I0002) is the next change, on top of this model.
