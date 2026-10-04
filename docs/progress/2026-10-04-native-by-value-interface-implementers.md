# Native: a by-value record stays a value when it implements an interface (#8010)

On `--target native` a record with no `var` field and only by-value fields
is an LLVM struct value (docs/67 §4.2, G1). An interface value holds its
implementer behind a pointer, so the first slice kept every `impl I for R`
target on the heap, and a `Vec3` that implements `Show` allocated again. It
matched the target by bare name too, so a same-named record in another
package was forced to the heap as well.

Now an implementer is classified like any record:

- **Upcast.** `buildIfaceBox` copies a struct value into a refcounted
  `__box<R>` (the shape `List`/`Map` slots already use) that the interface
  value owns, so the interface value can outlive the record it was made from.
- **Vtable thunks.** A by-value implementer's vtable slot points at a thunk
  that takes the box as its erased `self`, reads the record out, does the
  same for each `Self` parameter, calls the impl method with the values, and
  boxes a `Self` result for the caller to own. A concrete by-value argument
  at an erased `Self` slot is boxed for the call.
- **Target resolution.** The vtable is built for the impl's own package's
  record of that name before one declared elsewhere.

Calls on the concrete record (`v.sum()`) use the by-value method directly
and allocate nothing.

`llvm_self_test_n3.l` adds four ASan cases with a by-value `Vec3` through
`Show`: methods called through the interface and directly, a `Self` result
and a `Self` argument, 200 upcasts in a loop, and interface values that
outlive their records in a record's fields. The existing interface cases,
whose implementers are now by-value too, pass unchanged.

Found along the way: an unannotated binding of a `match` whose arm is
`if c { None } else { Some(v) }` is built as `Option<object>` on dotnet
(#8136); the native backend's own source annotates that binding.
