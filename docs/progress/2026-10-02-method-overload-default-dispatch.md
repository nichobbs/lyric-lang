# Method calls with omitted defaults bind the checker's overload; T0161 for differing impl defaults (#7828)

Two gaps left by #7820.

**Overload dispatch.** A method call that left out a defaulted argument was
dispatched by the number of arguments written, not by the overload the type
checker resolved. With

```lyric
record P {
  n: Int
  func m(self: in P, x: in String): Int { 3000 }
  func m(self: in P, x: in Int, y: in Int = 2): Int { 4000 + x * 10 + y }
}
```

`P(n = 0).m(1)` type-checks against `m(Int, y = 2)`, but MSIL looked up the
arity-qualified key `P/m/1` and called `m(String)` with an `Int` (printing
3000), and the JVM, which registered a method under `<class>#<name>` only,
took whichever overload registered first and failed verification. A call
that wrote two arguments to `m(x)` / `m(x, y = 2, z = 3)` found no `/2` key
and fell back to the first-registered overload on MSIL as well. Native
dispatched by the written count too, so a call there could bind an overload
of that count silently.

The type checker now records, for each method call that leaves out a
defaulted argument, the parameter count of the method it resolved to
(`SymbolTable.methodCallArities`, keyed by `Lyric.Parser.methodCallSiteKey`
of the callee). `Lyric.Pipeline` hands the table to each backend through
`MiddleEndOptions.methodCallAritiesOut`, one table per package (spans are
per file):

- MSIL: `CodegenCtx.methodCallArities`, swapped in per package by
  `Msil.Bridge.useMethodCallAritiesMsil`; the instance/interface, generic
  record and bare-sibling dispatch keys are built from
  `methodCallArityMsil`. A body specialised from another package's generic
  (`FuncCtx.originPkg`) does not consult it.
- JVM: `~arity~<site key>` entries in the externs seed
  (`Jvm.Bridge.withRecvClasses`), filtered out of foreign-origin bodies like
  `~recv~`; instance and interface signatures are also registered under
  `<class>#<name>/<parameter count>` (`addMethodSigJvm`), and
  `methodSigJvm` looks the overload up by the resolved count. Defaults are
  refreshed under both keys.
- Native: `Ctx.methodCallArities` (`<pkg>|<site key>`) from each own
  package's `CodegenUnit`; UFCS dispatch looks up `<name>/<count + 1>`. Native
  does not splice defaults yet (#7985), so such a call now stops with that
  message instead of binding another overload.

Method overload selection also now prefers an overload that takes exactly
the written arguments over one that fills the rest from defaults, as free
calls already did, so `o.m(1)` with `m(x)` and `m(x, y = 2)` calls `m(x)`
(it called whichever was declared first).

**T0161.** docs/01 makes a call take the defaults of the declaration it
resolves through, so a call on an interface-typed value and one on the
concrete type can fill an argument differently. The type checker now warns
(T0161) at an `impl` method's parameter whose default differs from the
interface member's (abstract or default method), or where only one of the
two declares one. Defaults count as equal when written alike, ignoring
spans and parentheses.

**Tests.** `method_default_args_self_test.l` (both targets, ilverify phase 4)
gains four cases: exact-arity preference, an omitted default past a
mismatching same-count overload (direct, bare sibling and `self.` calls),
an overload with no method of the written count, and a generic record's
overloads. `typechecker_self_test.l` gains the recorded-arity case and T0161
for differing, impl-only, interface-only, equal and absent defaults, and for
an overridden interface default method.
