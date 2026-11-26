# D512 - Methods of pub records and impl members are public invariant boundaries on TIR

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §7.2; follows D507 and D509)

## Decision

1. **`MemberSite.isPublic`** marks a member that is part of the public invariant boundary, with the AST pass's rule (`elaborateItem`, docs/08 §7.1): a method of a `pub` record, and every `impl` member. A method of a record that is not `pub`, and a protected-type member, are not (a protected member carries its own type's invariants, D509).
2. The builder sets `TFnDecl.isPublic` from it (or from the function's own `pub`), so `Lyric.Tir.Contracts` applies D507's boundary checks to those members unchanged: an `in` or `inout` parameter of another package's invariant type is checked on entry, and an `inout`/`out` parameter or the result of any bundled invariant type at exit, with `InvariantViolated: Pkg.Type.member parameter p` / `result`.
3. The receiver `self` is an ordinary parameter of the member, so a receiver of an invariant type is checked like any other.

## Not done

Generic invariant types at the boundary (the AST pass does not check them either; docs/01 §6.2 tracks it under #7222), a checker held only in a restored interface, and `exposed record` methods (not built as members yet).
