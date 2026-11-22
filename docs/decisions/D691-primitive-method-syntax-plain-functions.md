# A plain function called by method syntax on a primitive receiver is typed and recorded (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

docs/01 section 12.1: a method call on a `String` that names none of the built-in methods but a `Std.String` function or a plain function the file can call bare binds to that function's first parameter (`s.equalsCaseInsensitive(t)`, `s.shout(2)`). The checker accepted the call but left it untyped, and the backends bound it by name, so the TIR gate (D347) stopped the body (the string-probe program of `native-reachability-e2e.sh`).

## Decision

For a primitive receiver, `resolveMethodCallPick` takes, when the receiver's type has no method and no dot-named function of the name, the visible plain functions of that name whose first parameter takes the receiver and whose other parameters take the call's arguments, as dot-named candidates are taken (the call is that function called with the receiver first). The call is typed from its signature, its arguments are checked against it (T0042, T0043), and the callee and call site are recorded (`recordMethodCalleeNode` names a plain function without the receiver's type; `recordMethodCallSite` accepts a primitive receiver).

## Results

`tir-builder-shapes-e2e.sh` (`primitive_method_syntax`, run on dotnet); `native-reachability-e2e.sh`.
