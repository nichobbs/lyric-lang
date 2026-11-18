# docs/70 phase 3a: a type-test pattern builds (D459)

`case x is T` builds as `TpTypeTest` at the inner pattern's recorded type, so it and the body reading its binding are no longer counted (I0002).
