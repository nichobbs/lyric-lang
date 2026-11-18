# D457 - A restored package's default argument is its compiled default thunk (docs/70 phase 3a, #8613)

**Status:** shipped; extends D482 (defaults carried by interfaces) and #7827 (default thunks).

## Context

A package restored from its compiled form carries each public callable's parameter defaults as a call to a compiled thunk (`__lyric_default_...`, `Lyric.ContractElaborator.synthesizeDefaultThunks`), because the default expression is written in the declaring package's scope and cannot be carried as source. The builder places a call's omitted arguments from the checker's recorded default; for a default of another package it read the interface's carried default or, failing that, copied a literal, and counted anything else. A restored dependency has no interface in the build, and the default is a call, so every call that left out such a defaulted argument was counted ("a default argument declared in another package"): the restored-defaults, fixed-array and native dependency self-tests and lyric-ui.

## Decision

When the default is a call to a default thunk (`isDefaultThunkCall`), the builder calls the thunk where the argument is left out: the checker exposes the thunk's symbol and signature (`defaultThunkCallee`, read from the declaration the restored contract synthesised into the table), the builder emits a direct call of it with no arguments and converts the result to the parameter's type as any argument is. No default expression crosses the package boundary, as for the backends.

## Results

`restored_default_args_self_test.l` (20 cases) builds every body, including the consumers' calls to restored defaulted functions, methods and interface members, with no I0002 or I0003.
