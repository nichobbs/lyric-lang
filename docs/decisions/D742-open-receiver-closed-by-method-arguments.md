# A call on a receiver with an open type argument is typed from the method's arguments (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`emptyCell().orDefault(5)` with `func emptyCell[T](): Cell[T]` and a method `orDefault(self: in Cell[T], d: in T): T`: the receiver's own type is `Cell[<hole>]` and the method the checker picked against it was instantiated at the hole, so the call and the receiver call both had the type `<error>`. `Lyric.Mono` recovered the type arguments from the call alone; the typed IR (D347) has no such recovery, so the TIR gate stopped the body (`open_receiver_self_test.l`, `await_hoist_typed_self_test.l`).

## Decision

When the callee's receiver is a call that leaves a type argument open (`openCallReceiver`), the receiver's type arguments the method's parameters bind from the call's arguments (and, for what they leave open, the type expected of the result) give the closed receiver type (`hoistedRecvType`). The method pick is resolved again against that closed type (`pickAtClosedReceiver`), so the call has its closed result type, and the checker's type of the receiver node becomes the closed instantiation (`recordClosedReceiverType`). A receiver the arguments do not fix stays an error (T0154) as before.

## Results

`open_receiver_self_test.l` 2 of 2 and `await_hoist_typed_self_test.l` 14 of 14 under the gate.
