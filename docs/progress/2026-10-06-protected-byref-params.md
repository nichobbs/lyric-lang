# `out`/`inout` parameters of protected-type members on every target (#8184)

#8184 reported that a protected-type `entry` with an `inout` parameter
compiled on dotnet but the CLR rejected the caller with
`InvalidProgramException`, while native rejected the declaration with
`N0007` ("declares 'x' as out/inout, which is not yet supported for --target
native on protected-type methods"). A comment added the same parameter on an
interface method implemented by a protected type: `TypeLoadException` on
dotnet ("does not have an implementation"), `N0007` on native. The JVM ran
both correctly.

**dotnet.** `lowerProtectedMsil` emitted every member's signature from the
parameters' plain types and never wrapped an `out`/`inout` one in a managed
pointer, although the member's body (`registerParamsMsil`) and every caller
(`methodParamModes`) already treated it as by-ref. The caller pushed an
address against an `int32` parameter (invalid IL), a generic protected
type's caller referenced `swap(!0&)`, which the class did not define
(`MissingMethodException`), and an impl method moved into the type (#7457)
no longer matched its interface slot. The signature now goes through
`byrefWrapSigTypes`, as `lowerImplMethodMsil`'s does. A protected `func` is
lowered through the same path (#7363), so it is fixed too.

A member of a generic protected type (or a generic record's method) passing
its own field on by reference (`setInt(hits)`, `setInt(self.hits)`) was
`T0120` ("out/inout field argument receiver must be a class type"):
`lowerByrefFieldReceiverMsil` accepted only a plain class receiver, while
`self` there is the open self-instantiation. It now reaches the field through
a TypeSpec-parented MemberRef, as reads and writes of such a field already
did, with a new `MLdfldaGeneric` instruction beside `MLdfldGeneric` and
`MStfldGeneric`; the three now share one token builder
(`genericFieldTokenMsil`).

**Native.** `registerProtectedMember` refused any `out`/`inout` parameter,
registered the wrapper's signature with every mode `in`, and gave the
wrapper the parameters' value types. It now records the declared modes, so
call sites pass the place (`lowerByRefArg`, D171 order, D179 copy-in and
copy-out for an array element, and `pinBorrowForByRefCall` for the
receiver), and types each by-ref parameter as a pointer, which the lock
wrapper forwards to the inner function. The inner function's own lowering
(`lowerFunctionEnv`) already bound such a parameter to the incoming pointer.
A vtable slot of an interface implemented by
a protected type already declared the pointer (#8183) and now matches the
wrapper it points at.

Writing the tests found a second native defect: a protected member written
with an explicit `self` receiver (D037), which is how an impl method moved
into the type usually reads, got a second `self` parameter
(`An item with the same key has already been added. Key: self`), so no impl
for a protected type that spells its receiver could be built.
`collectProtectedMethods`, `addGenericProtectedMember` and
`registerProtectedMember` now drop it with `withoutExplicitSelf`, as the
record impl path does.

**JVM.** Every shape in the new test ran correctly except one: a member
passing its own field by bare name to an `out`/`inout` parameter
(`addTo(total, d)`) panicked in `prepareHolderPlace` ("is not a local or
parameter"). A bare name that is a field of the receiver is now the place
`this.<name>`, filled and written back through `this` like `self.<name>`.

**What a protected member guarantees about a by-ref parameter.** The
member's own reads and writes of the parameter happen while it holds the
lock. The caller's place receives the final value when the call returns, and
that store is not part of the protected operation: the JVM copies the place
into a holder before the synchronized method and back after the monitor is
released, and an array element is copied in before the call and out after
it on every target (for a barrier entry, the copied-in value predates the
wait). A place that several threads pass in needs its own protection; shared
state belongs in the protected object's own fields. docs/01 §7.5 and book
chapter 10 say this, without promising any target's timing.

Tests: `protected_byref_self_test.l` (17 cases, dotnet, JVM, native):
entries and funcs with `inout` and `out` at `Int`, `String` and record
types, an `out` written before an early `return`, named arguments in and out
of order with the source-order trace, an argument reading the by-ref place
before the call, a field, a nested field and array elements (`Int` and
`String`) as places, the caller's own `inout` parameter, a member passing
its own field and parameter on, receivers that are a record field and an
array element, a `when:` barrier entry with `out`/`inout` parameters fed by
a second thread, a generic protected type at `Int`, `String` and record
types and passing its own field on (bare and through `self`), an interface implemented by a protected type called directly and
through the interface (including an array element), and two threads calling
one entry with their own locals. Wired into the compiler, JVM-generics and
native batches and the `ilverify` list. `llvm_inout_self_test.l` adds an
AddressSanitizer case: `String` and record arguments to entries, funcs and an
interface slot, and a protected object passed as the by-ref place of its own
entry (`c.replace(c)`), whose receiver is retained for the call so the
wrapper's unlock never reads freed memory. A two-package project calling
another package's protected entry with by-ref arguments was checked on all
three targets.

Docs: docs/01 §7.5 and the native surface paragraph, book chapter 10.
