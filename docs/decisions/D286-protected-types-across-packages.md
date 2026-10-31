# D286 - Export `pub` protected types through contract metadata with their constructor and member signatures (#8261)

**Status:** shipped (dotnet and JVM)

## Context

`Lyric.ContractMeta` exported a protected type as a bare `opaque type`, so a
consumer that restored the library read an opaque type with no members. The
consumer could neither construct it (`T0100`, an opaque type cannot be
constructed outside its package) nor call an entry or func. The same type
worked when both packages were compiled in one project, because the consumer
then saw the real declaration. Two earlier triage passes (#8628, #8641) left
the issue open because the fix crosses the contract writer, the parser, the
type checker and the MSIL registration of restored types.

## Decision

1. **Export.** A `pub` protected type is a contract decl of kind `protected`
   whose repr is a `pub protected type` declaration: the fields (`var`, `let`
   or plain) with their types and initialisers in declaration order, one
   bodyless `entry` head per entry, one bodyless `func` head per func. The
   `when:` barriers, the `invariant:`, the bodies and field annotations are
   omitted: they run inside the compiled member. A package-private protected
   type keeps the old `opaque` anchor (kind `opaque`), so a signature can
   still name it but it cannot be constructed.
2. **Parameter defaults.** `DefaultThunkKind` gains `DTProtectedMember` (thunk
   prefix letter `q`). The contract elaborator synthesises a default thunk for
   each defaulted parameter of a `pub` protected type's entries and funcs, and
   the repr carries the call of the thunk, exactly as for a record method
   (D168).
3. **Parser.** In a `@contract_source` file an `entry` may be a head with no
   body (as a `func` already could). Hand-written source still requires a body
   (`P0172`).
4. **Checker.** Skips the body of an entry head (`EntryDecl.hasBody`, false only
   for such a head; the passes that rebuild an entry carry it). Otherwise no
   change: an imported protected type is a `DKProtected`
   symbol, and construction, field checking and member lookup already work on
   it. Reading or writing a field by name outside the type's members is
   accepted today, in the declaring package and now in an importing one; it
   bypasses the lock and contradicts docs/01 section 7.5. Forbidding it is a
   separate change (#8672), since it affects existing code.
5. **MSIL.** Two existing defects had to be fixed for a library protected type
   with a barrier to run: an entry ending in `return` was an invalid program,
   and `Monitor.Wait`/`PulseAll` are now registered with the type. And
   `registerRestoredMembers` registers a restored protected type as
   the record-shaped class `lowerProtectedMsil` emits (one constructor taking
   every field, one instance method per member): the constructor MemberRef,
   the default expressions of the fields, and each member's MemberRef with its
   by-reference parameters.
6. **JVM.** No change: a JVM consumer of a restored `pub` protected type constructs it and calls its members (including an `inout` parameter, a defaulted parameter, a generic type and a barrier) before and after this change; the e2e case pins it.

## Consequences

Contract metadata format version is unchanged; a reader that does not know
kind `protected` treats the declaration as a type, via `isTypeDeclKind`.
docs/70 (D267) replaces the source-synthesising metadata with checked package
interfaces; the protected type's constructor shape and member signatures are
what its `Lyric.Iface` entry must carry, and this decision fixes that contract.
