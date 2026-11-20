# D419 - A config block field read and a shared `Enum.Case` build in the typed IR (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

Two shapes the checker types and records no reference for were counted unbuilt (I0002) by the typed IR builder:

- `Settings.port` or `Pkg.Settings.port`, a read of a field of a `config` block (docs/25). The block's name is no value, so the checker records no type for the receiver and the builder, which built the receiver first, failed on it: four bodies of `Grpc` (`serverConfigProblem`, `start`, `startHandle`, `startHandleAt`) and one test body of `Web` (`EnvWebTls.certPath`).
- `LogLevel.Info` where two packages declare an enum `LogLevel` (`Std.Log` and `Std.Logging`). The checker leaves such a read to the expected type (a bare name two enums share is told apart the same way, D446), and the builder had that rule for the bare spelling only: six test bodies of `Lyric.Logging`.

## Decision

`buildFieldRead` first tries `buildConfigFieldRead`: a receiver the checker recorded no type for, that names a `config` block of the program with the field, is a module value, `XGlobal` of the DefPath `Pkg::Cfg::field` (the form a union case has, `Pkg::Union::Case`), registered with the type the checker gave the read so the verifier's symbol check holds. Then `buildQualifiedSharedCase`: a receiver that names no value (untyped or an error type) whose last segment is the name of the enum the node settled at is that enum's case, as `sharedCaseRead` builds the bare one. Neither changes what the checker accepts, so no program changes meaning.

The backends do not lower from TIR yet (docs/70 phase 3c), so this is the IR's form only: the config block's own lowering (a sealed static class with a `.cctor` on dotnet, a `<clinit>` on the JVM) and its reads are as they were, and `config_block_self_test.l` still passes on both targets.

## Results

`config_field_read` (a single-file config read, exit 7) and `logging_shared_case` (lyric-logging's tests build every body and pass) in `scripts/ci/tir-builder-shapes-e2e.sh`. `Grpc` builds all 36 bodies of `grpc.l` (was 32), `lyric-logging`'s tests 15 of 15 (was 9), `Web`'s `WebTlsConfigTests` 3 of 3.
