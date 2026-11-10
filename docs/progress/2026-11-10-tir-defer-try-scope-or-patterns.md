# TIR: defer, try, scope and binding-free or-patterns (D559, #8613)

The builder builds `defer`, `try`/`catch`/`finally` without a catch binding, `scope` without a handle
binding, and or-patterns whose alternatives bind nothing. Bindings in a catch, a scope handle and an
or-pattern stay counted under their own kinds. Census: bodies built 1007 -> 1016 of 1165, I0003 0; `a defer`, `a scope` and `an or-pattern` 0; the 6 `try` statements all bind the exception and stay counted.
