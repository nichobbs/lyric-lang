# D303 - `in` is read-only for value records (V0038, #8289)

**Status:** shipped (mode checker; dotnet, JVM and native share it)

Narrows the `in` bullet of docs/01 section 5.2 and the "mutable container"
reading it gave D183's `bump(x: inout Int, r: in R)` example. A `ref record`
`R` keeps that example's behaviour.

## Context

A `var` field of a record reached through an `in` parameter could be written,
directly or by passing it to an `out`/`inout` parameter, and the caller saw the
write even through a `val`. #8289 asked for it to be rejected. The earlier
attempt (#8688) measured about 290 such sites and stopped for a language
decision, because "`in` is deeply read-only for every record" would turn each
of them into an `inout` parameter, and the change would run up every call
chain (the compiler's `FuncCtx` alone is threaded through about 460
signatures).

## Decision

1. A record that is not declared `ref` is a value (D157, D222). `in` makes a
   value read-only: it cannot be rebound (T0087) and none of its `var` fields
   can be written through it.
2. A `ref record` is a handle to a mutable object. `in` hands over the handle
   and forbids rebinding it; the object stays writable. This is the idiom for
   context, cursor and state objects, and it needs no `inout`.
3. **V0038** rejects, in a function whose parameter (or `self`) is `in`, a
   write to a `var` field of a not-`ref` record of the same file, reached from
   that parameter through such records only:
   - assignment, plain or compound (`a.n = 7`, `a.inner.n += 1`, `self.n = 7`,
     and the bare `n = 7` for a field of `self: in T`);
   - passing the field to an `out`/`inout` parameter of a callee the file
     resolves (by position or by name);
   - calling a `self: inout` method on such a field.
   A path that goes through a `ref record` binding or field is not checked.
4. Not tracked, as before: writes through `val`/`let` bindings, collection
   element writes, records and callees of other files (the typed IR of
   docs/70 is where V0038 over imported types belongs).
5. The fix for a diagnosed record is `ref record` (the same change W0031
   already asks for) when the type is a mutable object, or `inout` when the
   function is meant to change the caller's value.

## Consequences

The repository's own records that were written through `in` parameters are
now `ref record`, with no behaviour change: a record with a `var` field
already had identity on every backend. docs/01 sections 2 and 5.2, the book
appendix B and `modechecker_self_test.l` carry the rule.
