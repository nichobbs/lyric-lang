# Dot-named method calls: enum receivers, async `self`, lambdas capturing `self` (#8254, #8253, #8291, #8037)

- A qualified enum case value (`Color.Red`, `Pkg.Color.Red`) now has the type of its enum. It was untyped, so
  `val c = Color.Red; c.num()` found no dot-named `Color.num`, passed type checking and failed at run time on
  dotnet ("unsupported method"), at verification on the JVM and as `N0007` on native. An enum receiver of a dot-named
  call is also rewritten into the plain call `Color.num(c)`, as a primitive's is, since an enum is a bare tag on
  every backend (`receiverNeedsPlainDotCall`).
- dotnet, `async func T.m(self: in T)`: `self` is an ordinary parameter of a dot-named function and lives in a field of
  the state machine, so it is read like any parameter instead of through `ldarg.0` (the machine itself). The await
  pre-scan types a dot-named call through the type (`Acc.aGet(a, 3)`, resolved under the package-qualified name) and a
  receiver bound to a non-generic record construction (`val a = Acc(n = 1)`), so an `await` on either counts.
- dotnet, a lambda that reads `self` in a dot-named function captures the parameter with its declared type; it captured
  the receiver as an unnamed class, which verified as invalid IL (`InvalidProgramException`) for a value-type field and
  as an untyped operand (`T0120`) for a reference-type one.
- #8037: union, `Option` and generic-record receivers of dot-named calls already resolve and run on dotnet and the JVM
  on main; `dot_named_receivers_self_test.l` pins them, including an `await` in the arguments of a call on a `None`
  receiver.
- Tests: `dot_named_receivers_self_test.l` on dotnet, JVM and native, and in the ilverify list.
