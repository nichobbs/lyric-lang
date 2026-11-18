# D424 - A function of another package used as a value through its alias or package path records its reference (docs/70 phase 3a, #8613)

**Status:** shipped; extends D368 (references by node) and the cross-package function value desugar (D-progress-963).

## Context

A bare name that resolves to a function used as a value (`Prog(step = update)`) records a reference under the node (`recordFuncRefNode`), which the builder reads as the function's global. The same function named through its package (`Reg.Lib.update`) or the alias of an aliased import (`AL.update`, `import Reg.Lib as AL`) was typed by `resolveQualifiedFuncValue`, which recorded the forwarding-lambda site for the desugar but no reference under the node, so the builder found "a name that is not a local". An alias of two segments was not resolved by the member-expression branch at all, which treated only chains of three or more segments as a package path.

## Decision

`resolveQualifiedFuncValue` takes the node and records the reference when it resolves the function, as the bare-name path does. The member-expression branch resolves a two-segment chain whose first segment is an import alias (not a local) through `symTablePackageOfAlias`, the same function lookup under the alias's package.

## Results

`Reg.App::main` (`llvm_project_self_test.l`), `EPCh.App` and `EPFv.App` (`emitter_project_self_test.l`) build; the new `package_qualified_function_value` shape in `tir-builder-shapes-e2e.sh` builds with no I0003.
