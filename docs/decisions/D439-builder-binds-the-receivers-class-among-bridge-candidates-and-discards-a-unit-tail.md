# D439 - A host chain binds the receiver's own class among bridge-method candidates, and a `Unit` function discards its last value (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444 and D445. The checker is unchanged.

## Context

`Std.StringHost.hostAppend` is `sb.append(s)` as the tail of a `Unit` function on a `java.lang.StringBuilder` (a deliberate tail form, #5379). Two gaps kept it counted.

- `StringBuilder.append` is overridden with covariant returns, and the host compiler adds bridge methods that return `AbstractStringBuilder` and `Appendable`. The chain typing refused a member whose candidates did not agree on one result.
- Once the call was typed `StringBuilder`, the function body had that type where `Unit` is declared (the verifier's `branch-type: function body`, 2 I0003 in `Std.StringHost`).

## Decision

- When the candidates of a host member differ, the result that is the receiver's own class wins (`isHostClassTy`): the covariant override is what a call binds. Candidates that differ in no such way still leave the member counted.
- A function that returns `Unit` discards the value of its last expression (language reference section 2): `discardTailValue` turns a non-`Unit`, non-diverging tail into a statement and types the body `Unit`. A body of `Never` is left alone. A generator is not touched.

## Results

`Std.StringHost` builds 9 of 9 with 0 I0003. `jvm_host_kernel_shapes` gains `appendTail`; `make self-test NAME=tir_build` passes 234 of 234.
