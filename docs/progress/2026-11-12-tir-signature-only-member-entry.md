# 2026-11-12 - TIR: a member whose body does not build keeps a signature-only entry (D595)

A member of a generic type whose body fails to build is now described by its declaration (a body-less signature built by
`buildFnCore` with `sigOnly`) instead of the first call site's instantiated signature, which removes the
`call-arg-type` I0003 in `protected_exclusion_dotnet_self_test.l`. One test added to `tir_build_self_test.l`
(`tir_build` 168/168).
