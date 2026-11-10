# TIR: interface method calls take the value as the receiver (D563, #8613)

A call of a method an interface declares without a receiver builds as a receiver-first `Interface`
call instead of being counted as `a method call with no declared receiver`.
Census: bodies built 1039 -> 1053 of 1165, I0003 0, `a method call with no declared receiver` 30 -> 11.
