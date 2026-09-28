# Native: `impl` methods callable directly on a concrete record receiver, scoped erased-`Self` unbox (#7600, #7618)

`--target native` previously only reached an `impl I for R` method through
an interface-typed receiver — `sq.area()` on a concrete `Square` failed to
lower, since `collectImplMethods` registers the method under the
collision-free `<Record>.<Iface>.<method>` symbol and ordinary UFCS
resolution (`lowerUfcsCall`) never looked that name up (#7600). Fixed with
`registerImplDirectMethods`, an index from `<record>.<method>/<arity>` to
the impl method's `ctx.sigs` key, walked in the same units/impls/members
order the type checker's `tbl.impls` builds up so a same-named method on
two interfaces implemented by one record resolves to the first-declared
`impl`, matching the checker's own (undiagnosed, for records) tie-break.
Checked first in `lowerUfcsCall`, before the existing bare
`curPkg + "." + name` lookup — that lookup matches ANY same-arity function
in the package regardless of receiver type, so an unrelated free function
sharing the impl method's name would otherwise shadow it.

Also lands two review follow-ups to #7616/D-progress-1016 (#7618): the
`coerceTo` erased-`Self`-slot unbox is now gated on an explicit
`NIfaceInfo.methodParamIsSelf` fact instead of inferring "this is a `Self`
slot" from the declared type merely being `i8*` (a real `NativePtr[Byte]`
extern parameter erases identically and must not silently accept a
ref-typed argument); and `registerInterfaceNames`'s panic path and
`nativeSelfShapeDiagnostics`'s diagnostic path now share one
`nestedSelfShapesInSig` traversal instead of two copies.

See D-progress-1019 for the full design and `docs/01-language-reference.md`
§ native-backend paragraph and `book/chapters/01-getting-started.md` /
`appendix-b-quick-reference.md` for the updated surface description.

## Tests

New: `lyric-compiler/lyric/llvm_self_test_impl_direct.l` (5 tests: plain
return, `Self` return + chain, two-interfaces-same-name tie-break, a free
function sharing a name with an impl method). Added to
`scripts/ci/native-backend-self-tests.sh`.

Regression, all green:
- `scripts/ci/native-backend-self-tests.sh` — 356 `ok`, 0 `not ok`.
- `scripts/ci/compiler-self-tests-batch.sh` — 0 `not ok`.
- `scripts/ci/jvm-generics-self-tests-batch.sh` — 0 `not ok`.

## Out of scope

- A true pre-codegen diagnostic (new N-code) for a ref-typed value passed
  to a genuinely-declared `NativePtr[Byte]` extern parameter, so even that
  misuse never reaches a panic. The scoped fix above already stops the
  #7616 SILENT bitcast (it now hits `coerceTo`'s existing generic
  type-mismatch panic, the same invariant-violation report every other
  `coerceTo` failure in this backend produces), but a dedicated,
  pre-codegen-gated diagnostic (matching the `N0006`/mode-checker `N0100`
  precedent) needs either type-checker cooperation or a new AST+type
  call-site walker — a larger, separate piece of work not attempted here. Tracked in #7624: the type checker accepts the
  ill-typed argument today, and should reject it.
