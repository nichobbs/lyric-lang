# `self: inout` receivers write the caller's place on every target (#8179)

A method with an `inout` receiver (`func reset(self: inout Pt)`) parsed and
type-checked, but an assignment to `self` was silently lost on dotnet (the
caller kept its old value) and failed in codegen on the JVM (J008) and native
(N0007). docs/01 §5.2 gives every parameter a mode and D037 makes the
receiver the method's first parameter, so `self: inout` is part of the
language; it now works on dotnet, the JVM and native.

A backend method takes its receiver as the host `this`, which cannot be
rebound, so the middle end (`Lyric.Pipeline`, new `byref_receivers.l`) lowers
such a method to the D037 function it stands for and passes the receiver as
an ordinary `inout` argument. No backend needed a receiver-specific change.

- **Before type checking** (`hoistByRefReceiverMethods`, in
  `pipePrepareForCheck`, so the LSP sees it too): each record-body method with
  an `inout` receiver becomes the dot-named function `func Pt.reset(self:
  inout Pt)`, with the record's type parameters, its own visibility or the
  record's, and its bare field and sibling-method uses written on `self`
  (the machinery D173 uses for value-generic records). A remaining method's
  bare call of a hoisted one becomes `self.m()`. Contract metadata, sibling
  packages and restored consumers all see the dot-named function.
- A hoisted method of a generic record names its own record through its
  package (`XLib.Box[T]`, `XLib.Box(v = v)`) in its signature, annotations
  and constructor calls, since `Lyric.Mono` specialises it into each calling
  package, where a caller's own `Box` would otherwise capture the
  construction. It also carries a marker annotation
  (`recordMethodMarker`) so the aspect weaver leaves it unwoven like every
  other record method; before, aspects wove `inout`-receiver methods but not
  `in` ones.
- **Type checker.** A method call or a type-qualified call (`T.m(...)` or
  `Pkg.T.m(...)`) that resolves to a dot-named function with any
  `out`/`inout` parameter is recorded (`SymbolTable.byRefDotCallSites`),
  named through its package whenever it is another package's function,
  generic or not, so `Lyric.Mono`'s qualified-call table picks the
  declaring package's generic over a caller's same-named function. Method
  syntax now finds another package's dot-named function past a caller's
  same-named one (every package's `T.m` is a candidate, the receiver's type
  decides), and `Pkg.T.m(...)` resolves to the function package `Pkg`
  declares; before, neither was type-checked, and both miscompiled on
  dotnet and the JVM. Its argument order (D171) is
  recorded in the rewritten shape, the receiver a by-reference argument, and
  the receiver is no longer recorded as an operand the `?`/`await` hoist
  binds. New diagnostics:
  - **T0165**: an `out` receiver, an `inout` receiver on an interface
    method or `impl` method, or an `out`/`inout` receiver on a protected
    type's entry or function.
  - **T0166**: the receiver of a by-reference receiver is not a writable
    place (a `val`, an `in` receiver, a module-level binding, a call result,
    or a field path starting at a module-level binding or a call result; an
    indexed element names #8180).
  - **T0085** also covers a module-level binding passed to any `out`/`inout`
    parameter, which every backend failed on with an internal error.
  - **T0087** now covers `self = ...` when the receiver is not `inout` (it
    was accepted and miscompiled the same way).
- **After type checking** (`rewriteByRefDotCalls`, before the D171
  argument-order rewrite and the `?`/`await` hoists): each recorded call
  becomes a plain call of the function, `Pt.reset(p)`, so the receiver is
  evaluated first and passed as a place, never a copy.
- **After `?`-propagation and again after mono** (`renameByRefReceivers`):
  the `self` parameter of each function with an `inout` receiver becomes an
  ordinary parameter name and every `self` in its body reads it, so no
  backend treats it as a host `this` (a free function whose first parameter
  was `self: inout T` crashed dotnet with SIGSEGV before). The first pass
  covers generic functions exported to sibling packages (native instantiates
  those itself); the second, specialisations of a restored package's body.
- **JVM** (`Jvm.Bridge.collectDeriveFreeSigs`): a dot-named function first
  registered after mono, such as a specialised `Box.put__Int`, now records
  its holder-array parameter types and modes, so its call wraps the
  `out`/`inout` holder (it was `NoSuchMethodError`).
- **Native** (`Lyric.LlvmCodegen.lowerGenericFnCallWith`): a generic
  function native instantiates itself (one from another package, or a
  generic record's method) passed each `out`/`inout` argument's value where
  the instantiation takes its address, so the callee wrote through the value
  (SIGSEGV). It now passes the place's address (`lowerByRefPlace`, split out
  of `lowerByRefArg`), binds type arguments from the place's type, and
  requires the place's type to match the instantiated parameter exactly, as
  for a non-generic call. This also fixes the native half of #8182
  (`b.into(x)` on `func into(self: in Box[T], x: inout T)` prints 42).
- **#8183 (method-call half):** `a.into(y, 3)` on `func Acc.into(self: in
  Acc, x: inout Int, j: in Int)` passed `y` by value (InvalidProgramException
  on dotnet, VerifyError on the JVM). The same rewrite makes it the plain call
  `Acc.into(a, y, 3)`, which passes `y` by reference; it prints `y = 103` on
  all three targets.

Tests:

- `inout_receiver_self_test.l` (21 cases; dotnet, JVM and native): assigning
  `self` whole on a value record, bare field and sibling-method uses, both
  call forms, a dot-named `inout` receiver, a function whose first parameter
  is `self: inout`, field writes and a value-returning `inout` method, a
  contract with `old(self.n)`, a field path and a nested field path as the
  receiver, receivers in nested calls (evaluation order), an argument that
  reads the receiver, an `inout` receiver call as another's argument, an
  `inout` parameter passed on as a receiver, generic records (`Box[Int]`,
  `Box[String]`, a second `inout Box[T]` parameter, and #8182's `in` receiver
  with an `inout T` parameter), and calls next to `?` in both forms.
- `inout_receiver_closure_self_test.l` (4 cases; dotnet and JVM): a receiver
  captured by a closure (read and written through the closure), a generic
  captured receiver, and a call inside a lambda.
- `typechecker_self_test.l`: T0165 (including protected members), T0166
  (including the #8180 message, module-level and call-result roots), T0085
  for a module-level argument, the `self` T0087, and an aspect leaving a
  hoisted method unwoven.
- `scripts/ci/inout-receiver-e2e.sh` (dotnet, JVM, native): a two-package
  project, and the same application against the library built on its own,
  calling the library's record method and dot-named function with `inout`
  receivers in both forms, a generic record's `inout` method, and generic
  functions with `inout` parameters; and three applications with their own
  `Box` (with a `set`, without one, and at `String`) calling the library's
  generic `Box[T].set`.

The self-tests are in `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh`, the ilverify consumer list, and
`native-backend-self-tests.sh` (the non-closure file); the e2e script is in
`compiler-self-tests-batch.sh` (dotnet, JVM) and
`native-backend-self-tests.sh` (native).

Not covered:

- An indexed element as the receiver is T0166 until an element can be passed
  by reference at all (#8180).
- Native captures `var`s by value (#7891 item 1), so the closure file does not
  run there.
- A generic *free* function of another package specialised into a caller
  still names types in the caller's scope (a same-named caller record
  captures its constructions); that is the open #7917/#7372 family, not
  closed here, since only hoisted methods get their own record qualified.
- A bare field name inside an `in` record method still fails on native
  (N0007, the record-method counterpart of #7637); `inout` methods are not
  affected, since the hoist writes their field uses on `self`.
