# Tuple `Map`/`Set` keys compare by structure (#8170, D289)

A tuple used directly as a `Map` key or `Set` member is now found by structure
on dotnet and the JVM. Before, dotnet compared it by identity
(`m.containsKey((1, 2))` was false after `m.add((1, 2), ...)`) and the JVM held
`(1, 0.0)` and `(1, -0.0)` apart through `Double.equals`, against D172.

Root cause: a tuple was a bare host list (`List<object>`, `ArrayList`) with no
equality override. Three earlier attempts (#8599, #8636, #8651) stopped at the
design: a comparer passed to `newMap` cannot work, since generic stdlib code
builds maps without the key type, so the equality has to be on the tuple
object (D289).

Fix:
- dotnet: a synthesised `Lyric.Internal.LyricTuple : List<object>` is the first
  TypeDef of each assembly (MethodDef rows 1 to 7, so predicted rows start
  after them), with `Equals`/`GetHashCode` that walk the elements: a nested
  `IList` element by element, anything else through
  `StructuralEqualityComparer` (boxed doubles equal `0.0`/`-0.0` and
  `NaN`/`NaN`). `ETuple` lowering builds it (`MNewobjByName`).
  `MRecord` gained `extendsToken`/`baseCtorToken` for a TypeSpec base.
- JVM: `<package>/__LyricTuple extends ArrayList` per package that builds a
  tuple; `equals`/`hashCode` call the package's `__lyricKeyEq`/`__lyricKeyHash`.
  `LRecord` gained `superClass`.
- native keeps N0007 for a tuple key.

Tests: five new cases in `structural_equality_collections_self_test.l`
(separately built key, `Set` membership, `Double` zeros and `NaN`, nested
tuple with a record and a list, a key built in a generic function plus
`List.contains`), 12/12 on dotnet and the JVM.

Also: `Lyric.Pipeline` did not build on main (two `SourceFile` constructions
gave `files` twice, T0104); the duplicate fields are removed.

Open, separate: `List.indexOf`/`remove` on a `List` of tuples return -1/false on
dotnet even for the identical reference (reproduces on the previous compiler).
