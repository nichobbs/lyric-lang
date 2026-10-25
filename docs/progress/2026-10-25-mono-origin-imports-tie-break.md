# Mono resolves same-named calls in a specialised body by the declaring package's imports

`Lyric.Mono.resolveAmbiguousOverload` broke a tie between two same-named,
same-signature candidates by the root file's imports (`uniqueRootImported`),
but inside a generic body specialised from another package P it gave up
(`None`): the call was never specialised. D230 hit it with `Ui.Forms.formFieldAt`
calling `Ui.Widgets.field` in a bundle that also held `Ui.Plugins.Build.field`
(`NoSuchMethodError: Ui.Widgets.field(String, ArrayList, Object)` on the JVM,
an Object fallback on dotnet), and avoided it by moving `Ui.Plugins.Build`
into a library of its own.

Each generic Mono receives now carries its package's imports, in a reserved
`__lyric_origin_imports` annotation beside `__lyric_origin`
(`Lyric.Parser.originImportsAnnotationName`, `Lyric.Mono.withOriginImportsMono`):
`P` for a whole import, `P::f` for a name imported selectively.
`Lyric.Pipeline.pipeAddGenericFuncs` takes the declaring package's imports and
records them; `pipeOriginImportsOf` builds them from a file's `ImportDecl`s,
`pipeOriginImportsFrom` from recorded whole and selective lists. The callers
pass them: MSIL from `StdlibPkg.wholeImports`/`selectedImports`, the in-bundle
files' imports and the restored artifacts' contracts; the JVM from the stdlib
and source-dependency files and the restored contracts; native from the
stdlib and project files. Mono gathers them into `MonoState.originImports`,
and the tie-break (`uniqueImportedBy`) uses P's imports inside a body
specialised from P, as it uses the root file's at the top level. A tie whose
candidates P does not import is still not guessed.

Verified by three new `mono_self_test.l` cases (a selective import, a whole
import, and neither, each with the root file importing the other candidate).
