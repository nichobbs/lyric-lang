# Generics, open types and monomorphisation fixes (#8461, #8241, #8301, #8531, #8038, #8250, #7887)

One group of `Lyric.Mono`, type-checker and native-reachability fixes, each with a
dual-target (and native where supported) self-test.

- **#8461 generic overloads of one name.** A same-package overload set with at
  least one generic member (`two[T](x)` / `two[T](x, y)`, and the defaulted
  `gen[T](x, y = 1, z = 2)` / `gen[T](x, y = 1)` shape) is tabled in
  `ambiguousFuncOverloads`; a call resolves through `resolveAmbiguousOverload`
  (argument count, argument types, then fewest defaults filled, the rule the
  checker binds by, #8355) and each overload is specialised under its own name
  (`two__o1__String`). Before, the second overload's specialisation never
  existed: T0123 on dotnet, `NoClassDefFoundError` on the JVM, N0007 on native.
  `generic_overload_arity_self_test.l`.
- **#8531 `T.default()` at a distinct type or record.** `Lyric.Mono` rewrites
  `T.default()` (and `X.default()`) at a named type to `X.from(<zero of the
  underlying type>)` or the record constructor with each field at its default
  or its own zero. `generic_default_named_self_test.l`.
- **#8038 open method receiver.** The receiver typing of #7844
  (`hoistedRecvType`) now applies to any member call whose receiver is a call
  leaving a type argument open, not only to receivers hoisted ahead of an
  `await`; T0154 when nothing fixes it. `open_receiver_self_test.l`.
- **#7887 alias locals.** `val o2 = o` from an open local registers an alias
  site whose evidence reaches the source's sites (a tuple source's children, or
  the source itself at the empty position). `open_alias_self_test.l`.
- **#8250 pattern-bound type arguments.** A name a constructor pattern binds to
  a payload typed by a type parameter of an open local is open to that type
  argument (`OpenBindingSite.argKeys`); `resolveOpenBindingSites` folds the
  fixed arguments into the local's type. `open_alias_self_test.l`.
- **#8301 stdlib generic from a generic member.** On dotnet and the JVM the case
  already passed. On native two things failed. The reachability pass never
  walked the body of a generic record's method, so a stdlib generic it calls
  (`isSome`) was not linked (N0007); `Lyric.LlvmBridge` now seeds those bodies.
  And a lambda typed by the record's (or a generic function's) own `T` passed to
  a stdlib generic (`mapOption(o, { v: T -> 3 })`) had no spelled type
  arguments, so native could not give the lambda its function type: the checker
  now records the call's type arguments over the enclosing generic's type
  parameters (`GenericCallTypeArgsSite.mentionsVars`), which only the native
  lambda spelling reads (Mono's fallback ignores them), and Mono substitutes
  them per specialisation. `generic_member_stdlib_native_self_test.l`.
  Found, not fixed: a method of a generic `impl[T]` calling a stdlib generic
  (`isSome(o)` over `Option[T]`) fails on dotnet and the JVM (`isSome__T`
  specialised over the unbound `T`) and a call to it on a concrete receiver is
  N0007 on native.
- **#8241 method-level generics on record methods.** The `in`/result shapes run
  on all three targets (`method_generic_self_test.l`). A method's own type
  parameter taken by reference (`out`/`inout`) cannot be passed on dotnet, so
  it is now the diagnostic **T0214**. Reifying method-level generics (specialising
  them like a free function) is the remaining work, so the issue stays open.
