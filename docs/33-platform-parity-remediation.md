# docs/33-platform-parity-remediation.md — Platform parity remediation plan

_Status: in progress (D-progress-227)._
_Backing decision: D058 (see `docs/03-decision-log.md`)._

## 1. Motivation

An audit of the repository on 2026-05-10 identified three classes of problem:

1. **Stale documentation** — docs and book chapters that contradict shipped code,
   contain unresolved `[TBD]` markers, reference wrong file paths, or repeat
   duplicate D-progress identifiers.
2. **JVM platform gaps** — five stdlib kernel shims present in `_kernel/` but
   absent from `_kernel_jvm/`, preventing `Std.File` and `Std.Process` from
   linking on the JVM target.
3. **Self-hosted emitter disconnect** — neither the self-hosted JVM emitter
   (`compiler/lyric/jvm/`) nor the self-hosted MSIL emitter
   (`compiler/lyric/msil/`) is reachable from `lyric build`.  The JVM emitter
   has a full high-level lowering layer (`Jvm.Lowering`, 29 `lowerXxx`
   functions) but no F# bridge.  The MSIL emitter has only the binary
   PE/opcode/tables layer; high-level MSIL lowering in Lyric is missing
   entirely.

This document is the authoritative plan for remediation.  Items are ordered by
priority and dependency.

---

## 2. Documentation fixes (Phase R1)

### R1-A  grammar.ebnf — add `defer` and `config` to soft-keyword list

`docs/grammar.ebnf` §1.6 lists soft keywords as:

```
'range' | 'derives' | 'forall' | 'exists' | 'implies' | 'scope_kind' | 'from'
```

`defer` and `config` are parsed as `TIdent` with contextual meaning in
`compiler/src/Lyric.Parser/Parser.fs` and must appear in the list.

Fix: append `| 'defer' | 'config'` to the soft-keyword production.

### R1-B  Decision log — renumber second D044

`docs/03-decision-log.md` has two entries both numbered D044.  The second
(self-hosted MSIL PE emitter approach) must be renumbered D058.

### R1-C  Language reference — inline resolved [TBD] answers

The TBD-index table in `docs/01-language-reference.md` §13 claims all twelve
items are resolved, but the body still contains `[TBD]` at §§2.4, 2.8, 2.9,
4.5, 5.2, 5.4, 7.1, 7.4, and 13.9.  Each occurrence must be replaced with a
short inline answer pointing to the resolution doc or decision-log entry.

### R1-D  Bootstrap progress — fix stale paths

Multiple entries reference `compiler/lyric/std/core_proof.l`.  The correct path
is `stdlib/std/core_proof.l`.  Affected entries: D-progress-198, D-progress-5585,
and every other line citing that path.  Also fix the same stale path in
`docs/12-todo-plan.md`.

### R1-E  Bootstrap progress — fix M5.2 status row

Line 112 of `docs/10-bootstrap-progress.md`:

```
| M5.2 stage 3+ — monomorphizer / MSIL emitter | Not shipped | — |
```

The self-hosted MSIL binary layer (M1–M83) has shipped.  High-level lowering
has not.  Split into two rows:

| Deliverable | Status |
|---|---|
| M5.2 stage 3a — self-hosted MSIL PE / opcode / tables layer (M1–M83) | Shipped (D-progress-213..D-progress-219) |
| M5.2 stage 3b — self-hosted MSIL high-level lowering (`Msil.Lowering`) | Not shipped |

### R1-F  Bootstrap progress — renumber duplicate D-progress identifiers

The following D-progress numbers are used by more than one entry.  Renumber
the **older** (lower in the file) entries to the new IDs below:

| Current ID | Location (approx. line) | New ID | Topic |
|---|---|---|---|
| D-progress-141 | 951 | D-progress-213 | MSIL PE emitter Stages M2a–M2d |
| D-progress-142 | 1011 | D-progress-214 | MSIL PE emitter Stage M3 |
| D-progress-143 | 1053 | D-progress-215 | MSIL PE emitter Stage M4 |
| D-progress-144 | 1092 | D-progress-216 | MSIL PE emitter Stage M5 |
| D-progress-145 | 1136 | D-progress-217 | MSIL PE emitter Stage M6 |
| D-progress-146 | 1179 | D-progress-218 | MSIL PE emitter Stage M7 |
| D-progress-147 | 1216 | D-progress-219 | MSIL PE emitter Stage M8 |
| D-progress-141 | 10391 | D-progress-220 | Tier 6 #16 — generic interface methods |
| D-progress-142 | 10473 | D-progress-221 | parser aspect from/config + lyric-otel |
| D-progress-143 | 10499 | D-progress-222 | lyric-logging library |
| D-progress-202 | 10545 | D-progress-223 | lyric-web library |
| D-progress-203 | 10624 | D-progress-224 | Maven shim — instance methods |
| D-progress-204 | 10676 | D-progress-225 | lyric-cache / lyric-db / lyric-health |
| D-progress-205 | 10751 | D-progress-226 | Q-J005 facade + Q-J007 sketch |

The newer (upper) entries that own IDs 141–147 and 202–205 are correct and must
not be renumbered.

### R1-G  Out-of-scope doc — update JVM and self-hosted entries

`docs/04-out-of-scope.md` marks both the JVM backend and the self-hosted
compiler as "DEFERRED post-v1".  Both are in active development.  Update to
"Phase 6 in progress — self-hosted only; not wired to `lyric build` (see
docs/33-platform-parity-remediation.md)".

### R1-H  Status banners — flip shipped items

- `docs/24-test-runner-plan.md`: banner says "in progress".  `lyric test` v1
  shipped in D-progress-138.  Change to "shipped (v1 — D-progress-138)".
- `docs/22-distribution-and-tooling.md`: header says "Phase 6 dependency".
  Stage 1 distribution shipped in D-progress-126.  Update header.

### R1-I  todo-plan — flip Band D2 to shipped

`docs/12-todo-plan.md` Band D2 items 5–14 (lines 721–747) are listed as
outstanding M4.3 work.  All shipped per D-progress-113..116.  Move to a
"shipped" subsection or strike through.

### R1-J  Open questions — fold or reference Q-J series

`docs/06-open-questions.md` does not contain Q-J001..Q-J008, which live only
in `docs/18-jvm-emission.md`.  Add a §"JVM-specific questions" section to
`docs/06-open-questions.md` pointing to `docs/18-jvm-emission.md §"Open
questions"` as the canonical location.

Also flip Q-J005 (opaque-type Java facade) to RESOLVED: `lowerOpaqueFacade`
shipped in D-progress-226.

---

## 3. Book chapter fixes (Phase R2)

### R2-A  appendix-b — correct `--target jvm` claim

`book/chapters/appendix-b-quick-reference.md` line 659 says:

```
lyric build --target jvm <file.l>   # target JVM bytecode
```

This is incorrect today.  `--target jvm` only switches the kernel directory;
the output is still a `.dll`.  Replace with an honest callout:

> `lyric build --target jvm <file.l>` — selects JVM kernel bindings
> (`_kernel_jvm/`).  Full JAR emission requires the self-hosted JVM emitter
> bridge (in progress — see `docs/33-platform-parity-remediation.md §4`).

### R2-B  aspects chapters — remove "deferred" bullet for aspect templates

`book/chapters/21-aspects.md` §21.6 lists aspect templates as "Planned
(deferred)".  They shipped in D051 / D-progress-221.  Remove the bullet.

### R2-C  testing chapter — use explicit source path in examples

`book/chapters/14-testing.md` examples omit the required positional `<file.l>`
argument.  Update all `lyric test` invocations to `lyric test <file.l>`.

### R2-D  getting-started — add publish/restore/sdk-info to toolchain table

`book/chapters/01-getting-started.md` toolchain table omits `lyric publish`,
`lyric restore`, and `lyric --sdk-info`.  Add rows for each.

### R2-E  standard-library chapter — move Std.Logging to service-library note

`book/chapters/12-standard-library.md` §12.1 lists `Std.Logging` in the
stdlib inventory.  It lives in the third-party `lyric-logging` library, not
`stdlib/std/*.l`.  Add a footnote and move it out of the table or annotate.

---

## 4. JVM kernel parity (Phase R3)

Five kernel shims exist in `stdlib/std/_kernel/` but not in
`stdlib/std/_kernel_jvm/`:

| Missing file | Provides |
|---|---|
| `file_host.l` | `Std.File` — text and byte file I/O |
| `process_host.l` | `Std.Process` — subprocess launch |
| `unicode_host.l` | `Std.Encoding` unicode normalization |
| `jvm.l` | `Std.Jvm` — JVM escape hatch (already present in JVM kernel?) |
| `jvm_exception.l` | `Std.Jvm.Exception` wrappers |

Action: write JVM-target implementations of `file_host.l`, `process_host.l`,
and `unicode_host.l` under `stdlib/std/_kernel_jvm/`.  Each file must export
the same surface as its `_kernel/` counterpart, implemented using Java stdlib
externs (`java.nio.file.Files`, `java.lang.ProcessBuilder`,
`java.text.Normalizer`).  `jvm.l` and `jvm_exception.l` are already present
in the JVM kernel or covered by `Std.Jvm.catch` (D-progress-224); verify and
document.

---

## 5. Self-hosted JVM emitter — CLI wiring (Phase R4)

### 5.1 What exists

- `compiler/lyric/jvm/lowering.l` — complete high-level lowering (29 functions)
- `compiler/lyric/jvm/driver.l` — `writeJarFromClasses` JAR assembler
- `compiler/lyric/jvm/bytecode.l`, `classfile.l` — binary class-file emission
- `compiler/lyric/jvm/self_test_b*.l` — 125 self-tests (B3–B125)
- `compiler/lyric/lyric/parser/` — self-hosted parser (`Lyric.Parser`)
- `compiler/lyric/lyric/type_checker/` — self-hosted type checker
  (`Lyric.TypeChecker`)

### 5.2 What is missing

A **source-to-JAR bridge** in Lyric that chains:

```
source text  →  Lyric.Parser  →  Lyric.TypeChecker  →  Jvm.Codegen  →
  Jvm.Lowering.lowerPackage  →  Jvm.Driver.writeJarFromClasses  →  JAR
```

`Jvm.Codegen` is the new piece: it walks the typed AST and constructs
`Jvm.Lowering.LPackage`.  This is the monomorphizer / codegen layer for
the JVM target.

### 5.3 New package: `Jvm.Codegen`

Location: `compiler/lyric/jvm/codegen.l`
Package: `Jvm.Codegen`
Public entry point:

```
pub func codegenPackage(ast: in Lyric.TypeChecker.TypedPackage): Jvm.Lowering.LPackage
```

Supported subset for Phase R4:

- Top-level `func` declarations with primitive parameters and return types.
- `record` declarations with primitive fields.
- `union` declarations with primitive cases.
- Expressions: arithmetic, boolean, string literal, variable load/store,
  function call (static), `return`, `if`/`else`, `while`, `match` (literal
  and binding patterns).

Unsupported in Phase R4 (deferred to follow-up):

- Generics, async, protected types, wire blocks, aspects, FFI (`@extern`).
- Cross-package references beyond the stdlib primitives.

### 5.4 New package: `Jvm.Bridge`

Location: `compiler/lyric/jvm/bridge.l`
Package: `Jvm.Bridge`
Public entry point:

```
pub func compileToJar(source: in String, outputPath: in String,
                      packageName: in String): Bool
```

This function:
1. Calls `Lyric.Lexer.lex(source)`.
2. Calls `Lyric.Parser.parseTokens(...)` to get a `ParseResult`.
3. Calls `Lyric.TypeChecker.check(...)` to get a `TypedPackage`.
4. Calls `Jvm.Codegen.codegenPackage(...)` to get an `LPackage`.
5. Calls `Jvm.Lowering.lowerPackage(...)` to get `List[ClassFile]`.
6. Converts to `List[Jvm.Driver.BuiltClass]` and calls `writeJarFromClasses`.
7. Returns `true` on success.

### 5.5 F# bridge: `SelfHostedJvm.fs`

Location: `compiler/src/Lyric.Cli/SelfHostedJvm.fs`

Mirrors `SelfHostedFmt.fs`:

- Compiles a driver Lyric program that `import Jvm.Bridge` to trigger
  precompilation of the entire dependency chain.
- `Assembly.LoadFrom` all cached stdlib DLLs.
- Reflects out `Jvm.Bridge.Program.compileToJar`.
- Caches the delegate; one compile per process.

Public API (F#):

```fsharp
module Lyric.Cli.SelfHostedJvm
val compileToJar : source:string -> outputPath:string -> packageName:string -> bool
```

### 5.6 CLI wiring in `Program.fs`

When `compileTarget = Emitter.Jvm`, after the current `emitSingle` call,
replace the MSIL path with:

```fsharp
let jarPath = Path.ChangeExtension(outputPath, ".jar")
let ok = SelfHostedJvm.compileToJar source jarPath packageName
```

The `.dll` is still produced (for tooling that inspects it); the JAR is the
primary runnable artefact.

---

## 6. Self-hosted MSIL emitter — high-level lowering (Phase R5)

### 6.1 What exists

- `compiler/lyric/msil/pe.l` — raw PE binary writer
- `compiler/lyric/msil/opcodes.l` — IL opcode encoding
- `compiler/lyric/msil/tables.l` — CLI metadata table helpers
- `compiler/lyric/msil/heaps.l` — `#Strings`, `#Blob`, `#GUID`, `#US` heap writers
- `compiler/lyric/msil/assembler.l` — `assemblePe` — top-level assembler taking
  pre-built bodies and metadata rows

### 6.2 What is needed: `Msil.Lowering`

Location: `compiler/lyric/msil/lowering.l`
Package: `Msil.Lowering`

Mirrors `Jvm.Lowering` but targets the CLI/MSIL binary format.  The MSIL
intermediate representation reuses the same `LInsn`-family union approach:

```
pub union MsilInsn { case MNop | case MRet | case MLdarg(slot: Int) | ... }
pub record MFunc { flags: Int; name: String; ... }
pub record MRecord { className: String; ... }
pub record MPackage { packageName: String; items: List[MPackageItem] }
pub func lowerMFunc(f: in MFunc, tables: in MsilTables): MethodBody { ... }
pub func lowerMRecord(r: in MRecord, tables: in MsilTables): Unit { ... }
pub func lowerMPackage(pkg: in MPackage): List[Byte] { ... }
```

Key differences from JVM lowering:

- No constant pool (MSIL uses metadata token references directly).
- Method bodies are CIL byte sequences, not JVM bytecode; branch offsets
  are 4-byte signed integers from the instruction after the branch opcode.
- Stack-map frames are absent (CLR computes them from PDB / metadata).
- Calling convention: `callvirt` for virtual, `call` for static/non-virtual.
- Records lower to `TypeDef` rows with `Field` rows; constructors are
  `MethodDef` with `.ctor` name and `MethodAttributes.SpecialName`.

Phase R5 supports the same subset as Phase R4 (`Jvm.Codegen`): primitive
types, records, unions, top-level functions, arithmetic, control flow.

### 6.3 New package: `Msil.Bridge`

Location: `compiler/lyric/msil/bridge.l`
Package: `Msil.Bridge`

Same pattern as `Jvm.Bridge` but calling `Msil.Lowering.lowerMPackage` and
writing a `.dll` via the existing `Msil.Pe.buildPe` infrastructure.

### 6.4 F# bridge: `SelfHostedMsil.fs` (future)

Not wired in Phase R5 — the F# MSIL emitter remains authoritative.
`SelfHostedMsil.fs` is a Phase R6 deliverable once `Msil.Lowering` passes
the same self-test coverage as `Jvm.Lowering` (125 B-stages).

---

## 7. Parity milestone

Both self-hosted emitters reach **Phase R parity** when all of the following
are true:

- `lyric build --target dotnet <file.l>` — F# emitter (unchanged; baseline).
- `lyric build --target jvm <file.l>` — produces a runnable JAR via
  `Jvm.Bridge` + `SelfHostedJvm.fs`.
- `lyric build --target dotnet-sh <file.l>` — produces a `.dll` via
  `Msil.Bridge` + `SelfHostedMsil.fs` (new flag, experimental).
- All three paths pass the same 20-program smoke-test suite covering:
  hello-world, records, unions, arithmetic, control flow, contracts.
- `lyric test` passes on all three targets.

---

## 8. Work tracking

New D-progress entries for this remediation:

| ID | Deliverable |
|---|---|
| D-progress-227 | This doc + R1 documentation fixes + R2 book fixes |
| D-progress-228 | R1-F D-progress renumbering |
| D-progress-229 | R3 JVM kernel shims (file_host, process_host, unicode_host) |
| D-progress-230 | R4 Jvm.Codegen + Jvm.Bridge |
| D-progress-231 | R4 SelfHostedJvm.fs + CLI wiring |
| D-progress-232 | R5 Msil.Lowering (high-level lowering) |
| D-progress-233 | R5 Msil.Bridge |
| D-progress-234 | Parity milestone smoke-test suite |
