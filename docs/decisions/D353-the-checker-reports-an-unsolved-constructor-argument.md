# D353 - The checker records a construction with an unsolved type argument (W0038) (docs/70 phase 3a, #8760)

**Status:** step one: the warning W0038. The error, and deleting Mono's `ctorFill`
and `importedFill`, follow once CI's logs show no W0038 (D339 lists the order).

## Context

D339 made the checker report a generic *function* call whose type argument
nothing fixes (T0224). The table behind it (`SymbolTable.unsolvedCallSites`)
holds function calls only, so a construction such as `val r = Ok(value = 7)`,
whose `E` nothing fixes, was never reported: `Lyric.Mono` typed it
`Result[Int, Object]` through `ctorFill`, the erased default docs/70 section 5.2
removes.

## Decision

1. A union-case construction whose arguments leave a type parameter of its union
   unsolved is recorded as a constructor site (`UnsolvedCallSite.ctor`), keyed by
   the callee's span like a function call, and reported at the end of the file
   as **W0038** ("cannot infer type argument(s) 'E' of 'Ok' from the
   construction's arguments or its expected type; give it an expected type").
2. It is fixed by what fixes a function call (the call's expected type, solved
   from its own and its parent's parameter type; a recorded type-argument site),
   with one difference for the open binding that holds it: `val r = Ok(value = 7)`
   is an open binding, and a function call it holds counts as fixed by the
   binding's own site, but a construction counts only once the binding got an
   annotation (`localBindingTypeSites`), since the binding is the very case
   being judged. A construction that is the operand of `?` (`Err(error = e)?`)
   never yields a value, so its success type is open by design and the propagate
   tables (#8181) hold it.
3. The same indeterminate rule applies (an argument typed `TyError`, one that
   passes an open binding, a read of an open-typed value), and a construction
   named by a local binding or without a source position is not recorded.
4. A partly solved construction held by a binding (`val r = Ok(value = 7)` then
   `take(r)` with `take(r: in Result[Int, String])`) is reported: the checker
   opens a binding only for an evidence-free construction (`None`, `newList()`),
   so a later use does not fix `E` there. Whether code relies on that is what
   CI's census is for; if it does, the binding site is what to extend.
5. Record constructors (`Box(items = newList())`) and a nullary case used as a
   value are not recorded yet; Mono's `ctorFill` covers the union-case call.

## Census

The compiler and stdlib closure (`./scripts/bootstrap.sh --stage 2`) has no
W0038. The ecosystem libraries, examples, fixtures and the JVM and native
sources are reachable only through CI, whose job logs are the census for the
error step.
