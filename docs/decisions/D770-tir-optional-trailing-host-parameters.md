# A host call may leave out trailing parameters the host defaults (docs/70 phase 3a, #8613)

**Status:** shipped for dotnet; the JVM has no optional parameters.

## Context

`JsonEncodedText.Encode("hi")` (`Encode(String, JavaScriptEncoder = null)`), `JsonDocument.Parse("{}")` (an options struct defaulting to `default`) and `File.OpenHandle(path)` (five defaults, two of them non-zero enum constants and an `I8` constant) are legal dotnet calls the MSIL backend resolves through the reference assemblies (#5605): it picks the overload whose trailing parameters all have a default it can synthesize and passes the declared default for each. The TIR builder asked the metadata for overloads of exactly the call's argument count, found none, and the gate (D347) stopped the body as "an extern call the host metadata cannot resolve".

## Decision

- `ExternMemberSig.optionalTrailing: Int` (default 0) is how many trailing parameters of an overload have a default the call can leave out. `Mdr.methodSigsWithTrailingDefaults` returns, for `argc` arguments, the overloads of exactly `argc` parameters and those of more whose remaining parameters `trailingParamDefaults` can all synthesize; `hostMemberSigsOfExtern` reports `optionalTrailing` for each and the MSIL bridge passes it on.
- `HostMemberRef.omitted: Int` (default 0) is how many trailing `params` a call leaves out; `params` stays the member's whole signature. The host fills each omitted parameter with the default its metadata declares (a null reference, a zeroed struct, an enum or integer constant), which is what the MSIL backend passes today: the value is the metadata's, not a TIR expression, so no new node is needed. The verifier checks `0 <= omitted <= params.count` and that the arguments are the first `params.count - omitted` parameters (`call-arity`).
- `scoreOverload` scores the supplied arguments only, types the omitted parameters from the host signature, and adds 1000 to an overload that takes exactly the arguments given, so an exact-arity overload always outranks one that leaves any out (the MSIL resolver's exact-arity bonus); equal scores prefer the overload that leaves fewer out.
- The interface format is version 6 (the codec records `omitted`).

## Consequences

`auto_ffi_self_test` 304, 311 and 324 build. A resolved MSIL overload set now includes the overloads with defaults, so a call that no exact-arity overload fits can resolve where it was counted before. Tests: `tir_build_self_test.l`, `tir_verify_self_test.l`.
