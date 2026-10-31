# D298 - The JVM caches an `out`/`inout` place across a loop that cannot reach it

**Status:** accepted, implemented (#8371)

## Context

D183 passes an `out`/`inout` parameter on the JVM as a `Lyric$Ref$<K>` place
reference, and the callee read the place through `get()` at every use and wrote
it through `set(v)`. The reference's class depends on the place each caller
passes (a local's cell, one class per field), so a callee called with several
kinds of place has megamorphic `get`/`set` call sites that HotSpot cannot
inline. A hot loop over an `inout Int` ran 3-5x slower than with the old holder
array.

Alternatives weighed:

- One `Ref` class per element type: the shapes differ in how they reach the
  place (owner object, field, cell), so merging them needs a `MethodHandle` or
  a switch on a kind tag, which costs as much as the megamorphic call.
- Specialising the callee per place kind: multiplies methods and changes the
  descriptors that aspects, interfaces and the weaver depend on (#8368).
- Caching the place in a local across the whole callee: unsound under D183
  without an alias analysis, since a call, closure, field write or second
  argument can reach the place.

## Decision

A `while` or `loop` statement in a function with `out`/`inout` parameters is
lowered into a buffer, and `appendLoopWithRefCache` then decides on the loop's
**bytecode** whether the place can be held in the parameter's value slot for the
whole loop. It can when the loop

- uses exactly one place reference,
- holds only local loads and stores, constants, non-trapping arithmetic,
  comparisons, conversions and branches whose targets are inside the loop (and
  the loop's exit label is a branch target),
- and contains no call, field access, allocation, array access, division,
  cast, `return` or `throw`.

Calls, field access and allocation are how a second path to the place, an
aliasing write or a closure would show up; array access, division and casts can
raise an exception, which would skip the write back and lose a write made before
a panic (D183 item 1). Deciding on bytecode, not source, means an overloaded
operator or an inlined helper is judged for what it compiles to. A place passed
twice, or a second reference used in the loop, falls back (the two could be the
same place).

When it applies, the loop is preceded by the value-slot refresh (`get`), the
`get`/`set` sequences inside become plain slot loads and stores, and a `set`
follows the exit label if the loop wrote. Nested loops are handled innermost
first; an outer loop containing a cached inner loop sees its `get`/`set` calls
and is left alone. A `for` over a range or a collection is not covered.

Loops that do not qualify behave as in D183. This amends the "Cost on the JVM"
note of D183; its semantics are unchanged.

## Consequences

- `benchmarks/bench_inout.l` (`lyric bench --target jvm`, a callee called with a
  local and three record fields, 80M and 1.2G iterations): medians
  `benchInoutMixedPlaces` 490 ms to 86 ms and `benchInoutBreakLoop` 3700 ms to
  231 ms.
- `inout_loop_cache_self_test.l` pins results on dotnet and the JVM, including
  the aliasing shapes that must not be cached.
- Hot loops that call a helper, read a field or index an array are not
  improved; they need either the alias analysis D183 mentions or an escape
  analysis of the callee, and remain read-through.
