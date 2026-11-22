# A host call may leave out optional trailing parameters (docs/70 phase 3a, #8613)

**Status:** shipped; MSIL host metadata resolver, TIR builder, verifier, package interface format 6.

## Context

`JsonEncodedText.Encode("hi")`, `File.OpenHandle(path)` and `JsonDocument.Parse(text)` call host methods whose last parameters are optional (a default value in the metadata). `hostMemberSigsOfExtern` matched the call's argument count against each overload's parameter count exactly, so the call had no candidate and the builder reported I0002 (`auto_ffi_self_test.l`).

## Decision

- `ExternMemberSig.optionalTrailing` (default 0) is the number of trailing parameters the host declares optional; the MSIL metadata reader fills it from the Param table (`declaredParamDefaults`, the decoding `resolveOverloadIn` already used for emission). A host with no optional parameters (the JVM) leaves it 0.
- `resolveMemberSigs(.., argc, ..)` also returns an overload with more than `argc` parameters when every parameter beyond `argc` is optional.
- `scoreOverload` scores only the supplied arguments, types the omitted parameters from the host alone, and ranks an overload that needs no omitted parameter above one that does (`score * 4 - omitted`), as the host's overload resolution has it.
- `HostMemberRef.omitted` (default 0) is the number of trailing parameters the call leaves out; `params` is the whole signature. The verifier checks a host call's arguments against `params` less the omitted tail (rule `host-omitted` for a count out of range). Backends fill each omitted parameter with the default the host metadata declares.
- The package interface format version is 6: a host member now records its omitted count.

## Results

`tir_build_self_test.l` covers an omitted parameter and the exact-arity preference; `auto_ffi_self_test.l` bodies 304, 311 and 324 build.
