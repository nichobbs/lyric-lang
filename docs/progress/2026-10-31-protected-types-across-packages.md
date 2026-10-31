# Protected types across packages (#8261, D286)

A `pub protected type` of a library can now be constructed and called from a
package that restores the library (dotnet; the JVM already worked and is pinned
by the same test).

**Root cause.** `Lyric.ContractMeta` exported every protected type as a bare
`opaque type` anchor with no members, so the consumer's checker rejected
construction (`T0100`) and had no entries or funcs to call.

**Fix.**
- Contract export (`contract_meta.l`): a `pub` protected type is a `protected`
  decl carrying its fields (type, initialiser) and bodyless `entry`/`func`
  heads; barriers, the invariant and bodies stay in the library. A private one
  keeps the opaque anchor.
- Parameter defaults: `DTProtectedMember` thunk kind, synthesised by
  `default_thunks.l`.
- Parser/AST: a bodyless `entry` head is accepted in `@contract_source` files;
  `EntryDecl.hasBody` carries that through the passes that rebuild entries, and
  the checker skips such a body.
- MSIL (`registerRestoredMembers`): a restored protected type registers as the
  record-shaped class `lowerProtectedMsil` emits (constructor, field defaults,
  member MemberRefs with by-reference parameters).

**Two existing MSIL bugs found on the way, fixed here** because a library
protected type with a barrier hit them at once:
- an entry or func ending in an explicit `return` in a type with a `when:`
  barrier was an invalid program (the barrier's `defer` exit `leave` landed on
  the first byte of the lock's `finally`); also failed on the seed compiler;
- `Monitor.Wait`/`PulseAll` references are now registered once with the
  protected type instead of while a member body is lowered.
- `Lyric.Pipeline` had two duplicate `files =` arguments from a merge, which
  stopped the compiler building; removed.

**Tests.** `scripts/ci/restored-dependency-codegen-e2e.sh` `protected` case
(restored and sibling, dotnet and JVM; construction, entry, func, `inout`,
default, barrier, generic, private type); `contract_meta_self_test.l`.

**Open.** Reading or writing a protected type's field by name from outside its
members is accepted (in any package) and bypasses the lock, against docs/01
section 7.5; filed as #8672.
