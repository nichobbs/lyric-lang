# D308 - A `for` over an untyped host iterable lowers through the enumerator protocol (#8604, #7770)

**Status:** shipped

Extends D302.

## Context

D302 typed a `for` over a value whose checked type is an `extern type`, and
`Lyric.Mono` marks such a loop (`__lyric_host_iter`) so MSIL lowers it through
the non-generic `IEnumerable` enumerator. The checker does not type the result
of an auto-FFI call (`File.ReadLines(path)` with `import extern System.IO.{
File }`), of an instance method or of a property of an `import extern` type:
the loop variable stays unchecked and the loop is never marked. MSIL then
lowered it as a `List<object>`/array index loop and failed at run time with
`InvalidCastException: ReadLinesIterator -> List<object>` (#8604).

## Decision

1. `emitCollectionForMsil` asks the metadata for the lowered type when no
   other lowering applies (`hostIterElemOfMsilType`): a `MGenericInst` or
   `MClassRef` naming a reference-pack (or restored-DLL) class is looked up with
   `Msil.MetadataReader.iterProtocolOfExtern`, the same walk D302 uses for a
   checked `extern type`. A class that implements `IEnumerable<T>` iterates
   through the enumerator with element type `T`, the type's own arguments
   substituted (`substituteTypeVarsMsil`); one that only implements
   `IEnumerable` yields `object`. Lyric's own collections, value types and
   types the pack does not know keep their lowerings.
2. The enumerator takes part in the D143 disposal region, so it is disposed
   exactly once on every exit.
3. `--target jvm` needed no change: it iterates any reference through
   `Iterable` and closes an `AutoCloseable` iterator.
4. The disposal tests #7770 asks for are
   `for_loop_dispose_extern_self_test.l` and
   `for_loop_dispose_extern_jvm_self_test.l`. A Lyric record implements the
   host's own `IEnumerable`/`IEnumerator`/`IDisposable` (docs/51) on dotnet and
   `Iterable`/`Iterator`/`AutoCloseable` on the JVM, and counts disposals on
   `end`, `break`, `return`, `?`, `break outer`, `continue outer`, a caught
   panic, a panicking disposal, and the D143 precedence of the consumer's panic.

## Limits

A value whose lowered type is erased to `object` (an extern generic result the
emitter cannot name) still falls back to the index loop. Value-type
enumerables (`ImmutableArray<T>`) keep their lowering.
