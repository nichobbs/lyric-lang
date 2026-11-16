# 2026-11-16 - Checker: host class results are typed as the extern type that names them (D493)

docs/70 phase 3a, #8613. A host member call whose result is a host class with an exact-match `extern type` in scope now has that type, so a chain of host calls continues with a recorded callee. Standard library census: 2443 of 2563 bodies built (2434 before), 0 I0003. Shape: `host_class_result_chain` in `tir-builder-shapes-e2e.sh`.
