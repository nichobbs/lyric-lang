# A primitive array an untyped host chain returns is the slice of its element (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`val grown = JArrays.copyOf(src, 5)` followed by `JArrays.asList(grown)` (the CI step "genuine primitive array" in `ci.yml`, which pins that a real `int[]` passed to `Arrays.asList`'s `Object[]`-only overload fails loud) was stopped by the TIR gate (D347) at `copyOf`: the checker leaves a host call's result untyped (docs/01 section 2.11) and the builder types the chain itself from the host metadata (D444), but `hostArrayAsSlice` accepted only `byte[]` and arrays of host classes. Where the checker does type a host call, it types an `int[]` result as `slice[Int]`.

## Decision

`hostArrayAsSlice` also accepts the arrays of the primitives a Lyric slice holds (`Byte`, `Int`, `Long`, `Double`, `Bool`, `Char`), as the slice of that primitive. The call node carries `CvFromHost`, which is where a backend converts the host array to the slice, so the builder converts no element. An array of `String` stays counted.

## Consequences

The CI program builds, and the JVM backend still rejects `Arrays.asList(grown)` with "no matching static overload": the program is not newly accepted, the gate no longer stops it first. That negative case is a representation difference TIR types do not express (a slice from a host `int[]` is an `int[]` at run time, one from a literal an `Object[]`), recorded here for the backend work in docs/70 phase 4.
