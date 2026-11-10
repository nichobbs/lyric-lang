# TIR: interface upcasts in argument conversions (D561, #8613)

A declared type passed where an interface is expected builds with an explicit `CvUpcast` node
instead of being counted as `an argument conversion`.
