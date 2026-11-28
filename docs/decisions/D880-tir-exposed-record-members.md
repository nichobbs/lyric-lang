# D880 - Methods and field defaults of an exposed record build as TIR members

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §6.3; amends D512 "Not done")

## Decision

1. **`memberSites` visits `exposed record` declarations as it does `record` declarations.** An exposed record is the same `RecordDecl`; its methods with a body are members, built with the record as receiver, so a call `p.twice()` has a callee with a declaration. Before, the method had no TIR body and its callers could not name it, so a function calling one fell back to the AST path on native ("a call with no IR name").
2. **Field defaults** of an exposed record (`noteFieldDefaults`) are collected as a record's are, so a construction that leaves a field out reads the default.
3. A method's visibility follows the declaration's (`isPublic`), so it is a D512 boundary like any member of a `pub` record.

## Effect

A native build of a function that calls a method of an exposed record lowers it from TIR; the self-hosted corpus has no remaining builder-side cause for that fallback.
