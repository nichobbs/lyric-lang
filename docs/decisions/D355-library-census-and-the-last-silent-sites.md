# D355 - The ecosystem census, and the last silent TyError shapes (docs/70 phase 3a, D354, #8613)

**Status:** accepted; fifth slice of the non-callee silent `TyError` sites.

## Context

D354 took the silent-site census of the compiler and standard library closure
to zero. That closure is not the whole code base: the ecosystem libraries are
checked by the same checker, and the I0001 gate rejects whatever silent site
it meets in any program. Running the gate (`LYRIC_TYERR_GATE=1`, W0036) over
every library manifest on both targets found 92 further sites in 11 packages,
in a small number of shapes.

## Decision

1. **Typed from what the program says.**
   - `Cfg.field`, a read of a `config Cfg { field: T = ... }` block, is `T`
     (`configFieldReadType`).
   - `Std.Http.GET`, a case of an enum named through its package, is its enum.
   - `Union.Case` read as a value (`PluginIssueKind.BadContributions`, the form
     generated plugin code uses) is the union (`qualifiedUnionCaseSymbol`).
   - A package's own enum shadows an imported enum of the same name: a bare
     `LogLevel.Info` inside the package declaring `LogLevel` names that one,
     whichever other package declares a `LogLevel` too.
   - `Pkg.ExternType.new(...)` and members read through a package-qualified
     `extern type` are typed like the bare spelling (`externTypeSymbolOfExpr`).
   - The body and the handlers of a value-position `try` join their open type
     arguments: `try { Ok(()) } catch Bug as b { Err(e) }` is a `Result[Unit,
     E]`, so a `match` on it binds `Err(e)` at `E`.
2. **Named, not silent.**
   - A read of a field of a generic record instance is `tyErrorGeneric()`: the
     field's own type parameter is erased until generic bodies are typed with
     rigid parameters (the reason #8018 gives for not typing it `T`).
   - A generic call whose result no argument fixes (`default()` and
     `sentinel[T]()` used as an argument, typed by where it is used) is
     `tyErrorGeneric()`; the result type is still recorded for `Lyric.Mono`.
   - A member call on a receiver that is itself unchecked, or whose silence is
     exempt (a qualifier or callee position), is `tyErrorUnresolved()`, never
     a silent cascade of an exemption.
   - A bare enum case name that several enums share (`Error`), read with no
     expected type, is `tyErrorUnresolved()`: the expected type tells the enums
     apart, and an expression read on its own does not have one.
3. **The native bridge stays resolver-free.** No file under
   `lyric-stdlib/std/_kernel_native/` declares an `extern type` or an
   `import extern`; native kernels are C-symbol `extern func`s with fully
   declared signatures, so there is no host type to read metadata for. "Cannot
   say" (`tyErrorHost()`) is the complete answer on `--target native`, and it is
   not counted by the gate. #8825 records this and is closed with this decision;
   it is reopened if native grows `extern type`.

## Census

`LYRIC_TYERR_GATE=1` over the library manifests: 92 sites -> 0 on both targets
(`scripts/ci/tyerr-census.sh` prints the compiler and stdlib closure; the
library sweep is the loop in this entry's progress note). The `lyric-ui` JVM
build reports `M0004` for six imported generic calls both before and after this
change; that is an independent defect, filed separately.

## Consequences

- No new rejection: every site above built before and builds now. The gate
  stays a warning until a CI census over the libraries is wired in (the next
  slice), which is docs/70 §12.2 step one for I0001.
- The library census is a CI gate (`scripts/ci/library-tyerr-census.sh`, job
  `library-tyerr-census`): the count is zero, so any new silent site fails the
  PR. Builds that stop before the checker finishes are listed as unchecked, not
  counted as clean.
- The remaining silent source is the `tyErrorSilent()` returns that do not
  follow a diagnostic; each is classified in the slice that switches W0036 to
  I0001.
