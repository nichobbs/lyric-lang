# TIR builder: methods, impl members and protected members as declarations (D573, #8613)

Docs/70 phase 3a: `buildPackage` also builds the methods of a record, the members of an `impl` block and the
`func`s and entries of a protected type as `TFnDecl`s with the receiver `self` first; an entry's `when:` clause
is its `barrier` and its symbol entry is `TSkEntry`. The checker now records the type of the `self` receiver of
a `self.field` read. Generic owners are listed in `PackageBuild.failed`, not built. Census (stdlib tests, bodies
built / total): 1082/1165 -> 1130/1240, I0003 0; compiler 11071/12380 -> 11183/12518, I0003 27 unchanged.
Next: a protected member's bare field names, generic owners. Phase 3a is not complete: I0002/I0003 do not stop
the build yet.
