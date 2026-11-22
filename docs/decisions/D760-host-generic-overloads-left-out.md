# A generic host overload does not hide the member's other overloads (docs/70 phase 3a, #8613)

**Status:** shipped; MSIL host metadata resolver.

## Context

`String.Join("-", parts)`: `hostMemberSigsOfExtern` returned no answer for the whole member as soon as one overload was a generic method (`Join<T>(string, IEnumerable<T>)`), because its signature mentions its own type parameters, so the non-generic `Join(string, string[])` was lost (`import_extern_self_test.l`).

## Decision

A generic overload is left out of the candidates. A member whose only overloads are generic stays unresolved, as before. The `ExternIterResolver.resolveMemberSigs` doc names the rule. A call the builder would have resolved to the generic overload now either takes the best non-generic one or finds none (I0002); it never picks a wrong generic instantiation.

## Results

`import_extern_self_test.l` 22 of 22.
