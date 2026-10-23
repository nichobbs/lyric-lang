# D215 - The private generic helpers of a pub generic travel with it on every target

**Status:** shipped (#8427, generic helpers); supersedes the table in D204 item 1 for the private-generic column; non-generic helpers stay as D204 left them

## Decision

1. **A `pub` generic carries the private generics it reaches.** A generic's body is compiled into each package that
   calls it, and a consumer reaches a library only through public names (a restored dependency through contract
   metadata, which carries `pub` generic bodies; a private method of another assembly cannot be bound). The helpers
   a `pub` generic reaches, directly or through other helpers to a fixpoint, are therefore copied under a name unique
   to their package, `__priv_<Pkg>_<name>` (dots in the package become underscores), and the calls to them in the
   carried bodies are rewritten to match. `Lyric.Mono` keys imported generics by bare name and the first wins, so
   two packages' private `step[T]` would otherwise collide silently. The package's own code is untouched: only the
   carried copies are renamed.
2. **One implementation, in `Lyric.ContractElaborator.carryPrivateGenerics`**, used by
   - `Lyric.Pipeline.pipeAddGenericFuncs` for the packages of the same project (`requirePub`), so an in-bundle
     consumer on `--target dotnet` gets the helpers; and
   - `Lyric.ContractMeta.buildContractFromFile`, which writes the rewritten `pub` generic bodies and the renamed
     helpers (`visibility: "internal"`, so they are not public API) into contract metadata. A restored consumer
     reads them back as ordinary generics and `Lyric.Mono` specialises them. `Msil.Bridge` and `Jvm.Bridge` hand
     the contract builder the private generics `Lyric.Mono` strips, next to the `pub` ones they already re-attached.
3. **A name bound locally is not a call.** If a parameter, `val`/`var`/`let`, `for` pattern, lambda parameter, match
   arm or catch binding in a carried body has the same name as a helper, that body is left alone for that name.
4. **Non-generic helpers are unchanged.** A private non-generic helper still cannot be called from a body
   specialised into another package on dotnet and the JVM (T0123, docs/01 §3.3). Copying it would duplicate module
   state per consumer, and exporting it needs a visibility change in the emitted assembly; either needs its own
   decision and is tracked in #8427's follow-up.

| | private generic helper | private non-generic helper |
| --- | --- | --- |
| `--target native` | works | works (one module) |
| `--target jvm` | works | T0123 |
| `--target dotnet` | works (D215) | T0123 |

## Not done

- A restored generic function on `--target jvm` cannot be called at all today (#8089), so the JVM restored-JAR
  path has no carry test; the JVM source-dependency path is covered by a project run.
