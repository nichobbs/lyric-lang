# D515 - Equality of a tuple or union holding an array is expanded on TIR

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §7.2; amends D506 item 3, follows D167)

## Decision

1. **`shapeEqCore` has a step for the two `EqShape`s that had none.** A tuple (`ESTuple`) is `match a { case (x0, x1..) -> match b { case (y0, y1..) -> <x0 == y0> and ... } }`; a union (`ESUnion`) binds both operands to locals and is `match l { case C(x..) -> match r { case C(y..) -> <parts>; case _ -> false } ... }` over the cases the checker recorded, each named by the last segment of its written path, its payload types read from the case's signature at the union's arguments. Each part is compared by its own shape, so an array part is the element loop (D506), a `Float` part has the NaN rule (D172) and a nested tuple or union recurses. The forms are those of `eqShapeExpr` on the AST; they use typed `TpTuple` and `TpCtor` patterns, no new node.
2. **Both places the checker records such a shape use it.** A record leaf in `wrapLeaves` (a tuple, union or distinct type holding an array) is compared by its shape instead of keeping the single `IoEq`, and a direct `==`/`!=` with a `wrapEqSites` entry is built by `buildWrapEq` (negated for `!=`). A shape whose parts cannot be read keeps the one `IoEq`/`IoNeq`, never an I0002.

## Effect

A native function comparing such a value no longer needs the AST fallback ("an operator on (Int, array[2, Int])"). D506's remaining single-`IoEq` case is a leaf path through a generic record.
