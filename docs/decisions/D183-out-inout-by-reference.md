# D183 - An `out`/`inout` parameter refers to the caller's place

**Status:** accepted, implemented (#8263)

## Context

When the place passed to an `out`/`inout` parameter is also reachable from
inside the callee, the targets disagreed about what the program means:

- dotnet passes the place's address and native a pointer to it, so a write
  the callee makes to the place through another path (a field of an object it
  was also given, a field of its own protected object, a second argument
  naming the same place) is seen through the parameter, and the reverse.
- The JVM copied the place into a one-element holder array before the call
  and back after it, so the last write won. `bump(r.f, r)`, where `bump`
  writes both `x` and `r.f`, gave 2 on dotnet and native and 1 on the JVM; a
  protected `entry selfAlias() { addOut(total, 1); total }` returned 2 and 1;
  `c.addOut(c.total, 3)` from outside left 9 and 6.
- The JVM's copy back also ran after a protected member had released its
  lock, so concurrent callers passing a protected field lost updates.

D179 had already made an array element copy in and copy out on every target.
The language therefore had two by-reference models, and the reference did not
say which one aliasing code could rely on.

## Decision

1. **By reference.** An `out` or `inout` parameter refers to the caller's
   place itself while the call runs: a local, an `out`/`inout` parameter of
   the caller, a field of an object (a record's `var` field, a protected
   type's field read from outside the type, the receiver's own field named
   bare inside a member), and a field path of any depth (`d.n.c.f`). A write
   through the parameter is a write to the place, seen at once through every
   other path to it, and a write to the place through another path is seen
   through the parameter at its next read. Nothing is copied back when the
   call returns, so a write made before the callee panics stays made, and a
   protected member writes a place while it holds its lock.

2. **Array elements are the exception.** An element of an `array[N, T]` is
   passed by copy in and copy out on every target, exactly as D179 decides:
   the callee reads and writes a temporary that is stored back into the
   element when the call returns. This is the only place that is not passed
   by reference.

3. **An argument is always a place.** An argument bound to an `out`/`inout`
   parameter must be a writable place whatever its type (T0085): a `var`
   local, an `out`/`inout` parameter, a `var` field (of any receiver, the
   field being what is written, as for `p.f = v`; a protected type's `var`
   field named bare inside its member), or an element of an array that is a
   writable place (item 2). These are the place classes an element write
   already requires (T0157, `placeClass`). A `val`, `let` or `in` binding, a
   non-`var` field, a literal, a call result or any other value is not. The
   former exemption for reference types (a `val` record, a `String`
   literal) is withdrawn, and a non-`var` field is no longer accepted: under
   item 1 the callee may assign the parameter, which would reassign an
   immutable binding or field, or a value that is no place at all. A callee
   that only changes the fields of the record it is given, or adds to the
   collection, takes it `in` (docs/01 §5.2); lyric-otel's `spanSetError`/
   `spanAddAttribute`/`spanFinish` and lyric-jobs' `runNext`/`runAll`, and a
   few compiler-internal helpers, changed to `in` for this reason.

4. **A lambda captures a parameter's value.** A lambda that names an
   enclosing function's `out`/`inout` parameter captures its value when the
   lambda is created, like a `val`, never the caller's place, since the
   lambda may be called after the function has returned and the place may
   no longer exist. Inside the lambda the name is immutable: assigning it is
   T0087 and passing it to an `out`/`inout` parameter is T0085. (C# rejects
   the same capture, CS1628.) Every target already captured the value; a
   write inside the lambda was lost on dotnet and the JVM and rejected on
   native. A `spawn` operand is not a lambda: its task is joined by the
   enclosing `scope` before the function returns, so the place outlives it,
   and a parameter it names is the caller's place, as it is in the rest of
   the body.

5. **The JVM passes a place reference.** The JVM has no interior pointers,
   so an `out`/`inout` parameter is declared as the shared interface
   `Lyric/Lyric$Ref$<K>` (`<K>` the descriptor letter of the place's type,
   `L` for every reference type), with `get()` and `set(v)`:

   | place | reference the caller passes |
   |---|---|
   | a local | the local is hoisted to a one-element heap cell for its lifetime, as a local a closure captures already is; the reference reads and writes the cell |
   | a local a closure captures | the cell the closure shares |
   | the caller's own `out`/`inout` parameter | that parameter's reference, or one converting between the two views of the place when the callee's parameter type erases differently (a generic `T` instantiated at a primitive) |
   | a field, at any depth; a protected type's field; the receiver's own field | a reference over the receiver object that reads and writes the field (an opaque type's through its accessors) |
   | an array element | a local holding the element's temporary (item 2), passed as a local |

   The reference classes are synthesised once per package per place shape
   (`<pkg>$Ref$<shape>`); the interfaces are shared by every package, as
   `Lyric$Lambda` is. The callee reads the parameter through `get()` at
   each use and writes it through `set(v)`. The protected member that is
   called runs these reads and writes while it holds its lock.

## Rationale

By reference is what `out`/`inout` say: the reference has always described
them as C#'s `out` and `ref` (§5.2), and two of the three targets already
implemented it. It is also the model in which a protected type's lock covers
the writes a member makes. Copy in and copy out is kept for array elements
only because an element has no stable address on every target (D167
represents an array as a `List` on dotnet, whose indexer returns a value).

Rejecting a lambda's write to a captured parameter is the one rule that is
both implementable on every target and never silently wrong: a lambda cannot
hold a reference to a place that may not outlive the call that passed it.

## Consequences

- dotnet already passed the places of item 1 by address, except where the
  place's CLR type differs from the parameter's pointee as two reference
  types: an `inout Self` parameter keeps the interface slot's `object&`
  while the caller's place is the concrete class (or the reverse when such a
  parameter is passed on), and a closure cell forced to `object[]` (#8204).
  Managed pointers are invariant, so these went through a temporary stored
  back after the call (#7783), and `h.v.stepInto(h.v, h)` lost the write the
  callee made through `h`. They now pass the place's own address
  reinterpreted with `Unsafe.As<TFrom, TTo>(ref TFrom)`. One dotnet shape
  still copies: a closure-captured `var` whose type names a type parameter
  (its cell is `object[]`, #7695) passed at that type parameter, which may be
  instantiated at a value type whose storage an `object` slot is not; it
  needs the cell typed by the type parameter, which a closure class cannot
  name when the parameter is the enclosing method's own (#8263 follow-up).
- native needed no change.
- A closure on native captures a variable's value (#7891), so a closure the
  callee calls cannot see or make a write to the caller's local there; the
  closure cases are pinned on dotnet and the JVM.
- Tests: `inout_aliasing_self_test.l` pins every place kind, the three issue
  repros (2, 2, 9), concurrent protected callers and the D179 exception on
  dotnet, the JVM and native; `inout_aliasing_closure_self_test.l` pins the
  closure and panic cases on dotnet and the JVM; `typechecker_self_test.l`
  pins items 3 and 4.
- **Cost on the JVM.** The callee reads the place through `get()` at every
  use and writes it through `set(v)`, and the reference's class depends on
  the kind of place each caller passes (a field, a local's cell, a converting
  wrapper). A callee called with several kinds of place in a hot loop sees a
  megamorphic call site there, which the JIT cannot inline: a
  read-modify-write loop over an `inout Int` measured about 3-5x slower than
  the old holder array (whose `iaload`/`iastore` were monomorphic, but whose
  copy back was wrong). A callee whose callers all pass one kind of place
  stays monomorphic and is inlined. Caching the place in a local across a
  loop and writing it back afterwards would be faster, but is sound only
  where no call, field write or other argument can reach the place in
  between, which the backend cannot yet prove; until it can, read the
  parameter into a `var` in a hot loop and assign it once at the end, which
  is what the cache would do.
