# Structural `toString` for records, unions, tuples and collections (#7892, D282)

`toString(x)`, `x.toString()`, interpolation, `String + x`, `s += x`, `print`,
`println` and `format1`-`format4` of a record, union, enum, tuple, `List`,
`Map`, `Set` or slice now print one documented text on dotnet, the JVM and
native: `P(x = 1, y = 2)`, `Circle(radius = 5)`, `Some(value = 3)`, `(1, a)`,
`[1, 2]`, `{a: 1, b: 2}` (D282). Before, dotnet printed CLR type names, the JVM
`P@<hash>` and `[..]`, and native rejected the argument.

How: the type checker records each stringified operand of such a type
(`SymbolTable.showSites`) and synthesises a rendering function per type
(`typechecker_show.l`, `__lyric_str_<type>`); `Lyric.Pipeline.lowerShowSites`
wraps the operand in a call of it, so no backend has rendering code. The joins
(`showSeq`, `showMap`, `showSet`, with the `Map`/`Set` ordering) are in
`Std.String`. A specialisation of a same-package generic that stringifies a
`T` is re-checked (`specMayRender`) like the unsigned and equality cases. A
bundling backend links `Std.String` for any build with an expression that may
stringify (`pipeUsesFormatBuiltin`), and the JVM bridge registers the
synthesised functions with the other post-check synthesised ones.

Tests: `structural_tostring_self_test.l` (dotnet and JVM, 14 cases),
`structural_tostring_native_self_test.l` (native, 13: native has no `Set` or
`UInt`).

Known gaps, each tracked in an issue: `array[N, T]` keeps the host text; a
generic declared in another package renders a type parameter by the host; a
bare enum case with no expected type (`println(Green)`) has no checked type
and prints its ordinal on dotnet and native; a user union case named `Unit`
stops the JVM bundling `Std.String`.
