# A bare name of a payload-bearing case is the case with wildcard fields (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

`match r { case Err -> true  case _ -> false }` over a `Result[Int, String]` names the prelude's `Err` case with no payload pattern. The checker binds nothing for it (it is not a variable that matches every value, #8230) and records no case reference, so the builder had no case for "a bare name the checker did not bind" and the TIR gate (D347) stopped the body; `lyric prove` reaches that gate first, so `examples/prove-unmodelled-match/bare_err.l` reported I0002 instead of its expected V0027.

## Decision

When a bare pattern name is neither a binding nor a recorded case and the scrutinee is a union that has a payload-bearing case of that name, the pattern is that case with one wildcard per payload field, each at the field's type under the scrutinee's type arguments (`payloadCaseOf`; the wildcards take fresh node ids). A name that is no case of the scrutinee's union stays counted.

## Results

`bare_err.l` builds and `prove-items.sh` reports V0027 as before; `scripts/ci/tir-builder-shapes-e2e.sh` gains `bare_payload_case`, which also runs the program (`Err` matches only `Err`).
