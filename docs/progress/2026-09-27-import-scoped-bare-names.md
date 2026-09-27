# Bare names follow the file's imports (#7463, #6703)

The type checker now enforces docs/01 §9.2 (D141). A bare name from another
package resolves only when the file's imports make it visible:

- `import P` makes every name of `P` visible, and transitively the names of
  the packages `P` imports.
- `import P.{f, T}` makes only `f` and `T` visible (and `T`'s cases, when it
  is a union or enum).
- `import P as Q` makes no name visible bare; write `Q.f`.
- `Option`, `Result` and their cases are the prelude.

Before, any imported package's names were visible whatever the import form,
and a name from a package the file never imported still resolved through a
last-registered-wins fallback. A hidden name is now T0020 (T0010 in type
position) with a hint, for example `unknown name 'trim' (declared in
Std.String, imported as Str; write Str.trim)`.

A bare case pattern resolves through the scrutinee's type whatever the
imports, so `case Dotnet ->` over an aliased package's enum stays a case test
rather than turning into a binding. Both backends follow the same order when
they resolve a bare name: the JVM constructor scope counts whole imports only
(D140 had widened it to every import form), and the MSIL resolvers drop
aliased imports and prefer direct imports over transitive ones. Alongside:
`Lyric.AliasRewriter` rewrites alias-qualified lambda parameter types and
keeps `where T: Log.Logger` package-qualified instead of collapsing it to the
bare name; the checker records `where` constraints by declaring package;
restored dependencies pass their contract's imports to the checker; and an
`impl` of another package's interface checks that interface's signatures in
its own package.

The tree needed few changes: `import Std.Collections` in three stdlib files,
`lyric-forms`, `lyric-ui` and `examples/ui-customers`; alias-qualified names
in `_kernel/http_server.l`, the regex tests, `lyric-i18n`, `lyric-testing`'s
tests, and the compiler's CLI, emitter, pipeline and discovery packages;
`import Std.Iter` in `lyric-web`.

Tests: `typechecker_self_test.l` replaces the #6703 "still resolves" pin
with cases for each import form, the hint text, ambiguity with an aliased
package, selectively imported union cases, and case patterns behind an
aliased import. `emitter_project_self_test.l`'s specialised-constructor test
now uses a whole import, and a new case checks on both targets that a bare
constructor ignores an aliased import's same-named case.
