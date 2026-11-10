# TIR: generic record construction (D557, #8613)

The checker records the construction signature of a generic record at its closed result type, on
both the plain and the expected-type construction paths, and the builder leaves the record's own
declaration entry in place. Census: bodies built 1006 -> 1007 of 1165, `a method, constructor or member call` 56 -> 54, I0003 0;
`collections_persistent_map_tests.l` builds fully.
