# TIR builder: a generic call's type arguments from its arguments and result (D567, #8613)

Docs/70 phase 3a: the builder reads a generic call's instantiation from the checker's argument types
and the call's result type together when the checker recorded none. Census 1080 -> 1082 of 1165 bodies,
I0003 0 (see D567). Phase 3a is not complete: I0002/I0003 do not stop the build yet.
