# 2026-09-27 — JVM `config { }` blocks observe `Std.Environment.setVar`'s overlay (#7594)

Found while verifying `lyric-web/tests/webtls_config_tests.l` on
`--target jvm` for #7578, after #7577 ("JVM setVar is observable") was
expected to make it pass. It still failed.

## Root cause

#7577 gave `Std.Environment.setVar`/`getVar` a process-wide overlay on the
JVM (`Std.EnvironmentHost.envOverlay`, a `ConcurrentHashMap` checked before
falling back to `System.getenv` — `hostGetVarOpt` in
`lyric-stdlib/std/_kernel_jvm/environment_host.l`). That overlay is
consulted by every *Lyric-level* `Std.Environment.getVar*` call.

A `config { }` block's generated JVM `<clinit>` (`Jvm.Lowering.
lowerConfigBlock`, `lyric-compiler/jvm/lowering.l`) instead read its env var
with a **direct, hand-rolled** `System.getenv` call — never consulting the
overlay. `Env.setVar("LYRIC_CONFIG_...", v)` followed by a read of a
`config { }` field (or a `config X from Template { }` materialisation,
which desugars to the same block, docs/58) never observed `v` on
`--target jvm`.

MSIL needs no such overlay: `System.Environment.SetEnvironmentVariable`
mutates the real process environment block that `.cctor`'s
`GetEnvironmentVariable` call reads back from directly, so `--target
dotnet` was unaffected — confirmed by reading `Msil.Codegen`/`Msil.Lowering`
`GetEnvironmentVariable` call sites; no change needed there.

## Fix

Two parts, both needed (a fix to only one still leaves either a silently
un-observed override or a runtime `NoClassDefFoundError`):

1. **Codegen** (`lyric-compiler/jvm/lowering.l`, `lowerConfigBlock`): the
   `<clinit>` now checks `Std.EnvironmentHost.envOverlay.containsKey(key)`
   first (inlined as raw bytecode — `getstatic` + `invokevirtual
   containsKey`/`get` + `checkcast String` — rather than calling
   `hostGetVarOpt`, whose `Option[String]` return is awkward to unwrap at
   this low-level codegen layer, mirroring its logic exactly) and only
   falls back to `System.getenv` when the key was never overlaid. Both
   branches `astore` into the shared temp slot and `goto`/fall through to
   ONE merge label with an EMPTY operand stack on every incoming edge —
   required by this whole file's StackMapTable computation, which assumes
   every branch target sees an empty stack (`jvmToVerifier`'s header
   comment); an earlier draft that left the resolved `String` live across
   the merge label would have hit the exact same failure class as the
   #7578 `dispatch_tests.l` `J008: stackmap simulation underflow`.

2. **Bundling** (`lyric-compiler/jvm/bridge.l`,
   `compileProjectToJarBundledWithRestored` — the single shared
   implementation behind `compileToJarBundledWithRestored`,
   `compileToJarBundled`, and every JVM single-file/project/restored-deps
   entry point): a file with a `config { }` block does not necessarily
   `import Std.Environment` (confirmed with a minimal repro: a bare
   `config { }` block with no `Std.Environment` import threw
   `NoClassDefFoundError: Std/EnvironmentHost` at class-load, even for a
   field that only ever reads its literal default — the class reference
   alone, unresolved, is fatal). New `fileHasConfigBlock`/the
   `anyConfigBlock` check forces `Std.EnvironmentHost` into the transitive
   bundle worklist whenever ANY project package or restored dependency
   declares a `config { }` item, mirroring the existing `Std.Core`
   implicit-prelude special case right above it in the same function.

## Verification

- Minimal repro (`config Settings { name: String = "default" }`, no
  `Std.Environment` import): before the fix, `NoClassDefFoundError:
  Std/EnvironmentHost` at class-load on `--target jvm` even reading the
  bare default. After: reads the real process env (`System.getenv`
  fallback) correctly, and a paired repro with `Env.setVar(...)` inside
  `main` before the field read observes the override.
- `config_block_self_test.l` (`lyric-compiler/lyric/`) gained a new
  `SetVarOverride` config block + a `Env.setVar`-before-first-access
  regression pair (its own dedicated config type, so no earlier method
  could have triggered its `<clinit>` first) — 6/6 on both
  `--target dotnet` and `--target jvm`.
- `lyric-web/tests/webtls_config_tests.l` restored to its original
  single-expectation form (the real override, unconditionally) and passes
  on both targets — see `docs/progress/2026-09-27-lyric-web-jvm-parity.md`.
- `bash scripts/ci/compiler-self-tests-batch.sh` — 2123 assertions, 0
  failures.
- `bash scripts/ci/jvm-generics-self-tests-batch.sh` — 114 assertions, 0
  failures.

## Docs updated

- `lyric-stdlib/std/time.l` — `Std.Time.sleepMillis`'s doc comment claimed
  the JVM binding was an unimplemented Phase 6 deliverable; it has been
  implemented (and used, in this same session's lyric-web fixes) for a
  while. Corrected to state it works on all three targets.
- `lyric-web/tests/webtls_config_tests.l` — the per-target
  `expectedCertPathForTest`/`setCertPathOverrideForTest` workaround this
  fix made unnecessary was reverted; see the lyric-web progress entry.
- `docs/10-bootstrap-progress.md` Tier status — new row, D-progress-1018.

Issue [#7594](https://github.com/nichobbs/lyric-lang/issues/7594) closed
with a comment pointing at this fix.
