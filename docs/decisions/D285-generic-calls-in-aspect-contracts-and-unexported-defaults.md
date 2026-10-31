# D285 - Generic calls in aspect contracts, unannotated generic records, unexported defaults

**Status:** shipped (#7530, #8440, #8076 partly, #7917 verified).

## Context

Four fixes from the generics group share one root: a compiler pass that
decides from too little information.

## Decision

1. **Aspect contracts are specialised after weaving (#7530).** The weaver
   builds each wrapper, and elaborates the aspect's `requires:`/`ensures:`
   into it, after `pipeCheckAndMono`, so a generic call in one
   (`ensures: isSome(result)`) never reached mono and codegen found no
   function for it (T0123). `pipeWeave` now runs `Lyric.Mono` once more over a
   file that holds a woven wrapper, with the generics mono saw plus the file's
   own (`pipeWovenGenerics`), and drops any specialisation the first run
   already made. A file with no wrapper is untouched.
2. **A generic record built without a type annotation types its binding
   (#8440).** `Lyric.Mono` inferred the type arguments of
   `Box(v = 0.5)` only when an argument was a lambda, so `b.v` had no type and
   `render(b.v)` stayed erased: an unboxed field was passed as `object`
   (`InvalidProgramException`). The arguments' inferred types now bind the
   record's parameters for any argument. The annotation is still added only
   for the lambda case.
3. **An unexportable restored default is a dedicated error (#8076, partly).**
   D168 item 4 lists defaults that get no thunk. The contract now writes such
   a default as a call to `__lyric_default__unexported`, and the checker
   reports **T0218** when a call leaves the argument out, instead of T0042
   "which has no default". The generic thunk that would let the default be
   used is not built; see the PR for the plan. Defaults of methods in a
   generic `impl` are not rendered at all (the impl is bodyless) and are
   unchanged.
4. **#7917 needed no change.** D-progress-946 already resolves a specialised
   body's bare callees in its declaring package; a project test now pins it.
