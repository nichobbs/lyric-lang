# D871: the native TIR lowering copies an array element passed by reference in and out

Status: accepted (docs/70 phase 4a, part 9; D520 slice 48; closes #9433).

## Decision

An `out` or `inout` argument that is an element of an inline array is passed through a temporary of the element's type: an `inout` argument is copied into it first, the callee writes through it, and after the call it is stored back into the element (D179). D859 kept a call that passed such an element beside another by-reference argument on the AST path; that fallback is gone. The temporary is the rule for every element argument, not only the aliasing case, so the result does not depend on whether the callee also reaches the array. `scripts/ci/native-via-tir/elemcopy.l` pins the call `elemAlias(a[0], a)`, whose callee writes the whole array, and an `out` element, and checks that nothing stays on the AST path.
