# Distinct-type member access, bare-constructor scope and Mono field inference (D140)

Follow-ups to #7443:

- **#7439.** A member read on a distinct type used to type-check unchecked
  and then miscompile (an invalid MSIL program, a JVM J009). Now `x.value`
  has the underlying type, any other member read is T0113 pointing at
  `x.value.<member>`, and an erased distinct value narrows to its wrapper
  class on the JVM before `.value`.
- **Bare constructors on the JVM.** Codegen resolves them in the scope the
  type checker uses: selectively imported names first, then any imported
  package, whatever the import form. It does this both in a file's own code
  and in a specialised copy of another package's generic. The checker's
  scope is itself wider than docs/01 §9.2 describes (#7463).
- **#7441.** Mono infers a generic call's type arguments from a field chain
  on a restored package's records, using the type checker's recorded field
  type (`mapKeys(o.inner.m)` was M0004).
- **#7442.** `union_case_collision_self_test.l` constructs the colliding
  `InvalidDocument` cases by qualified name (the bare form is T0123) and now
  runs in CI.

Tests:
- `typechecker_self_test.l`: the T0113 rule and `.value` typing.
- `erased_receiver_jvm_self_test.l`: distinct `.value` in a generic record, on both targets.
- `emitter_project_self_test.l`: a bare constructor through an aliased import, directly and specialised, on both targets.
- `cross_package_generics_self_test.l`: #7441.
- `jvm_trycatch_bridge_self_test.l`: its J007 repro is now an extern-typed value in a generic record.
