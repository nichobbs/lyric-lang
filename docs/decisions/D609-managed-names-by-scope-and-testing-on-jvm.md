# D609 - Bare names resolve by package scope on dotnet and the JVM; `lyric-testing` builds for the JVM (#9130, #9135)

**Status:** shipped.

## Context

D606/D607 fixed constructor-name collisions across packages on native. The same
programs failed on dotnet (`InvalidProgramException`) and the JVM
(`VerifyError`): both backends tried a bare call as a construction first, from
a bundle-wide name table.

## Decision

1. A call the type checker resolved to a function (`calleeSites`, D336) is
   never a construction.
2. Otherwise a bare constructor name is resolved one scope at a time: the
   calling package's own declaration of any kind, then an imported package's,
   then (nothing in scope) the single bundle-wide declaration, as on native. A
   record of a nearer scope beats a case of a farther one.
3. The JVM resolves a bare function through the file's imports when the checker
   recorded no site for it (a contract clause an `impl` inherits from an
   interface of another package), as dotnet already did. This is what kept
   `lyric-testing` off the JVM (`J002` on `allHaveIds`); its manifest declares
   `"jvm"` again, superseding the dotnet-only consequence recorded in D604.

## Left open

Lowering constructors from the checker's resolved symbol (docs/70 phase 4)
needs the checker to record the symbol of each constructor call; until then the
backends resolve by scope. An inherited interface clause is resolved in the
implementing package's scope, not the interface's declaring package's.
