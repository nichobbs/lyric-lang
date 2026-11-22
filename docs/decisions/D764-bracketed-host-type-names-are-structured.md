# An extern type named with bracketed type arguments is the structured host type (docs/70 phase 3a, #8613)

**Status:** shipped; TIR builder type conversion.

## Context

`extern type ProtoList = "System.Collections.Generic.List`1[System.Net.Security.SslApplicationProtocol]"` writes the host class with its type argument inside the name. The host metadata gives the same class as `List` with the argument `SslApplicationProtocol`. A value of the first spelling and the result of a member of the second (`o.ApplicationProtocols`) are one type, but the builder converted the first to a host type named with the brackets and no arguments, so the verifier reported I0003 `local-type` (`auto_ffi_generic_setter_self_test.l`).

## Decision

`Lyric.Tir.Build.hostRefOfClrName` converts a name that carries its arguments in brackets to the structured host type: the class without arity or brackets (`externHostBase`) and the arguments read from the brackets, split at top-level commas, a CLR primitive (`System.Int32`, `System.String`, ...) as the Lyric scalar the metadata gives it, any other as a host type whose own brackets read the same way. A name without brackets, or one the checker already gave arguments, stands as written.

## Results

`tir_build_self_test.l` pins the conversion (a single argument, two arguments with primitives, a nested argument, an unbracketed name); `auto_ffi_generic_setter_self_test.l` builds.
