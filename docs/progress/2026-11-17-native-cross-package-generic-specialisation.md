# Native specialises the generics of the project's other packages (#9131, D613)

A generic function of one package of a native build, with `x: T` and `T = Char`,
printed the code point for `x.toString()` and `"${x}"` and failed to compile for
`String + x` (N0007): the native bridge gave `Lyric.Mono` only the other
packages' value-generic functions, so the code generator instantiated the rest
itself, keyed by erased types, and `Char` and `Int` (both `i32`) shared one
instance.

`siblingGenericFuncs` (`lyric-compiler/lyric/llvm_bridge.l`, was
`siblingValueGenericFuncs`) now hands `Lyric.Mono` the generics of the
project's other non-`Std` packages that may render a value (`pipeRenderingGenerics`; the rest for inference only, with the union cases), read from their parsed files with the
private helpers they reach carried under `__priv_` names (the JVM bridge's
`pipeAddGenericFuncs(.., carryPlainHelpers)`). A call is specialised at its type
arguments and the specialisation re-checked in its declaring package's scope
with the type argument bound (D606's `charSpecs`), so the operand is marked and
renders as a character. The bundled standard library is unchanged.

Verified by `examples/char-generics` (library `CharGenLib` with generics doing
`String + x`, `.toString()`, interpolation, a private generic helper, a generic
union, an `Option` and two type parameters; application `CharGenApp` calling
them with a `Char` and an `Int`), run on dotnet, the JVM and native by
`scripts/ci/generic-char-e2e.sh` against one expected output:
`native-backend-self-tests.sh`, `native-platform-tests.sh` and
`compiler-self-tests-batch.sh`.

Left open: methods of a generic record still go through the code generator's own
instantiation on native, and fail with a `NullReferenceException` on dotnet
(separate issues). `Std.Xml`'s `xml_tests.l` stays off the native list: its
`textContent(..).length == 5` check counts UTF-8 bytes on native (documented as
the native byte-offset String model, D-N-006), not a generics matter.
