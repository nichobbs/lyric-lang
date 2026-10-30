# Unknown selective imports, `spawn` as a name, JVM unannotated `pub val`, unknown methods on a type parameter (#7926, #7936, #7777, #8018)

Worked the open front-end issues of `group:compiler-frontend-resolution`, `group:parser-fmt-doc` and
`group:typechecker-diagnostics`.

- **T0210 (#7926).** A selective import of a name the imported package does not declare (`import Geo.{Pointy}`, or
  `import Geo.{nope as n}`) is an error at the import item, with a did-you-mean hint when one declared name is within
  edit distance 2. A name counts as declared when the package declares an item or union/enum case of that name, or
  when a package it imports does (a `pub use` re-export reaches the consumer through it). A package whose source the
  checker was not given, and one with an extern package, a fixture or a destructuring `val`, is not checked, so no
  stdlib or library import is newly rejected. Audit: the stdlib bundle and every ecosystem library and example
  compiled with the new compiler without a T0210.
- **`spawn` as a name (#7936).** Option A of the issue: `spawn` is already a reserved keyword, so no function can be
  declared with that name (P0051). The diagnostic now says why (`spawn(a, b)` is a spawn of the tuple `(a, b)`, never a
  call) and how to bind a host function called `spawn`: declare it under another name with `@externTarget`. docs/01 §1
  states the rule.
- **JVM unannotated `pub val` (#7777).** The checker half was done; the JVM bundle still needed an annotation (J008) on
  another package's `pub val` with a non-literal initialiser. `Jvm.Bridge` now type-checks each bundled package that
  declares such a value (`pipeCheckedDefaults`) and registers its values at the checked, annotated type
  (`registerCheckedModuleVals`), which is the type the declaring package emits the field at. The J008 message no longer
  asks for an annotation unless the checker could not infer a type.
- **Call of an unknown method on a type parameter (#8018).** `x.zork()` and `b.v.zork()` under `where T: Named` are
  T0197 unless the name is a method of a bound's interface, a name every value has (`toString`, `equals`, `hash`,
  `compare`, `show`, `toJson`), or a plain function that binds by UFCS. A record-level or `impl`-level type parameter
  (whose bounds are not in the function's scope) and a bound the checker cannot enumerate are not diagnosed.

Left open:

- **#7809** (`for` over an extern type of arity 0 or 2+). It needs a `SymbolTable.externIterElemTypes` map filled by
  `Msil.Bridge` from `Msil.MetadataReader` and by `Jvm.Bridge` from `Jvm.AutoFfi`, a change across both bridges and the
  checker that was not finished to production quality in this slice. The plan on the issue stands.
- **#7901**: the `Nat` half and `UInt` conversions shipped earlier; the checked `ULong` conversion is #8450.

Coverage: `typechecker_self_test.l` (T0210 declared, undeclared, renamed, near-name hint, re-export, unknown package;
T0197 on calls), `parser_self_test.l` (P0051 for `spawn` with the rename hint),
`jvm_cross_package_collision_self_test.l` (unannotated `pub val` over a private helper on `--target jvm`).
