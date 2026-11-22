# A tuple literal and a negated float literal convert element by element (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder.

## Context

`val ok: (Int range 0 ..= 3, String) = (two(), "a")`, `takePair((two(), "a"))` and `Vec2(x = 1.5, y = -1.0)` with `Float` fields: the checker accepts each, but the builder had no conversion from a tuple to a tuple with refined elements, nor from a negated `Double` literal to `Float` (`range_refinement_self_test.l`, `record_arith_self_test.l`).

## Decision

`convertValue` converts a tuple literal to a tuple type by converting each element to its element type (`retypeTupleLiteral`), so a range check applies to the element it names, and retypes the negation of a `Double` literal as the negation of a `Float` literal (`retypeNegatedFloatLiteral`), as a float literal itself is.

## Results

`range_refinement_self_test.l` 21 of 21, `record_arith_self_test.l` 7 of 7.
