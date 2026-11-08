# D542 - `lyric build --verify-ir` and the TIR census gate (docs/70 phase 3a, #8613)

**Status:** shipped; extends D540 and D541.

## Context

`LYRIC_VERIFY_IR=1` reported the typed-IR census, but only as an environment
variable, and nothing in CI guarded the claim that every body the builder
produces verifies.

## Decision

1. `lyric build --verify-ir` sets the same switch for the build, so the node
   numbering and the census (I0002 per kind, I0003 per verifier rule) need no
   environment variable. It is in the usage line and the book's CLI reference.
2. `scripts/ci/tir-census.sh` builds the standard library's test programs with
   it and totals bodies built, bodies not yet built (I0002) and I0003 per rule.
   Any I0003 fails the run, and so does a program the census cannot judge (a
   build that stops before the checker finishes), as the I0001 census does
   (D386). The programs it cannot judge are listed in the script with a reason.
   I0002 is reported, not gated, until it reaches zero (docs/70 §12.2). CI runs it
   at the end of `scripts/ci/library-tyerr-census.sh`, so in that job: `ci.yml` is
   within 21 bytes of the soft size ceiling (`check-workflow-size.sh`), so a job of
   its own does not fit.
3. The first full run found, and this change fixes, defects in the builder that
   no hand-picked file showed: an `out` or `inout` parameter was not a mutable
   local; a block ending in `return`, `throw`, `break` or `continue` was typed
   `Unit` instead of `Never`; a module `val` or `const` read had no entry. A
   function body now meets the declared return type through a conversion the
   types derive, or the build counts the conversion it cannot (before, it
   produced a body of the wrong type).

## Measured

`scripts/ci/tir-census.sh` over the 98 stdlib test programs it can judge (101, less
the three it lists as skips): I0003 was 38 on the first run and is **0** after these
fixes, bodies built 809 of 1165 (it was 813 before the return-type coercion: four
bodies whose type needed an interface upcast or similar conversion are now counted as
I0002 instead of being produced ill-formed). A dependency union case's payload
(`H2Event.H2SettingsReceived`) is resolved in its declaring package's scope.
