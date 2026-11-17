# 2026-11-17: a record meets an extern interface type in any converted position (D441)

`convertValue` now takes the host upcast (`hostUpcastKind`) that call arguments already took, so a function body, branch, `val` or return value that is a record `impl`ing an extern interface (`Seq` for `IEnumerable`, `Cursor` for `IEnumerator`) builds as a `CvBoxToHost` node. `for_loop_dispose_extern_self_test.l` builds 17 of 17 bodies under `--verify-ir`; `tir_build_self_test.l` covers it. Docs/70 status updated.
