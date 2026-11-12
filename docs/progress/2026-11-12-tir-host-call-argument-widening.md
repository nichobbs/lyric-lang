# 2026-11-12 - TIR: host call arguments widen as the host resolves overloads (D600)

`Math.Sqrt(4)` and `Math.Sqrt(9i64)` build: an integer argument to a `Float` or `Double` host parameter is a `CvWiden`
node (`build_host.l`). Two tests added to `tir_build_self_test.l` (`tir_build` 153/153). The docs/70 phase 3b status
records that the generated nodes' spans are deferred behind D370 S2/S4.
