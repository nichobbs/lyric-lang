# Native backend on TIR: the generic fallback is pinned (docs/70 phase 4a, D520)

`native-via-tir/fallback.l` mixes generic records, unions and functions with a plain function. The
e2e script requires the plain one to lower from TIR, the generic ones to be counted as fallbacks,
and the program to behave identically to the AST build, under AddressSanitizer too (#9023).
