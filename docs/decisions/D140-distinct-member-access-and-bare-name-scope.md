# D140 — Distinct types expose only `.value`; codegen bare-name scope mirrors the checker; Mono takes checked field types

**Status:** accepted, implemented

Follow-up to D139 (#7443), resolving #7439, #7441 and the review suggestion
on `originScopedExternTypes`.

## 1. Member access on a distinct type (#7439)

docs/01 §2.3 defines a distinct type as nominal: `x.value` reads the
underlying value, derived operators act on it, and nothing else is said
about members. The type checker had no rule at all. Every member read on a
distinct value (`w.n` for `type Wid = Widget`, `e.length` for `type Email =
String`, and `.value` itself) type-checked as an unchecked error type, then
produced an invalid MSIL program or a J009 refusal on the JVM.

**Decision.** A distinct type does not expose its underlying type's members.
`x.value` has the underlying type (resolved in the declaring package's
scope). Any other non-call member read is **T0113**, whose message points at
`x.value.<member>`. Method calls on distinct values (`c.toLong()`) are
unchanged: the backends already lower them. Generic distinct types keep the
previous lenient path, because their underlying type depends on their
arguments.

Distinct types are also recorded receiver classes for the JVM (D139): a
distinct value is a wrapper class on dotnet and the JVM, so an erased one
narrows to it before `.value`. Otherwise `b.item.value` with `b:
Box[Tagged]` resolved `value` against an unrelated opaque type's field by
name.

## 2. Bare constructor scope on the JVM

D139 resolved a bare constructor through the file's selective imports and
then the packages it imports whole and unaliased. Review asked for the same
rule in a specialised copy of another package's generic, whose scope counted
every import of the origin package.

Checking that against the type checker showed the rule was stricter than the
checker. The checker makes every imported package's names visible bare,
whatever the import form: `import P.{f}` and `import P as Q` both make all
of `P`'s names usable unqualified. docs/01 §9.2 says otherwise (#7463). A
bare name the checker accepted from an aliased or selectively imported
package fell through to the bundle-wide first registration, and could bind
to another package's same-named case.

**Decision.** Codegen mirrors the checker. Both the file's own scope and a
specialised copy's origin scope try the selectively imported names first,
then the one imported package, of any import form, that declares the name.
Whether §9.2 is enforced or amended is left to #7463; codegen follows
whichever the checker implements.

## 3. Mono type-argument inference from field reads (#7441)

Mono infers a generic call's type arguments from its arguments' shapes. It
cannot see the fields of a restored package's records, so `mapKeys(o.inner.m)`
failed with M0004 (and, in compilers that predate M0004, instantiated the
call over `Object` and crashed at run time).

**Decision.** The type checker records the type of every field read in the
same span-keyed evidence it already records for qualified and method calls
(`SymbolTable.callResultTypes`, D-progress-969). Mono consults it when its
own member inference fails. The annotated local in `Lyric.Pipeline` stays:
compiler packages are built by the stage-0 seed compiler, which predates
this fix.
