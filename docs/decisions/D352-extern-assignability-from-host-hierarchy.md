# D352 - Extern assignability from the host's hierarchy, and extern `.new` results (docs/70 phase 3a, D351, #8787, #8613)

**Status:** accepted; third slice of the non-callee silent `TyError` sites.

## Context

D351 tried to type `T.new(args)` on an `extern type T` as `T` and reverted: two
JVM sources returned a constructed value where a host base type (or `String`)
is declared, relying on the silent `TyError`. The checker had no extern
subtyping (extern types share one id per host target; the only upcast is
`externAsObject`, to the root).

## Decision

1. **The bridge answers host-hierarchy questions.** `ExternIterResolver` (D302,
   the seam that already answers how a host type iterates) gains
   `resolveBases(clrName): Option[List[String]]`: every host supertype (base
   classes and interfaces, transitively) of the type behind an `extern type`,
   nearest first. `Msil.MetadataReader.hostSupertypesOfExtern` reads the
   TypeDef Extends column and the InterfaceImpl table across the reference
   pack and restored DLLs; `Jvm.AutoFfi.hostSupertypesOfExternJvm` reads
   `ClassInfo.superName` and `interfaces`. `None` means "cannot say" (a type or
   supertype not located), never "no supertypes".
2. **`externAssignable(tbl, expected, actual)`**, applied beside
   `taskHandleAssignable` in argument and return/binding/field checks: one
   extern type of no type arguments is assignable to another when the actual
   type's host supertypes include the expected type's host name. A resolver
   that cannot say leaves the assignment unchecked (as an iteration it cannot
   resolve is); with no resolver at all nothing is assignable by this rule.
   Generic extern types are not covered (docs/48 Q48-001).
3. **`T.new(args)` is a `T`** when a host resolver is present (so assignability
   can be decided from metadata); the host's own string type
   (`java.lang.String`, `System.String`) constructs Lyric's `String`. With no
   resolver (hostless tests, the native bridge today) it stays untyped.

## Census delta (`LYRIC_TYERR_CENSUS=1 ./scripts/bootstrap.sh --stage 2`)

| | D351 | now |
|---|---|---|
| non-callee | 355 | 327 |

Remaining non-callee: 213 call results (host methods `.clear` 22, `.Dispose` 8,
`.add` 6, `IsWindows` 5 and other extern calls), 102 member reads (extern
properties) and 12 others (5 operators, 3 `if`, 3 `index`, 1 `match`). The
native bridge has no resolver yet, so extern constructors there stay in the
count until it gains one. Next: extern members through host metadata.
