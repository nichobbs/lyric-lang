# docs/70 phase 3a: a qualified construction through an alias or a re-export builds (D420)

`L.Leaf(v = n)` where `L` aliases a package that re-exports `Leaf` resolves its constructor through the resolver, so the checker records its callee and signature and the builder no longer counts it as an unresolved call (I0002).
