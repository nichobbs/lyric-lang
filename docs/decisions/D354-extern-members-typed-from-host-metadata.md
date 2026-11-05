# D354 - Extern members typed from host metadata, and unchecked values named (docs/70 phase 3a, D352, #8613)

**Status:** accepted; fourth slice of the non-callee silent `TyError` sites.

## Context

D338 counted the silent `TyError`s the I0001 gate would reject. After D352 the
largest remaining classes were calls of host methods (`.Dispose()`, `.Add(...)`,
`NetMath.Min(a, b)`), reads of host properties and fields, and the members of a
value that was itself untyped. None has a signature in Lyric source: the host
metadata is the signature, and only a backend bridge can read it.

## Decision

1. **The bridge answers member questions.** `ExternIterResolver` gains
   `resolveMember(clrName, member, argc, isProperty): Option[ExternMemberType]`
   (`EMTVoid` or `EMTType(elem)`, the element spelled as an iteration element is).
   `Msil.MetadataReader.hostMemberReturnsOfExtern` looks the member up on the
   type and every supertype (methods of that arity, the `get_X` accessor and
   fields); `Jvm.AutoFfi.hostMemberDescsOfExternJvm` does the same over
   `ClassInfo`. Every candidate overload of that arity must agree
   (`externMemberAgreed`); a generic method whose result mentions its own type
   parameters, a type the bridge cannot locate, or no candidate is "cannot say".
2. **What a host result is.** `void` is `Unit`. `Int`, `Long`, `Bool`, `Byte`,
   `Double` and `Char` are those Lyric primitives, and a result that is the
   receiver's own type argument (`List<T>.Dequeue(): T`) is that argument. Not
   typed, by design: a host class (a reference the language cannot say is
   non-null, and one a kernel may bind at a subtype, `generateCertificate`'s
   `Certificate` as an `X509Certificate`, which both backends check where the
   value is bound), the host `String`, the root `Object` (the boundary's dynamic
   type), arrays, and `Single`, `Int16` and the other primitives Lyric has no
   type for. Typing a class result as the `extern type` nearest its name was
   tried and rejected: it broke host downcasts the backends accept, and
   accepting downcasts would contradict D352.
3. **Unchecked is named, not silent.** Three named markers stand for what the
   checker leaves untyped on purpose, each a `TyError` whose `DiagId` index is
   negative: `tyErrorHost()` (-1, the host boundary), `tyErrorGeneric()` (-2, a
   pattern binding, loop variable or lambda parameter of generic type, which
   `eraseTyParams` erases until generic bodies are typed with rigid `TyParam`s)
   and `tyErrorUnresolved()` (-3, a member call no checker rule resolves, such as
   a package-private dot-named function of another package). `rg tyErrorHost`,
   `rg tyErrorGeneric` and `rg tyErrorUnresolved` are the remaining inventory.
   The first of them is `tyErrorHost()`, a
   `TyError` whose `DiagId` index is -1. It is still the cascade-suppressing
   wildcard (`typeEquiv`), but `isSilentTyError` is false, so the I0001 gate
   does not count it: the checker knows it is leaving the host boundary
   unchecked and says so. With no resolver at all (hostless tests) the same
   marker is used.
4. **A cascade keeps its cause.** A member read, a method call, an index or `??`
   whose operand is a `TyError` is that same `TyError` (it was silent and
   stays silent only if the operand was).
5. **Collections.** `clear()` on `List`, `Map` and `Set`, and `Set.add`, are
   `Unit` (the backends already discard `HashSet.Add`'s flag).
6. **Qualifier positions are exempt** like callee positions: `IOError.message(e)`,
   `NetMath.Min(a, b)` name a type or package, not a value.
7. **Found while typing.** `.count` on a `slice[T]` (only `List`, `Map` and
   `Set` have it; `.length` is the slice's) reads as `Int` and reports the warning
   **W0042**, the first step of docs/70 12.2 (it becomes the error T0207 once the
   CI census of the ecosystem is clean; the JVM already rejects it). Tests and
   compiler sources used it and were migrated (`manifest.l`, `llvm_bridge.l`, 20
   self-tests and stdlib tests). A union
   case named through its package (`Emitter.Jvm`) and the no-argument
   `isSome`/`isNone`/`isOk`/`isErr` call form are typed. Two spellings of one
   host class (`extern type JSet = "java.util.Set"` and a generic alias of it)
   are assignable to each other (`externAssignable` compares host names). Kernel sources that
   relied on the silence were migrated (`string_host.l`: the fluent
   `StringBuilder.Append` result is bound to `_`; `environment_host.l`:
   `Environment.Exit` is followed by a `panic`).

## Census delta (`LYRIC_TYERR_GATE=1`, compiler and stdlib closure)

| | D352 | now |
|---|---|---|
| non-callee root sites (silent) | 327 | 0 |

The census is the stage 2 closure emit (`LYRIC_TYERR_GATE=1`): 0 silent sites
remain in the compiler and stdlib, so the W0036 to I0001 switch is next (the CI
logs of this change are the census of the ecosystem libraries, tests and
programs). The three named classes above are what typing leaves.

The native bridge still has no resolver, so a native build keeps the unchecked
marker for every extern member (docs/70 phase 3a item 3, tracked in #8825).
