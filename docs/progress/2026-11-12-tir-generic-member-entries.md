# 2026-11-12 - TIR: members of generic types are described by their declarations (D593)

Removes the last three I0003 reports of the self-test census (`generic_closure_self_test.l`,
`protected_exclusion_dotnet_self_test.l`): a member the package builds takes its symbol entry from its declaration, and a
call of a member of a generic type passes the receiver's type arguments as the owner's. Two tests added to
`tir_build_self_test.l` (`tir_build` 158/158).
