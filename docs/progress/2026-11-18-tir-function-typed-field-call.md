# docs/70 phase 3a: a call through a record's function-typed field builds (D456)

The checker records the type of a function-typed field's member callee, and keeps a generic record's parameters as parameters (instead of erasing them) when it types such a call inside a generic function, so `p.classify(x)` builds in TIR.
