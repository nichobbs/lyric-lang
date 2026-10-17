# `out`/`inout` parameters refer to the caller's place on every target (#8263, D183)

An `out`/`inout` parameter now refers to the caller's place itself on the JVM,
as it already did on dotnet and native. The JVM copied the place into a
one-element holder array before the call and back after it, so when the
callee also reached the place another way the last write won: `bump(r.f, r)`
gave 1 instead of 2, a protected `selfAlias()` passing its own field to a
sibling member returned 1 instead of 2, and `c.addOut(c.total, 3)` left 6
instead of 9. The copy back also ran after a protected member had released
its lock, so concurrent callers passing a protected field lost updates. D183
records the decision: every place but an array element is passed by
reference; an array element stays copy in and copy out (D179).

## JVM lowering

An `out`/`inout` parameter is declared as the shared interface
`Lyric/Lyric$Ref$<K>` (`get()`/`set(v)`, `<K>` the descriptor letter of the
place's type, `L` for any reference type), emitted by every package that
uses it and kept once per bundle like `Lyric$Lambda`. `JvmFuncSig.refElems`
carries each parameter's place type, which the erased interface no longer
spells. The callee reads the parameter through `get()` at every use
(`emitLoadLocalReadThrough`), so it sees a write made through another path,
and writes it through `set(v)` (`emitStoreLocalWriteThrough`). The caller
passes (`emitPlaceRef`):

- a field, at any depth, a protected type's field, or the receiver's own
  field: a synthesised `<pkg>$Ref$<shape>` class over the receiver object
  whose `get`/`set` read and write the field (an opaque type's through its
  accessors), converting between the field's type and the parameter's;
- a local: a reference to the local's heap cell. A local passed by reference
  is now hoisted to a cell for its lifetime, as a local a closure captures
  already was (`noteByRefLocals`, run as each block is entered, which finds such locals by the
  callee's name through a `~byref~<name>` index of the registry, before any
  call is resolved);
- the caller's own `out`/`inout` parameter: its reference, or a converting
  reference when the callee sees the place as a differently erased type (a
  generic `T` at a primitive).

Nothing is written back after the call, so a write made before a panic stays
made, and a protected member writes the place while it holds its lock. The
holder-array helpers and the write-back (`writeBackHolderArg`,
`prepareCellHolderArg`) are gone.

Which locals to hoist is decided as each block is entered, over that block's
own statements (`noteByRefLocals`), with a walker that lists every expression
and statement kind. A function-level pass missed a `var` declared in a range
bound, a module `val` initialiser, a record field default or a default
argument (both lowered at the use), and a wire binding, and the call then
failed in codegen; now every context that lowers a block runs it. (A
branching wire-binding initialiser, where such a `var` would live, fails JVM
verification for an unrelated reason — no stackmap frame in the wire's
`bootstrap` — so that context is not exercised by a test yet.)

A local hoisted to a cell is typed as its cell, so a field of it read with an
index (`h.buf[0]`, for a `var h` a closure captures or a call passes by
reference) lost the field's element type and failed to compile
(`staticBaseClass`); it now reads the cell's element type. A `spawn` operand
passes a parameter it names on by reference too: its task captures the
parameter's reference, since the enclosing `scope` joins it before the
function returns.

## Language rules (type checker)

- An argument bound to an `out`/`inout` parameter must be a writable place
  whatever its type (T0085). A `val` record or `String`, or a literal, was
  accepted for a reference-type parameter, and the callee's assignment then
  rebound an immutable binding.
  Compiler sources relied on the exemption in a few places: the lexer's
  `val state` and the contract elaborator's `val replCounter` (now `var`s),
  and `inout List`/`Map` parameters of the parser,
  formatter, contract elaborator, verifier and derives that only add to the
  collection (now `in`, which allows that, docs/01 §5.2).
  The place must also be writable along its last step: a field argument
  must be a `var` field (the class `placeClass` gives assignment and element
  writes, T0157), so `bump(p.x)` with a non-`var` `x` is T0085 instead of
  silently mutating the field (dotnet, JVM) or failing in native codegen.
  Callees that only change the fields of the record they are given take it
  `in`: lyric-otel's `spanSetError`/`spanAddAttribute`/`spanFinish`,
  lyric-jobs' `runNext`/`runAll`, and `Std.HttpEngine.Hpack`'s encoder and
  decoder functions (whose `HpackEncoder`/`HpackDecoder` were held in a
  non-`var` field of the connection state). The T0085 message now says why
  (D183), suggests a `var` or an `in` parameter, and points at the argument.
- A lambda captures an enclosing function's `out`/`inout` parameter's value,
  never the caller's place: inside it the name is immutable, so assigning it
  is T0087 and passing it by reference T0085, each with a message naming the
  rule. A write there was silently lost on dotnet and the JVM and rejected on
  native.

## dotnet and native

Both already passed the places of D183 item 1 by address, with one dotnet
exception: where the place's CLR type and the parameter's pointee are two
different reference types (an `inout Self` parameter's interface-slot
`object&` against the caller's concrete class, a closure cell forced to
`object[]` by #8204), managed-pointer invariance made `emitByrefArgCheckedMsil`
pass a temporary and store it back after the call, so `h.v.stepInto(h.v, h)`
lost the write the callee made through `h`. The place's own address is now
reinterpreted with `System.Runtime.CompilerServices.Unsafe.As<TFrom, TTo>(ref
TFrom)` (`emitByrefReinterpretMsil`, a new `MCallUnsafeAsByref` instruction
whose MethodSpec is built at lowering). A closure-captured `var` typed by a
type parameter (an `object[]` cell, #7695) passed at that type parameter
still copies, since the parameter may be a value type; that needs the cell
typed by the type parameter. Native needed no change; its closures capture
values (#7891).

## Tests

- `inout_aliasing_self_test.l` (dotnet, JVM, native): the three repros (2, 2,
  9), reads and writes through the other path, `out`, one place passed twice,
  a nested field path, a forwarded parameter, String, record, Long, Double,
  Bool and Byte places, a generic parameter, a method's parameter naming its
  receiver's field, an interface method, concurrent callers passing a
  protected field from outside and a member passing its own field on, and an
  array element copied in and out.
- `inout_aliasing_closure_self_test.l` (dotnet, JVM): a closure the callee
  calls writing and reading the caller's local, a generic parameter, a
  forwarded parameter, a call from inside a closure, and a write before a
  panic.
- `typechecker_self_test.l`: the T0085 place rule for reference types and the
  lambda capture rule.

A generic function with an `inout T` parameter passed a field of a generic
record (`f(b.v, b, 9)` with `b: GBox[Int]`) fails on every target before and
after this change (`InvalidProgramException` on dotnet, a phantom
`NoClassDefFoundError` class on the JVM, N0007 on native): the monomorphizer
does not infer `T` from that argument. It is unrelated to D183 and left for a
separate fix.
