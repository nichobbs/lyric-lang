# Wire fixes, member-name keywords, wildcard module vals, native `@nativeDtor` (#8540, #8539, #7780, #8310, #6234)

- **#8540: aliased `include` renames a dotted collection path.**
  `Lyric.WireExpand`'s `substExpr` renamed only single-segment paths, so
  `Mw.count` (a `contributes` collection read inside a template included `as
  Mw`) kept the template's bare collection name and read the consumer's
  collection instead of the isolated instance. A multi-segment path now renames
  its head segment through the same table when the replacement is a bare name.
  `wire_templates_self_test.l` adds `CountModule`/`CountApp`: the template reads
  `Middleware.count` while the consumer contributes its own entry, so the
  template must see 2 and the consumer 1 (dotnet and JVM).
- **#8539: wire member initialisers are type-checked.** The checker registered
  `IWire` symbols but never looked at a member's initialiser. `checkWireInits`
  (run from `checkItemDeclaredInits`, so after wire expansion) binds every member
  with a written type, infers each unannotated local to a fixpoint, and checks
  every `singleton`, `scoped`, `bind` provider and typed local (which covers
  the expanded `contributes` entries, collection `List[T]` and `<T>ByKey` map)
  against its type with T0060 at the member. `checkDeclaredInit` gained a
  scope-taking variant, `checkDeclaredInitIn`. Tests: four cases in
  `typechecker_self_test.l` (run after `WireExpand`) and the reject cases
  `wire_singleton_type_mismatch` and `wire_contributes_each_not_list`
  (`scripts/ci/reject-corpus.sh`, both targets).
- **#7780: wildcard module `val` keeps annotations; pipeline list renamed.**
  `val _ = <literal>` with docs or annotations is kept as a discarded temporary
  carrying them (`tempValWith`) instead of silently dropping them; a bare
  literal wildcard is still dropped, and a non-literal wildcard now keeps its
  annotations too. The T0080/T0144 list in `pipeline.l` is
  `gatingAdvisoryDiags`.
- **#8310: contextual keywords as member names.** The premise in the issue was
  wrong for current `main`: the parser rejected `c.entry.name` (P0081), not only
  the stage-0 seed. `tryEatMemberName` now accepts the contextual identifier
  keywords (`contextualIdentKeyword`) plus `when`, `invariant` and `result`.
  A named call argument spelled `entry = ...` is still rejected (P0080) and is
  not part of this change. Compiler sources can use `.entry` only once the
  stage-0 seed carries this parser change.
- **#6234 part 2: `@nativeDtor("symbol")` (D283).** An opaque type on native can
  name the C function that releases its raw handle; the destructor calls it with
  field 0 before releasing ref fields. See D283 for the contract, `N0104`
  validation, and the ASan tests in `llvm_opaque_self_test.l`.
