# D157 — Records without `var` fields are values; records with `var` fields have identity

**Status:** accepted (codifies existing behaviour on every backend)

Supersedes D156 item 4 (Q-GFX-008). Resolves docs/67 Q-GFX-008.

## Context

D156 item 4 stated that every record has value semantics, so that after
`var p = q; p.x = 1` the record `q` is unchanged. The docs/67 G1 audit
(2026-10-01, `main` at b7160d6) then compiled the same program for
`--target dotnet`, `--target jvm` and `--target native` and found the
opposite, consistently on all three:

- a record with a `var` field is shared: assignment, returning it from a
  function, storing it in a `List` or a field, and reading it back out all
  yield the same instance, so a write through one binding is seen through
  every other;
- a callee may assign a `var` field through an `in` parameter (an `in`
  binding cannot be rebound, but the record it refers to is not frozen, as
  §4.4 of the reference already says for objects in general), and the
  caller sees the write;
- `.copy()` makes a new, independent instance.

About 167 records in the repository declare `var` fields (78 in the
compiler, 23 in the stdlib, the rest in ecosystem libraries), and many are
object-like (HTTP/2 connections, JSON-RPC peers, transports, parser state,
`@stubbable` stub counters) and depend on the sharing. Making every record
a value would be a language-wide behaviour change with a large, risky
migration.

## Decision

1. **A record with no `var` field is a value.** It cannot be mutated, so
   whether a backend copies or shares its storage is unobservable; a
   changed value is derived with `.copy(...)`. Backends may lower such
   records by value (docs/67 §4.2 does so on native). This holds even
   when a field refers to a mutable record: the field holds a reference,
   and copying the outer record copies the reference.

2. **A record with a `var` field (a *mutable record*) has identity.**
   Assignment, argument passing (including `in`), returning, and storing
   in a field, collection or closure share one instance. A write to a
   `var` field is seen through every binding that refers to it.
   `.copy()` makes a new instance, with reference-typed fields copied as
   references.

3. **Every backend implements this today.** It is pinned on all three by
   `lyric-compiler/lyric/record_semantics_self_test.l`.

4. **`Plain` excludes mutable records.** D155 item 3 is narrowed: a record
   is `Plain` only if it has no `var` field (as well as all-`Plain` fields
   and no `invariant:`). Buffer elements are therefore values; an element
   is updated by writing a whole new element, typically
   `b[i] = b[i].copy(field = v)`.

5. **Mutable records will be marked explicitly.** Whether a record is a
   value or has identity should be visible at its declaration, not
   inferred from whether some field happens to be `var`. A follow-up
   proposal adds an explicit declaration form for mutable records (for
   example `ref record`) and makes a `var` field in a plain `record` an
   error. Because it changes no behaviour, its migration is mechanical:
   add the marker to each existing mutable record. Tracked in #7955.

## Consequences

- `docs/01` §2.4 states both rules and replaces D156's value-semantics
  paragraph; §2.7's `Plain` definition excludes records with `var` fields.
- docs/67 §4.2 and §4.5 and its Q-GFX-008 row are updated.
- The G1 issue (#7940) drops the "fix divergences" item: none exist.
