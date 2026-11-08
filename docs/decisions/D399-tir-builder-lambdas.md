# D399 - The builder's lambdas and captures (docs/70 phase 3a, #8613)

**Status:** shipped (`buildLambda`, `noteCapture` in `build_expr.l`); extends D398.

## Context

A lambda was an I0002. `XLambda(params, captures, body)` needs the parameters as
locals, the body in their scope and the set of outer locals the body uses, each
captured by value or by reference.

## Decision

1. `buildLambda` takes the parameter types and the result type from the
   function type the checker recorded for the lambda (`TFunc`), so an unannotated
   parameter has its inferred type. The parameters are declared in a new scope
   after the lambda's start mark, the body block is built and converted to the
   result type as a branch is (D396), and the node is `XLambda`.
2. Captures are found while building, not by a second walk: `BuildEnv.lambdas`
   is a stack of `LambdaFrame { start, caps }` where `start` is the highest local
   number declared before the lambda began. `lookupLocal` calls `noteCapture`:
   a local numbered at most `start` is outside the lambda and is captured by it
   and by every enclosing lambda it is also outside of, `CmByRef` when the
   local is a `var` and `CmByValue` otherwise.
3. Also: `indexKindOf` (D398) tells the stdlib `List`/`Map` from a user type of
   the same name by the declaring package (`Std.CollectionsHost`), from the #8903
   review.
4. Not built yet: a lambda whose type has a different parameter count than its
   parameter list (counted), and the captures of a generic function's `Self`.
