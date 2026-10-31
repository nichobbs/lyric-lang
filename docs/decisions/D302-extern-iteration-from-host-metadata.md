# D302 - A `for` over an extern type is typed from the host's iteration protocol (#7809)

**Status:** shipped

## Context

`forIterElemType` accepted any `extern type` as iterable and typed the loop
variable only for the one-type-parameter phantom idiom
(`extern type C[T] = "java.util.Collection"`). For an extern type of no type
parameters or of two or more the variable was `TyError`, which silenced every
diagnostic involving it in the body, and a non-iterable type such as
`System.Text.StringBuilder` was accepted and failed at codegen or run time. The
loop also lowered through a guess: MSIL cast any extern iterable to `IList`
(`InvalidCastException` for `ArrayList`'s sibling `Queue`, or a dictionary key
view). `Lyric.TypeChecker` is target-agnostic and cannot read host metadata.

## Decision

1. **The checker is told, not taught.** `SymbolTable.externIterElems` maps an
   `extern type`'s `clrName` to an `ExternIterInfo`: `EIINone` (neither
   protocol), `EIIObject` (only the untyped protocol) or `EIIElem(e)`, where `e`
   is an `ExternIterElem` over the extern type's own parameters (`EIEArg(i)`), a
   Lyric primitive (`EIEPrim`) or a host type applied to elements (`EIEHost`).
   Each bridge passes an `ExternIterResolver` (`MiddleEndOptions.externIterResolver`)
   the checker asks, once per type, only for the extern types a `for` actually
   iterates; the answer is kept in `externIterElems`. Resolving every extern
   type a build imports up front cost the JVM bridge seconds per build (each
   class read opens a JDK module), so the metadata is read on demand.
2. **MSIL** reads the reference pack: `Msil.MetadataReader.iterProtocolOfExtern`
   walks Extends and InterfaceImpl rows with TypeSpec decoding and generic
   substitution (so `ConcurrentDictionary<K, V>` reaches
   `IEnumerable<KeyValuePair<K, V>>` through `IDictionary` and `ICollection`),
   across assemblies. A concrete instantiation spelled in the name
   (`List`1[System.String]`) fixes the arguments.
3. **JVM** reads the class `Signature` attribute (`ClassInfo.signature`,
   `parseClassSignature`) and walks to `java.lang.Iterable`
   (`Jvm.AutoFfi.iterProtocolOfExternJvm`). A raw use (a generic class declared
   with no type parameters on the extern type) yields `Object`.
4. **Types.** A host element type is the `extern type` in scope bound to it (the
   checked package's own declaration first, then an imported package's); the
   host `Object` is the extern type bound to `System.Object` /
   `java.lang.Object`. One with no binding is **T0220**, never `TyError`.
   Neither protocol is **T0126**. A boxed JVM `Integer`/`Long`/`Boolean`/
   `Double`/`String`/`Byte` and the CLR `int`/`long`/`bool`/`double`/`string`/
   `byte` map to the Lyric primitives; other primitives stay host types
   (`System.Single`, `System.Char`, ...).
5. **Lowering.** `Lyric.Mono` rewrites the iterable of a checker-typed host loop
   to `__lyric_host_iter(xs)` (`hostIterCallName`, `hostIterInner`), and binds
   the loop variable through a local annotated with the element type, as it does
   a generator's (#7750). MSIL lowers the marked loop through the non-generic
   `IEnumerable` enumerator (the erased runtime type of most generic externs is
   `object`, so the protocol cannot be read off it); the JVM already iterates any
   reference through `Iterable` and only unwraps the marker.
6. **No answer is not a verdict.** A type or a supertype the bridge cannot locate
   (no reference pack, class not on the class path) leaves its entry out, and the
   loop variable stays unchecked, as before.

## Limits

Arity-one extern types keep the phantom-parameter rule and are not validated
against the host. Element types the metadata spells as arrays, pointers or
by-references have no Lyric type and report T0220. `--target native` has no host
metadata and is unchanged.
