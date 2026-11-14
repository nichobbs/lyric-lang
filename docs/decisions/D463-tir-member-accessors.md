# D463 - `d.value` of a distinct type and the `Option`/`Result` accessors build as an unwrap and a call (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

The census counted "a member access that is not a record field" for two families: `d.value` on a distinct type (derived `toString`/`equals`
of `type Age = Int`, `pluginEncodeDocId`), and the bare `o.isSome` / `o.isNone` / `r.isOk` / `r.isErr` on the real `Std.Core` `Option` and
`Result` (`Chan.take`, `firstPositive`). Neither is a record field; the second form has no `Call` node, so no callee was ever recorded.

## Decision

- `d.value` of a non-generic distinct type is `XConvert(CvUnwrapDistinct)` of the receiver, typed as the checker typed the access.
- The checker records, for the four bare accessors on the genuine `Std.Core` `Option`/`Result` (`monadAccessorType`), the `Std.Core` function of
  the same name under the member expression's `NodeId` (`calleeByNode`, `callSigByNode`) with the receiver's type arguments
  (`genericArgsByNode`). The builder makes it a `Direct` call of that function with the receiver as its `in` argument. A user type named
  `Option` or `Result` is not recorded (the signature's origin package must be `Std.Core`).
- `.value`/`.error` on `Option`/`Result` are not covered here: they have no function to call (they read a case payload) and stay counted.
