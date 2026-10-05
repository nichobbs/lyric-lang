# D179 - An array element passed by reference is copied in and copied out

**Status:** accepted, implemented (#8180)

## Context

docs/01 §2.7 makes an element of an `array[N, T]` a writable place when its array is one: a `var` local, an `out`/`inout` parameter, or a `var` field. Such an element may therefore be passed to an `out`/`inout` parameter (`swap(a[i], a[j])`), or be the receiver of a method whose receiver is `self: inout` (`pts[i].reset()`). The type checker accepted both, but every backend failed in codegen.

A variable place passed by reference aliases the variable: dotnet passes its address, and the JVM passes the shared cell of a captured `var`. An element has no such address on every target:

- D167 represents `array[N, T]` as a `List[T]` on dotnet. `List<T>`'s indexer returns a value, not a reference.
- On the JVM, an array is a typed Java array or an `ArrayList`. The JVM has no interior pointers at all, so its holder protocol already copies every `out`/`inout` place into a one-element array and back.
- Native could take an element's address, but that would make native alone alias, and the three targets would disagree about what a program prints.

## Decision

1. **An element is passed by copy in and copy out, on every target.** At the call, the element's computed indices run once, at the argument's turn in source order (D171). Every other argument then runs, also in source order. The element is then read into a temporary, the callee reads and writes the temporary, and the temporary is stored back into the element when the call returns. The same holds for an element that is an `inout` receiver.

2. **The array itself is never copied.** The element is read from, and stored back into, the place itself, at any depth (`m[i][j]`, `r.a[i]`, an element of an `inout` array parameter, or an element of a captured array).

3. **When nothing is stored back.** A call that panics stores nothing back, and neither does a call that a `?` in an argument skips. A `Never` call stores nothing back. A `Unit` call keeps no value across the store.

4. **Implemented once, in the middle end.** The type checker records the call as an `ArgOrderSite` with `elemCopy`. `Lyric.Mono.argOrderCallMono` then rewrites the call into the copy, the call and the store. No backend lowers an element by-reference argument itself.

5. **Only array elements qualify.** An element of a `List`, `Map`, slice, `String` or extern type is not a place (docs/01 §2.7). Passed to an `out`/`inout` parameter it is T0085, and as an `inout` receiver it is T0166.

## Rationale

Copy in and copy out is the one lowering that every target implements identically, given D167's representation. It is also an established semantics for by-reference parameters. Ada's `in out` parameters of a by-copy type are passed exactly this way (Ada RM 6.2): the actual is copied in, the formal is a separate object during the call, and the formal is copied back on normal return. Making dotnet or native alias an element would give programs a meaning that changes with `--target`.

## Contrast with variable places

| | variable place (`x`, `r.f`) | array element (`a[i]`) |
|---|---|---|
| dotnet | the variable's address (`ldloca`, `ldflda`, `ldelema` on a closure cell) | a temporary, stored back on return |
| JVM | a holder, copied back on return; a captured `var`'s own cell aliased (#8189) | a holder filled from the temporary, stored back on return |
| native | the variable's address | a temporary, stored back on return |
| a callee's write seen through the caller's name during the call | yes on dotnet and native, and for a captured `var` on the JVM | no, on every target |

## Consequences

- **An aliasing argument.** If one element is passed twice (`swap(a[0], a[0])`), each argument has its own temporary, and the temporaries are stored back in argument order. The later argument's store is kept. If an element and the whole array are both passed (`f(a[0], a)`, with the array `in`), the array argument is a copy anyway (D167). With the array `inout`, the element's store lands after the callee's writes through the array parameter, overwriting that one element.

- **A closure that reads the array during the call.** A closure that reads `a[i]` while the callee runs sees the element's value from before the call. A closure that writes `a[i]` during the call has that write overwritten by the store back. A write to any other element is kept. Variable places differ here: a captured `var` passed by reference is aliased on dotnet and the JVM (#8189), so the closure sees the callee's writes as they happen.

- **Async callees.** The store back runs when the call returns its task, not when an `await` of it completes. #8229 tracks `async` functions with `out`/`inout` parameters on dotnet, which today lose the write even for a local; native rejects such functions (N0007).

- **Tests.** `inout_array_element_self_test.l` covers dotnet, the JVM and native. `closure_captured_var_byref_self_test.l` covers the captured-array cases on dotnet and the JVM.
