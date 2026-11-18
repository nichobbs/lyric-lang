# docs/70 phase 3a: a union case built at a type the context settled builds (D429)

`{ m -> App(msg = m) }` against `(M) -> Wrap[M]` in a generic function builds the case's fields at the type the node settled at, so the body is no longer counted (I0002).
