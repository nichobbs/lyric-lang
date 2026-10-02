# D163 — Integer overflow panics in debug builds and wraps in release builds

**Status:** accepted, implemented

Resolves the language-semantics half of #6263 (docs/63 band B0's
optimization/overflow follow-up). Part of docs/67 phase G1.

## Context

`docs/01` §2.1 has said since v0.1 that integer arithmetic panics on overflow
in checked builds (the `--debug` default) and wraps on unconstrained integer
types in `--release` builds. No backend implemented either half: unconstrained
`Int` arithmetic wrapped on dotnet, the JVM and native in every build
(`2147483647 + 1` printed `-2147483648`), and the build profile reached
nothing but the `build_profile` define. #7852 then made `Byte op Byte` a
wrapping `Byte`, consistent with the other widths, pending this decision.

Three readings were considered: panic only in debug (the reference), always
wrap (the implementation), always panic. Always wrapping hides real bugs;
always panicking costs a branch per operation in the code that most needs to
be fast (graphics and games, docs/67).

## Decision

1. **`+`, `-`, `*` and unary `-` on `Int`, `Long`, `UInt`, `ULong` and `Byte`
   panic on overflow in a `debug` build and wrap (two's complement, modulo
   2^width) in a `release` build.** Compound assignments (`+=`, `-=`, `*=`)
   follow the operator. The panic message is
   `arithmetic overflow: <type> <addition|subtraction|multiplication|negation>`
   on every target. Range-constrained subtypes keep panicking on an
   out-of-range result in every build. `Nat`, division, remainder, shifts and
   conversions (`.toByte()` reduces modulo 256, `.toInt()` truncates) are
   unchanged.

2. **`.wrappingAdd(y)`, `.wrappingSub(y)`, `.wrappingMul(y)` and
   `.wrappingNeg()`** on those five types wrap in every build. Code that
   wants modular arithmetic (hashes, checksums, random number generators)
   says so with them.

3. **The standard library always wraps.** Its arithmetic is not checked,
   whatever profile the program is built with, so a `Std.*` routine behaves
   the same whether it was prebuilt (`Lyric.Stdlib.dll` on dotnet) or
   compiled from source into the program (JVM, native). The toolchain (the
   compiler and the shipped stdlib) is built with the release profile.

4. **Mechanism.** The type checker records every such operator with its
   exact type (`SymbolTable.overflowSites`). In a checked file,
   `Lyric.ContractElaborator.lowerOverflowChecks` rewrites each into the
   wrapping operation followed by an overflow test and a `panic`, evaluating
   each operand (and each part of a compound-assignment target) once; the
   wrapping methods become the plain operator in every build.
   `Lyric.Pipeline.pipeParseAndErase`, the entry point every target and
   build path shares, decides whether a file is checked from the resolved
   `build_profile` and the package name. No backend changes: every backend's
   operators already wrap.

## Consequences

- `docs/01` §2.1 drops its "not yet implemented" note and documents the
  wrapping methods; the book's numeric-types chapter and quick reference
  follow.
- Code in the repository that relied on silent wrapping in a debug build is
  moved to the wrapping methods.
- #6263 stays open for its two other parts: an optimization difference on
  the managed targets and the contract-elision policy in release builds.
- A debug build carries a check on every integer operation. A release build
  carries none.
