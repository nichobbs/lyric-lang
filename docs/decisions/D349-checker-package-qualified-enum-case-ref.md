# D349 - A package-qualified enum case is recorded as the case (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`Std.Http.GET` with `import Std.Http` (the full package path before a case of an enum that package declares) was typed by `packageEnumCaseValueType` but, unlike `Enum.Case` (`qualifiedEnumCaseType`), never recorded as a reference under the member's `NodeId`. The typed IR builder found no type and no case for the node (I0002 "no type recorded for expression node"), leaving the bodies of `Lyric.Docker` (x8) and `Grpc` (x4) unbuilt.

## Decision

The `Pkg.Case` arm of the member checker calls `recordQualifiedEnumCaseRef` with the settled enum type, as the `Enum.Case` arm does. A case name shared by several enums stays an error type and records nothing.

## Results

`package_qualified_enum_case` in `scripts/ci/tir-builder-shapes-e2e.sh` builds with `--verify-ir` (verifier clean) and runs (exit 3).
