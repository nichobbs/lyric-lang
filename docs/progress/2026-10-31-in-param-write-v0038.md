# V0038: write through an `in` parameter to a value record (#8289, D303)

The mode checker rejects a write to a `var` field of a not-`ref` record
reached through an `in` parameter (including `self: in T`, and the bare field
name inside such a method): assignment, compound assignment, passing the field
to an `out`/`inout` parameter, and calling a `self: inout` method on it. A
`ref record` stays a handle: `in` forbids rebinding and the object remains
writable. The rule and its limits are in D303 and docs/01 sections 2 and 5.2.

Every record in the stdlib, the compiler and the ecosystem libraries that was
written through an `in` parameter is now declared `ref record` (no behaviour
change). Twelve mode-checker cases cover each spelling and the allowed forms.
