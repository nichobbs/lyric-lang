# TIR builder: record copies, catch bindings, untyped tails, explicit type arguments (D565, #8613)

Docs/70 phase 3a: `XCopy`, exception-typed catch bindings, `buffer.length` and `exception.message`,
untyped lambda/branch/arm tails, never-completing blocks and the explicit type arguments of a call build.
Stdlib census: 1056 -> 1079 of 1165 bodies, I0003 0 (see D565). Phase 3a is not complete: I0002/I0003 do
not stop the build yet.
