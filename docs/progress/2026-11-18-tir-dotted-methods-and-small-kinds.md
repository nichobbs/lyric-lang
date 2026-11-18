# docs/70 phase 3a: dot-named generic method calls and four smaller kinds build (D422, D423)

A method of a value-generic record (or any dot-named generic function) called with method syntax builds as a call of the function with the receiver first, an omitted array field builds as its zero value, a sibling call in a generic `impl` builds, a range pattern bounded by a constant builds, a shared enum case read through its package builds, and a derived operator on a record (`a + b`, `r += s`) builds as its fields' operator in a record built from them.
