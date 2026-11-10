# TIR: interface upcasts in argument conversions (D562, #8613)

A declared type passed where an interface is expected builds with an explicit `CvUpcast` node
instead of being counted as `an argument conversion`.
Census: bodies built 1028 -> 1039 of 1165, I0003 0, `an argument conversion` 37 -> 2.
