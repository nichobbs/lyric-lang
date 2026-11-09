# D-progress-1054 — `List`, `Map` and `Set` have a closed method surface (#7683)

**Status:** shipped

`List[T]`, `Map[K, V]` and `Set[T]` are extern types with no declared method
signatures, and the checker declined to report an unknown member on them
because it cannot enumerate an extern type's members. A call such as
`xs.insert(0, 1)` or `m.get(k)` therefore type-checked, and each backend then
did something different: MSIL lowered it to a stub that throws when reached,
the JVM and native failed in codegen.

**Decision.** The members a collection has are the ones the backends lower by
name, and the checker now knows them: `List` has `add`, `contains`, `indexOf`,
`lastIndexOf`, `remove`, `removeAt`, `clear`, `count`, `set`, `toArray`,
`toList`; `Map` has `add`, `containsKey`, `containsValue`, `remove`, `clear`,
`count`, `set`; `Set` has `add`, `contains`, `remove`, `clear`, `count`. A
method call naming anything else is **T0113**, unless the name is one every
value has (`toString`, `equals`, ...), a plain function the file can call bare
(the function binds by UFCS), or a dot-named function of the type. The
message lists the members. This is the same rule slices follow (#8471).

A package that declares an `extern type` itself (the host kernels, such as
`Std.CollectionsHost` on the JVM, which call the host's own `Map.get`,
`keySet`, ...) is exempt, as it is for T0197.

The argument checks that already existed (T0042 arity, T0043 element, key and
value types, return types for `contains`/`containsKey`/`remove`/`indexOf`)
are unchanged.

**Issue census (re-checked on current main).** #7978 (arity, return types),
#7786 (`Option[Long]`/`Result[Long, _]`/`Box[Long]` construction, `id[Long](5)`),
#8161 (type-qualified calls), #8249 (`?` operand, T0195/T0169), #8289 (writes
through `in`, V0038, D303), #8331 (interface contracts, T0132/T0020) and #8334
(unknown primitive methods, T0113) no longer reproduce. #8104's static-form
argument checking and overloaded protected members (T0209) are fixed; its
third item, native bare sibling calls, is a native lowering gap outside the
checker.

The compiler's own sources, the stdlib bundle and every ecosystem manifest
check clean under the new rule.
