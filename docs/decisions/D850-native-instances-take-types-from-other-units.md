# D850: a monomorphised instance may take a type argument another unit lays out

Status: accepted (docs/70 phase 4a, part 7; D520 slice 40; extends D533).

## Decision

The code generator registers the layout of each generic instance (`Option[T]`, `Result[T, E]`, a user generic) per unit, from the record, union, enum and distinct layouts of that unit. An instance whose argument is a type another package declares (`Option[Std.Process::PipedProcess]` used from a unit that only imports `Std.Process`) found no layout for the argument and stayed unregistered, so every function touching it fell back. `Ctx.tirKnownAll` now accumulates the LLVM type of every type laid out in any unit, by symbol (symbols are shared across the bundle), and `tirInstArg` consults it after the unit's own map. Only argument resolution reads it: an instance's own layout is still registered per unit, because the lowering looks layouts up in the unit's maps.

`LYRIC_NATIVE_TIR_TRACE=1` also prints each instance left unregistered and the argument that blocked it.

## Not done

A record with an invariant (`Std.Http::Url`) is not given a TIR layout until type invariants are elaborated on TIR (D502 "not done", tracked in #9394's follow-ups), so `Result[Url, HttpError]` stays on the AST path.

## Verification

The native census lowers 1604 of 1710 functions from TIR (1587 before); `native-via-tir-e2e.sh` and `make test-native` pass.
