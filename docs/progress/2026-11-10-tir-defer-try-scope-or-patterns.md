# TIR: defer, try, scope and binding-free or-patterns (D559, #8613)

The builder builds `defer`, `try`/`catch`/`finally` without a catch binding, `scope` without a handle
binding, and or-patterns whose alternatives bind nothing. Bindings in a catch, a scope handle and an
or-pattern stay counted under their own kinds. Census numbers are in D559's section below.
