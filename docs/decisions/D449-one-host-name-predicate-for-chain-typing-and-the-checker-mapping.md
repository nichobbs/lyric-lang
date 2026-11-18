# D449 - The builder's host chain typing and the checker's host result mapping read one name predicate (docs/70 phase 3a, #8613)

**Status:** shipped; no behaviour change, no language change.

## Context

`isPlainHostResult` (which host classes the builder may type a chain result as) and `hostResultIsCallType` (which host results the checker types as a Lyric type) each spelled the same host class names by hand: the array marker, the string classes, `Object`, the 32 and 64-bit floating point classes, and the task and future classes. Part 8's review asked for one predicate so a class added to the checker's mapping cannot be missed by the chain typing.

## Decision

`build_host.l` holds the name helpers `isHostStringName`, `isHostSingleName`, `isHostDoubleName`, `isHostTaskName` and `hostNameHasLyricType` (the union of them with the array marker and `Object`). `hostResultIsCallType` reads the per-type helpers; `isPlainHostResult` reads `hostNameHasLyricType`. `hostResultIsCallType` still depends on the declared type (a host enum is an `Int`, an erased `Object` is whatever it was instantiated at), so only the name lists are shared.

`erasedHostKind` is public and has unit tests (the host `Object` as a type parameter, a host array as a slice of one, a host generic class as itself applied, and the cases that must not convert). `tir-builder-shapes-e2e.sh` gains `shared_union_case`: a nullary case name two unions share, built and run.
