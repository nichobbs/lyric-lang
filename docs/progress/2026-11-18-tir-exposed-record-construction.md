# docs/70 phase 3a: an exposed record's construction builds (D452)

The checker records a construction signature for an `exposed record` as it does for a record, so the construction (generic or not) builds in TIR instead of being counted as "a method, constructor or member call" (I0002).
