# Renamed selective imports (#7564, D156)

`import P.{f as g}` now works. It was T0138 ("not supported") since
D141.

- **Meaning.** `g` is the bare name for `P.f` in values, calls,
  constructors, type references and pattern heads, and `f` is not visible
  bare. A renamed union's cases are reached through the new name
  (`Shp.Circle(...)`, `case Shp.Circle(r) ->`).
- **Lowering.** `Lyric.AliasRewriter` rewrites each use of `g` to the
  qualified `P.f`, which every backend already resolves; qualified
  constructors are D155. The rewriter runs in `pipePrepareForCheck`, so
  MSIL, JVM, native and the LSP all see it.
- **Scoping.** Shadowing is lexical. A parameter, local, lambda
  parameter, pattern binding, `for`, `catch` or `scope` binding, or
  quantifier binder named `g` hides the rename only within its own scope.
  A local hides it from its declaration to the end of its block. Package
  aliases keep their function-wide approximation (#6311).
- **T0148.** The new name must not be a declaration or case of the
  current package, another import's bare name, a public name or case of a package
  imported whole, a package alias, or the head of an imported package's
  path (#7928). Every rename in a clash is reported. T0138 is retired.
- **Contract metadata.** A renamed item is left out of the contract's
  `selectedImports`, as for an aliased import: the contract's bodies are
  already rewritten.
- **Tests:**
  - `typechecker_self_test.l`: visibility, parameter/later-local/lambda
    shadowing, T0148 collisions;
  - `import_rename_self_test.l`, on dotnet and the JVM: a renamed
    function, record constructor and union, plus shadowing.
- **Filed:** #7926, a selective import of a name its package does not
  declare is not diagnosed at the import.
