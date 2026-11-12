# TIR builder: a failed binding's names are poisoned (D571, #8613)

Docs/70 phase 3a: the uses of a name whose binding could not be built are no longer counted as unbuildable
names of their own. Compiler-area `a name that is not a local` 2136 -> 2; the census now shows the real roots
(operators on declared types, non-literal defaults, named-argument reorder, member access). Bodies built are
unchanged. Phase 3a is not complete: I0002/I0003 do not stop the build yet.
