# The builder's errors name a source position, and a type the checker spells by package resolves without the file's imports (docs/70 phase 3a, #8613)

**Status:** shipped; the TIR builder and the checker's symbol table.

## Context

`lyric-ui/native/host/src/run.l` `reportViewports` failed the native build under the gate (D347) with "I0002: the checker gave no usable type for an expression the checker could not type: <error>", and no position: the message came from a `errors.add(msg)` site in `tir/build` that carries none (a type the checker could not record, a missing symbol), so the report could only name the function.

The cause was a type the file does not import. `match nodeAt(tree, path) { case Some(WElement(_, _, props, _, _)) -> props; case _ -> newList() }` joins `List[Prop]` (`Prop` is declared in `Ui.Core`, which `run.l` does not import) with an open `newList()`. The checker records the join's type as an annotation for the binding (`localBindingTypeSites`), spelled by the package because the bare name is not in scope (`Ui.Core.Prop`, `typeExprForUserType`). The builder resolved that annotation through `resolveType` under the file's import rule, which rejects a qualified reference to a package the file does not import (T0020), and the diagnostic was dropped on the assumption that the checker had already reported an annotation that does not resolve. The annotation was the checker's own spelling, not the file's source, so nothing had been reported, and the result was the `<error>` type. Importing `Ui.Core.{Prop}` made the bare spelling resolve, which is why the same code builds in a file that imports it.

## Decision

1. `buildExpr` gives every message that the build of one expression adds to the builder's errors, and that names no position, the position of the innermost expression being built (`stampErrorPositions`): a message that already ends in `line:column` or `line:column)` is left as it is. A failure reported from deep inside a helper now points at code.
2. `annotatedTy` resolves its annotation with the import rule lifted (`symTableLiftImportRule` and `symTableRestoreImportRule`, which hold and restore the package the rule judges). A `TypeExpr` of `localBindingTypeSites` or `hoistOperandTypeSites` is a reference to a known declaration the checker spelled, not source the rule judges; a written annotation was judged by the checker already, so lifting the rule changes nothing for it.

## Consequences

`reportViewports` builds on the native target. The gate's I0002 messages for an expression name a position. Test: `scripts/ci/tir-builder-shapes-e2e.sh` (`unimported_type_in_open_join`: a three-package project whose consumer matches a union of another package into a `List` of a third package's record, joined with `newList()`).
