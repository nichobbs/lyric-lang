# docs/70 phase 3a: a union case constructed through an alias or a re-export builds (D425)

`L.Circle(r = 3)` through an alias of a package that re-exports the declaring one resolves its case through the resolver, so it records its callee and the body is no longer counted (I0002).
