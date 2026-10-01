# D147 — Generic protected types

**Status:** accepted, implemented (`--target dotnet`, `--target jvm`)

Resolves #7830; docs/65 §15 finding F-10.

## Context

docs/01 §7.5 has always shown a generic protected type
(`protected type BoundedQueue[T]`), and the parser, the type checker's
member checks and the contract elaborator already carried the type
parameters. The backends did not:
- MSIL emitted a non-generic class whose `T` fields named a nonexistent
  `Pkg.T` class (`InvalidProgramException`).
- JVM left `T` un-erased (`NoClassDefFoundError: Pkg/T`).
- Native skipped the type and failed on first use.

Separately, construction of any protected type, generic or not, was not
type-checked. The constructor resolved to no symbol, so a wrong field name
or type was accepted, and the `TyError` result disabled checking of every
later use of the value (`val s: String = counter.bump()` compiled).

## Decision

1. **Construction is checked like a record's.** The constructor helpers
   (`ctorAllFields`, `collectCtorFields`, `ctorIsGeneric`,
   `ctorGenericNames`, `constructorSymbolOf`) accept `DKProtected`. A
   protected field becomes a `FieldDecl`: `var` is mutable, `let` and
   immutable fields are not. Field names and types are verified (T0101,
   T0104). Type arguments are inferred from the field arguments or taken
   from the expected type, exactly as for a generic record.
2. **MSIL: a reified generic class**, following generic records (docs/43):
   - GenericParam rows, with `!n` for fields and member signatures
     (`typeExprToMsilG`);
   - the open self-instantiation for `self`;
   - TypeSpec-parented field and method references at call sites.

   The Monitor lock and barrier wrappers are unchanged.
3. **JVM: erased like a generic record.** Type parameters become `Object`
   in field and member descriptors. A read through an instantiation is cast
   back to the instantiated type. `synchronized` members are unchanged.
4. **Native: a build-time N0008** at the declaration, naming #7864, which
   tracks per-instantiation layouts (the D-N-017 deferral). A pre-pass in
   `Lyric.LlvmBridge` reports it before codegen, as N0006 is (#7886). This
   replaces the type-resolution panic at the first use.
5. **Unchanged:** an `impl` for a generic protected type stays T0136, and a
   method-generic member stays T0135.

## Found while testing

On MSIL, assigning `None` (or `Some(v)`) to an `Option` **field** built
`Option_None<object>` rather than the field's closed case class, so
`.isNone` then read `false`. A `when: item.isNone` barrier therefore never
reopened, on records and protected types alike. Field assignment has to
pass the field's type arguments as the construction hint, as local
assignment already did (#3943); the same fix landed independently on `main`
(`lowerAssignValueAtMsil`, #7867) while this change was in review, so this
change keeps only its regression tests.

## Consequences

`Ui.Host` can hold per-session state in a protected cell (F-10), and
concurrent effects (#7835) can use a generic protected queue.
