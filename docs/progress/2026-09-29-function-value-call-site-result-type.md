# Calls through any function value return the real result on .NET (#7716)

#7711 (PR #7717) fixed calls through a closure bound to an unannotated local
by writing the checked function type onto the binding as its annotation. A
function value bound where no annotation can go still failed on
`--target dotnet`:

```
func forLoop(base: in Int): Int {
  val fs = [{ -> base + 1 }, { -> base + 2 }]
  var acc = 0
  for f in fs { acc = acc + f() }    // -1610495720, not 5
  acc
}
```

The same happened for a `match` pattern binding (`case Some(f) -> f()`), a
destructured tuple element (`val (f, g) = (...)`), a list element
(`fs[0]()`), and a record field read off a receiver codegen sees only as
`object` (`hs[0].get()`, which failed with "unsupported method 'get'"). The
JVM rejected the tuple and list-element forms at compile time (J008, `+` on
two operands erased to `Object`).

The cause is the one #7711 hit, at a different place. MSIL invokes a function
value through the uniform boxed `Func<object, ...>`, and the call site unboxes
the result only when codegen knows the callee's return type. It knows that
only for a binding with an annotation, a parameter, or a record field on a
receiver of known class. A loop variable, pattern binding, tuple element or
list element has no annotation for #7711's desugar to fill in.

The fix carries the checker's type to the call site instead of the binding:

- The type checker records every call through a function value in
  `SymbolTable.funcValueCallSites`, keyed by the call's span. Each record
  (`Lyric.Parser.FuncValueCallSite`) holds the callee's checked function
  type spelled as source. Only callees that are certainly values are
  recorded: a local, parameter or pattern binding, a record field, or any
  other value-producing expression such as a call, an index or a block. A
  function or builtin name is never recorded, because the call reaches it by
  name. Also skipped: async types, types that return `Unit` or `Never`, and
  types with no source spelling, such as a type parameter in a generic body.
  If two checked calls share one source position with different types
  (synthesized code), the site is marked conflicting and left alone.
- `Lyric.Mono.desugarCheckedFile` rewrites each recorded call `callee(args)`
  to `{ val __lyric_fv_<n>: <type> = callee; __lyric_fv_<n>(args) }`. This is
  the same shape as a hand-annotated binding, which both backends already
  lower correctly, and it keeps the evaluation order: callee first, then
  arguments.

#7711's binding annotation stays. It still types a closure that is passed
along rather than called, and the two desugars compose.

Verified by `closure_unannotated_result_self_test.l`, which runs on dotnet
and JVM. It now has 28 cases (19 from #7711 plus 9 new):

- `for` loop variable, with `Int`, `Long`, `Double` and `Option[Int]`
  results and with an argument
- `match` pattern binding, with `Int`, `Long`, `Double` and `Option[Int]`
- tuple destructuring, with `Int`, `Long`, `Double` and `Option[Int]`
- record field holding a closure, with `Int`, `Long`, `Double` and
  `Option[Int]`, plus a record read out of a list
- list element call, with `Int`, `Long`, `Double` and `Option[Int]`
- a `for` loop variable called inside another closure
- `?` on a loop-bound closure's result and inside its argument
- an `await` inside a loop-bound closure's argument
- nested loop-bound closure calls

Before the fix, the for-loop, match, tuple, record-field, list-element and
closure-loop cases failed on dotnet, and the tuple and list-element cases
failed to compile on the JVM.

Not covered, a separate bug: a lambda literal that returns a bare `None`
inside a list literal, such as `[{ -> Some(1) }, { -> None }]`, builds
`Option_None<object>` on dotnet even when the list is annotated
`List[() -> Option[Int]]`. Reading its result as `Option[Int]` then throws
`InvalidCastException`. The value is built wrong when the lambda is
constructed, not at the call. A local annotated `() -> Option[Int]` holding
`{ -> None }` works.
