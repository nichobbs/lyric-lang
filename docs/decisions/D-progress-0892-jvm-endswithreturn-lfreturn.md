# D-progress-892 — JVM codegen: `endsWithReturn` was missing an `LFreturn` case, so a `Float`-returning terminating branch got dead fallthrough code and a bad StackMapTable offset (#5510)

**Status:** shipped

**Context.** A union carrying a `Float` payload, extracted via `match` with
an explicit `return` on every arm, failed at class load with
`VerifyError: StackMapTable error: bad offset`.

**Root cause.** `Jvm.Codegen.lowerMatchExpr` (`03_match.l`) asks
`endsWithReturn(insns)` whether a lowered arm already terminated control
flow, to decide whether to append a store-to-result-slot + `goto`-to-join
after it. `endsWithReturn` (`06_items.l`) is a plain instruction-list scan
with one `case` per return-family `LInsn`: `LReturn`, `LIreturn`, `LLreturn`,
`LDreturn`, `LAreturn`, `LAthrow` — but not `LFreturn` (the `Float`-returning
opcode). A structurally identical sibling function, `lastInsnIsTerminator`
(`05_stmts.l`), already covers `LFreturn` correctly; the two were never kept
in sync. So a match arm ending in `freturn` was misjudged non-terminating:
`lowerMatchExpr` appended dead fallthrough instructions (store + `goto`)
after the arm's own `freturn`, and that dead `goto`'s target landed one byte
past the method's real bytecode end — an invalid branch offset the verifier
rejects at class load, before the JIT or the program's own logic ever runs.

`endsWithReturn` gates three call sites, all sharing the identical gap for
any `Float`-returning terminating branch: `lowerMatchExpr` (`03_match.l`,
the reported repro), `lowerIfExpr` (`02_exprs.l`, an `if`/`else` where both
arms `return` a `Float`), and the function-/method-body trailing-statement
checks in `06_items.l` itself.

**Fix.** Added the missing `case LFreturn -> { return true }` arm to
`endsWithReturn`, matching `lastInsnIsTerminator`'s existing coverage.
One line; no other call site needed a change since the fix is in the shared
helper.

**Verification.** `control_flow_jvm_self_test.l` — the existing regression
suite for `endsWithReturn`/`blockTerminates` — had zero `Float`/`Double`
return-type coverage among its 17 pre-existing cases (all `Int`/`String`/
reference-typed), which is exactly why the missing `LFreturn` case went
undetected: `LIreturn`/`LAreturn` were already covered. Two new cases close
that gap: a `match` arm extracting a `Float` union payload via explicit
`return` (the reported repro shape) and an `if`/`else` where both arms
`return` a `Float` (the `lowerIfExpr` sibling gap). Negative control:
reverting the fix and rebuilding reproduces the exact reported
`VerifyError: StackMapTable error: bad offset` on the new match-arm test,
confirmed via `javap -v -p` disassembly showing two dead `goto` instructions
immediately after `freturn` at offsets 36 and 44, targeting offset 61 — one
byte past the method's actual bytecode end at offset 60. With the fix
restored: `control_flow_jvm_self_test` 19/19. No regression in a broader
JVM self-test sweep: `record_method_jvm_self_test`,
`out_inout_jvm_self_test`, `control_flow_jvm_self_test`,
`try_catch_expr_jvm_self_test`, `silent_miscompile_guard_jvm_self_test`,
`middle_end_passes_jvm_self_test` all green.
