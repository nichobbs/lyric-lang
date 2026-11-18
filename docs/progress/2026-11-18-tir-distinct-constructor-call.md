# docs/70 phase 3a: a distinct type's constructor call builds (D458)

`T(x)` for a non-generic distinct type `T` builds as a wrap of its underlying value, as `T.from(x)` does, so it is no longer counted as "a call the checker did not resolve" (I0002).
