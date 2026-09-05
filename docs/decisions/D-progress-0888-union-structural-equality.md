# D-progress-888 — every union case class gets a real structural `Equals`/`GetHashCode` override, unconditionally — `Option[T]`/`Result[T,E]` `==` is no longer reference/tag identity (#6835, #6120)

**Context.** `None == None` returned `false`; `a != None` returned `true` when
`a` genuinely was `None`; and two independently-constructed `Some(value = 1)`
values compared `false` under `==` on `--target dotnet` (#6120, triaged
2026-07-29 and 2026-08-19; #6835, filed while fixing #6834's parser bug after
its `vis != None` idiom silently computed the wrong boolean and had to be
rewritten as a `match`).

**Root cause.** `Msil.Codegen`'s `BEq`/`BNeq` lowering (`derivedEqualsTokenMsil`,
D-progress-374/375) dispatches to a type's derived `<Type>.equals` free
function when one is registered, else falls back to the static
`Object.Equals(object,object)` helper. Records get real structural equality
via `appendDeriveOverridesMsil`'s `Equals(object)`/`GetHashCode()` **overrides**
on the record TypeDef (delegating to the derived free function) — but that
machinery was never extended to **unions**: no `IUnion` arm ever called it, so
every union case class (`Option_Some`, `Option_None`, and any user union's
cases) inherited `Object`'s identity-based `Equals`, and `BEq`'s fallback path
resolved to bare reference comparison. For a NON-generic union this is
occasionally masked (a non-generic nullary case is a singleton — `lowerMUnion`
line ~3308's `Instance` static field — so two `None`-shaped values of the same
non-generic union happen to be the same reference), but `Option[T]`/`Result[T,E]`
are **generic**: their nullary cases carry no singleton (docs/43 Q-GEN-001 —
constructed via `newobj` every time, since a generic type's static field is
per-instantiation), so `None == None` was false, and `Some(x) == Some(y)` for
two separately-`newobj`'d equal payloads never had anything BUT reference
identity behind it either way.

Delegating to a synthesised free function the way records do (call
`<Union>.equals(self, other)` from the override) is not viable for a generic
union: `Lyric.Derives`'s free-function shape (`makeFuncDecl`'s `generics =
None`, a bare unparameterized `typeRef(typeName)` for the `self`/`other`
params) has never supported a generic type at all, and even if it did, the
self-hosted MSIL backend has no reified GENERIC METHODS — only generic
**types** are reified (docs/43 Q-GEN-002, the exact constraint docs/55's
B-mode aspect work hit too) — so an `equals<T>` free function usable from
every instantiation isn't buildable.

**Fix.** `buildUnionCaseEqualityOverridesMsil` (`lyric-compiler/msil/codegen.l`)
synthesises `Equals(object): Bool` / `GetHashCode(): Int` **inline**, directly
on each case, sidestepping the generic-method blocker entirely: both methods
are ordinary (non-generic-signature) instance methods defined once on the
case's own already-reified `!0..!n` parameters — the same trick the case's
`.ctor` already uses to read/write `T`-typed fields without a generic method.
`Equals` does `isinst` against the SAME case (the open self-instantiation
`Case<!0,…>` for a generic case, `Case` bare for a non-generic one) — one op
that is simultaneously the null check and the same-variant check, which is
exactly what makes `None == None` and `Some(x) == None` correct — then
compares each field via the existing `Object.Equals(object,object)` static
helper (boxing first). `GetHashCode` folds `h = h*31 + fieldHash` seeded with
the case's 0-based index, mirroring `Lyric.Derives.synthesizeHashUnion`'s
shape so a user's `@derive(Hash)` union and this always-on override agree —
needed alongside `Equals` or `Map`/`HashSet` keys violate the hash/equals
contract the moment `Equals` stops being reference identity. Applied
**unconditionally** to every union, stdlib or user-defined, generic or not —
no `@derive(Equals)` gate — matching the language reference's "unions have
structural equality by default" (§2.4, extended in this PR to explicitly
cover unions; see docs/01 §2.5). `addPackageTokens`'s `IUnion` arm reserves
the matching +2 MethodDef rows per case.

Boxing a generic case's own `!0`-typed field needs a TypeSpec encoding the
bare VAR element (`box !0`, valid regardless of whether the actual
instantiation is a value or reference type) — `boxForUnionEqualityMsil`
builds that inline, since the existing `boxIfNeededMsil` never needed to
handle `MTypeVar` before (left untouched to avoid any risk to its ~40 other
call sites).

**Two real emission bugs found and fixed underneath, both exposed only by a
GENERIC case's Equals/GetHashCode (never exercised by any existing feature):**

1. A field read (`ldarg.0`/`ldloc.0` + `ldfld <bare FieldDef token>`) inside a
   method operating on a generic case's own type parameters throws
   `TypeLoadException: Could not load type 'Case`1'` at JIT time — the exact
   same failure class #6233 already documents for `PRecord` match-arm field
   binding. A bare FieldDef token carries no generic-instantiation context, so
   the JIT can't compute the per-instantiation field layout. New deferred-
   resolution instruction `MLdfldSelfOpen(ownerFqn, fieldName, arity,
   fieldType)` (`lowering.l`) routes the read through a Field MemberRef
   parented to the case's own open self-instantiation TypeSpec when `arity >
   0` (verbatim the same construction `lowerMRecord`'s ctor already uses for
   `stfld`, `selfTsRow`), and a bare FieldDef token when `arity == 0` (the
   pre-existing, already-correct non-generic path).
2. Declaring the `isinst`-target local's type as a bare `MClass(caseFqn)`
   for a generic case ALSO throws the identical `TypeLoadException` — its
   LocalVarSig entry (`buildLocalVarSigWithCtx`'s `MClass` arm) emits `CLASS
   <TypeDefOrRef>` with **no type arguments**, an incomplete reference to an
   arity>0 TypeDef the loader can't resolve standalone. Declaring the local
   as `MGenericInstByName(caseFqn, [MTypeVar(0), …])` instead (the closed-
   by-`!0` open self-instantiation) fixes it — `buildLocalVarSigWithCtx`
   already has a correct arm for that shape. Confirmed against a hand-written
   C# equivalent (`obj as Case<T>` inside `Case<T>`'s own `Equals`, real
   `csc`-compiled IL) emitting exactly `GENERICINST` for the local and a
   TypeSpec-parented field MemberRef — this is the standard idiom for a
   generic type's own equality override, not something Lyric-specific.

JVM needs neither fix: generics are already fully erased to `Object`
(docs/44 M-1), so `buildUnionCaseEqualsFunc`/`buildUnionCaseHashCodeFunc`
(`lyric-compiler/jvm/lowering.l`) are ordinary `equals(Object)`/`hashCode()`
overrides on the case class, called from `lowerSealedCase`. They are their
own functions, not reused as-is from records' `buildDeriveEqualsFunc`/
`buildDeriveHashCodeFunc` — those compare a reference-typed field via bare
`if_acmpeq`/`invokevirtual Object.hashCode()` (correct for a value directly
addressed but identity-based for anything else), which is precisely the
#6120 bug shape; the union builders route every non-primitive field through
the null-safe static `java.util.Objects.equals`/`Objects.hashCode` instead.

**Verification.** `map_option_self_test.l` (dual-target-wired in CI — chosen
over adding a new self-test file per the #6781 CI-size-ceiling constraint;
`equality_self_test.l` stays MSIL-only by design, docs/41 epic #1470) gains
five cases: `None == None` (independently-constructed generic nullary
cases), `Some(x) == None` / `None == Some(x)` both `false`, two independently-
constructed `Some(value = 1)` comparing `==` true, an independently-**built**
(via string concatenation, not the same interned literal) `Some("alice")`
payload comparing structurally, and an independently-constructed `@derive(Equals)`
record payload (`EqPair`) comparing structurally through the recursive
`Object.Equals` dispatch. 11/11 on both `--target dotnet` and `--target jvm`
(previously 6/6 with the new 5 unwritten). No regression: `derives_self_test`
49/49, `equality_self_test` 10/10, `inbundle_generics_self_test` 36/36,
`mono_self_test` 82/82, `union_list_match_self_test` 5/5 (all `--target
dotnet`); a minimal generic-union repro (`Box[T] { Full(value: T); Empty }`)
and the exact #6835 repro both now run clean end-to-end.

**Call-site audit (per the issue's own request).** `parser_items.l:194`'s
`if rangeOpt == None` (`rangeOpt: Option[RangeBound]`, a generic union — the
same bug class) was checked for real miscompilation and found **already
safe, for an unrelated reason**: `parser_exprs.l`'s `parseTypeExpr`
(`case _ if identStr(peekToken(st)) == "range"`) already consumes a `range`
clause immediately following ANY type path into `TRefined` directly, so
`rangeOpt` is only ever `None` at line 195 when no `range` token follows —
the fallback check is dead code for every parseable input, confirmed by
building `type Age = Int range 0 ..= 150` through both the unpatched
published `lyric` 0.6.2 tool and this fix (both: clean build, `Age.tryFrom(42)`
→ `Ok`). The `sigOpt == None` mentions in `modechecker_check.l` and
`modechecker_self_test.l` are prose in **comments** describing a `match`
arm in words — the actual code (`modechecker_check.l:3685`/`3697`) already
uses `match sigOpt { case Some(sig) -> …; case None -> true }`, never a raw
`==`/`!=` against `None` — never at risk.

**Related:** D-progress-374/375 (the record precedent this generalises to
unions), #6233 (the identical bare-FieldDef-against-open-generic-TypeDef
failure class, previously only known for `PRecord` match-arm binding),
docs/43 (in-bundle generics — Q-GEN-001/Q-GEN-002), docs/01 §2.5 (language
reference, now documents union equality explicitly).
