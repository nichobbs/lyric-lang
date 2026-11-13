# D481 - A name read before a later call that may change it is bound to a temporary when names reorder the arguments (docs/70 phase 3a, #8613, #9076)

**Status:** shipped; extends D575 and D171.

## Context

Arguments are evaluated in the order written. When named arguments reorder them, D575 binds every argument that is not a literal or a name to a temporary in source order, and the call takes the temporaries. A name was left in place, but a name is read when the call runs, after the temporaries: in `two(b = x, a = zero(x))` with `zero(x: inout Int)`, the call read `x` after `zero(x)` had set it to 0, where the source order reads `x` first (the 4a native lowering found it; `named_arg_eval_order_self_test.l`).

## Decision

When names reorder the arguments, an argument that is a name is also bound to a temporary when a later-written argument is not a literal or a name (a call, which may change the local). A name followed only by literals and names is read in place, as before, so ordinary reordered calls gain no temporaries.

## Tests

`tir_build_self_test.l`: the reproduction builds, verifies, and binds both `x` and the call to temporaries (183 pass).
