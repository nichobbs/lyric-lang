# D226 - `buffer[T]` on dotnet and the JVM: a copy-on-write handle

**Status:** accepted, implemented for `--target dotnet` and `--target jvm` (docs/67 §4.4, #8389). Supersedes item 4 of D185.

D185 gave `buffer[T]` value semantics on the managed targets by copying the
list at every logical copy. That is correct and conservative, but a buffer that
is only passed to an `in` parameter or returned cost O(n) at each pass, where
docs/67 §4.4 describes marking the storage shared and copying only when a write
meets it. #8389 asks for that form; this entry records how it is built.

## Decision

1. **Representation.** A managed `buffer[T]` is a *handle*: a `List[List[T]]`
   whose slot 0 is the storage (a `List[T]`) and whose second slot, present
   only while the storage may be shared with another handle, is a copy of the
   first. Marked is `handle.count == 2`. The type spelling comes from
   `Lyric.TypeAliasResolve` (`buffer[T]` becomes `List[List[T]]`), so every
   signature, field, local and generic argument agrees.
2. **A logical copy is O(1).** Every site D167 already records as a copy
   (a store into a writable place, an escaping read of one, a `.copy` field,
   a `spawn` argument) lowers to `shareHandle`: mark the source handle if it
   is not marked, and build a fresh handle over the same storage, marked. The
   invariant D167 states is unchanged, with *handle* in place of *list*: every
   writable place exclusively owns its handle, and a handle reachable from an
   immutable place is never written.
3. **A write makes the storage private first.** `b[i] = v`, `b[i] op= v`, and a
   write to an element array (`b[i][j] = v`) lower to
   `if b.count > 1 { b[0] = <copy of b[0]>; b.removeAt(1) }` followed by the
   write on `b[0]`. Only the handle the write goes through is changed, so a write
   through an `inout` parameter reaches the caller's handle with no assignment to
   the caller's place. The receiver is evaluated more than once, which T0174
   already guarantees is harmless. The copy of the storage is deep for element
   arrays, as the eager copy was.
4. **The value is evaluated before the check.** A stored value that can run code
   (a call, a copy of another place) is bound to a local, with the target's
   indexes ahead of it, before the uniqueness check. Otherwise a copy of `b`
   made while evaluating `b[0] = f(b)` marks the storage shared after a check
   that found it private, and the store lands in storage another handle holds;
   and an `inout` call that writes `b` replaces the storage the target had
   already named. A plain value (a literal, a path, arithmetic on those) needs
   no binding.
5. **The mark is never cleared on the handle a copy was taken from.** This is
   docs/67 §4.4's managed rule: the last holder of shared storage copies once
   more than it needs to. Native, with its reference count, is the performance
   target and is unchanged.
6. **`spawn` snapshots stay what #8391 made them.** The JVM evaluates a copied
   argument when `spawn` runs; that copy is now the O(1) handle share, which
   marks the spawner's handle, so the spawner's next write copies and the task
   keeps the storage it was handed. The copy block keeps the `__lyric_ac_`
   binding the JVM looks for.
7. **W0030 keeps its meaning.** `var b = a` followed by a loop that writes `b`
   still copies the whole buffer, at the first write, on every target, so the
   hint to write through the original binding or construct the buffer directly
   still holds.
8. **A record's `.copy(...)` copies a buffer field it carries over.** The
   eager scheme had the same hole as arrays did before D167 closed it: the new
   record shared the field's list with the old one. `.copy` now stores a copy
   of an array or a buffer field it keeps, which is one more O(1) handle share.

9. **Native evaluates a write's index and value before making the buffer
   unique.** The same hazard as item 4 held on native: `b[0] = f(b)` made `b`
   unique, then evaluated `f(b)`, so a copy `f` kept saw the write.
   `lowerBufferElemAssign` now evaluates both first.

## Why a list of lists, and not a record

A record `Handle[T] { var items: List[T]; var shared: Bool }` would read better.
It was considered and rejected for two reasons that bite in the lowering, not
in taste. The handle type has to be nameable from every package that spells
`buffer[T]`, including one that imports nothing from `Std.Buffer`, and a
generic record's field cannot be written through an `inout` parameter on the
JVM today (a write to `h.shared` fails at run time with `NoSuchFieldError:
Class java.lang.Object does not have member field`).
A list handle uses only operations both backends already lower for `List`
(`count`, indexing, `add`, `removeAt`), needs no import, and has no
generic-record path to get wrong.

## Not in this decision

Native (unchanged: the reference count is the mark). A way for the last holder
to clear its mark (it would need the reference count the managed targets do not
have). Moving a returned local instead of marking it, which would save the one
copy a returned-then-written buffer still costs.
