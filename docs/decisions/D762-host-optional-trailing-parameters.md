# A host call may leave out optional trailing parameters (docs/70 phase 3a, #8613)

**Status:** shipped; MSIL host metadata resolver, TIR builder, verifier, package interface format 6.

## Context

`JsonEncodedText.Encode("hi")`, `File.OpenHandle(path)` and `JsonDocument.Parse(text)` call host methods whose last parameters are optional (a default value in the metadata). `hostMemberSigsOfExtern` matched the call's argument count against each overload's parameter count exactly, so the call had no candidate and the builder reported I0002 (`auto_ffi_self_test.l`).

## Decision

- `ExternMemberSig.optionalTrailing` (default 0) is the number of trailing parameters the host declares optional; the MSIL metadata reader fills it from the Param table (`declaredParamDefaults`, the decoding `resolveOverloadIn` already used for emission). `allMethodSigsOn` now fills `ResolvedMethod.paramDefaults` with it for every method; its other callers (interface-impl validation in `msil/codegen.l`) read parameter types only. A host with no optional parameters (the JVM) leaves it 0.
- `resolveMemberSigs(.., argc, ..)` also returns an overload with more than `argc` parameters when every parameter beyond `argc` is optional.
- `scoreOverload` scores only the supplied arguments, types the omitted parameters from the host alone, and ranks an overload that needs no omitted parameter above one that does (`score * 256 - omitted`: a better fit always wins, and fewer omitted parameters break a tie), as the host's overload resolution has it.
- `HostMemberRef.omitted` (default 0) is the number of trailing parameters the call leaves out; `params` is the whole signature. The verifier checks a host call's arguments against `params` less the omitted tail (rule `host-omitted` for a count out of range). The call node carries only the supplied arguments; the host's own default for each omitted parameter is what the call gets, so the typed IR needs no value for it. The backends do not read the typed IR yet (docs/70 phase 3c), so no backend change is part of this decision: the MSIL emitter already synthesises declared defaults for the calls it resolves itself (`trailingParamDefaults`, #5605).
- The package interface format version is 6: a host member now records its omitted count.

## Results

`tir_build_self_test.l` covers an omitted parameter and the exact-arity preference; `auto_ffi_self_test.l` bodies 304, 311 and 324 build.
