# G1 follow-ups: native default arguments and methods, JVM subnormals, protected invariants, native bench settings

Four follow-ups from docs/67 G1 (#7940), plus the native gaps the first one
uncovered.

## Native: default arguments (#7985) and the method gaps behind them

A call that leaves out defaulted parameters now compiles on `--target native`,
as on dotnet and the JVM. The default comes from the declaration the call
resolves through, and written arguments are evaluated in source order before
the defaults:

- **Free functions and protected entries.** Each function is registered under
  every shorter arity it accepts, after the exact arities, so an overload
  declared with exactly the written arity still wins. `bindCallArgs` lowers an
  omitted parameter's default in the callee's parameter type.
- **Generic functions.** `lowerGenericFnCall` fills defaults the same way.
- **Interface calls.** `NIfaceInfo` carries each method's parameter names and
  defaults. Dispatch binds named arguments by name (it bound every argument by
  position before) and fills omitted ones from the interface member.

Wiring `method_default_args_self_test.l` into the native lane exposed four
native gaps unrelated to defaults. Each is now fixed:

- **Same-named record methods collided.** A record-body method was registered
  as a bare package function, so two records in one package with a method `m`
  shared one symbol and a call reached the wrong one (`cannot pass a '%P.B'
  where '%P.A' is expected`). Methods are now named `<Record>.<method>`, like
  dot-named functions, and a member call tries the receiver type's methods
  before same-named package functions.
- **Bare sibling calls.** `m(x)` inside a method, meaning `self.m(x)`, did not
  resolve. It now lowers as a member call on `self`, ahead of a same-named
  free function, as on the JVM (#1722).
- **Explicit `self` in interface and impl methods.** `func area(self: in Self,
  ...)` added a second receiver (`An item with the same key has already been
  added. Key: self`). The explicit receiver is dropped where native supplies
  its own.
- **Interface default methods through the vtable.** A default method now
  takes a vtable slot. `Lyric.ImplDefaults` already copies its body into every
  impl that omits it, so each slot points at the impl's own method.
- **Generic record methods.** `record Box[T] { func m(self: in Box[T]) }` had
  no native lowering. Each method is registered as a generic function
  `<Record>.<method>` over the record's type parameters, and a member call on
  an instance reaches it through the instance's generic key.

`method_default_args_self_test.l` (17 cases) and `func_default_args_self_test.l`
(9) now run on all three targets. The `ULong` default-widening case moved to
`method_default_widening_self_test.l`, on dotnet and the JVM, because native
`UInt`/`ULong` is #7891.

## JVM: one-digit subnormals (#7987)

Java's scientific form always prints a digit after the point, so the
smallest subnormals rendered with two significant digits (`4.9E-324`,
`1.4E-45`) where .NET prints one (`5E-324`, `1E-45`). The JVM float-string
normaliser now rounds a two-digit mantissa to one digit and keeps it when
`Double.parseDouble`/`Float.parseFloat` gives back the same value.
`float32_self_test.l` pins six subnormals on all three targets.

## Protected-type invariants are type-checked (#7988)

A protected type's `invariant:` clause was never type-checked, so an
ill-typed clause compiled and an unsuffixed literal compared with a `Float`
field stayed a `Double` (`level <= 0.1` failed for `level = 0.1f32`). The
clause is now checked like a `requires:` clause with the fields in scope by
bare name (T0132 when it is not `Bool`), and `Lyric.Mono` rewrites its
conversion sites before the contract elaborator copies it into the entries.
Tests: `typechecker_self_test.l` (a `String` comparison, a non-`Bool`
clause, a clean clause) and a `Float` invariant in `float32_self_test.l` on
all three targets.

## `lyric bench --target native` settings (#8096)

`lyric bench --target native` now applies the manifest's `[native]` table
(`triple`, `opt_level`, `extra_libs`) and takes `--triple`/`--opt`, which
override it, as `lyric build` does. With no level named a bench builds at
`-O2`. A `wasm32` triple is an error, since the benchmark runs on this
machine, and `--triple`/`--opt` with another target is a usage error.
`cli_build_self_test.l` covers the precedence (`resolveNativeBenchConfig`).
