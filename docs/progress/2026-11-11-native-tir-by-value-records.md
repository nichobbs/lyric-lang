# Native backend on TIR: by-value records (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers construction, field reads and `.copy` of by-value records
(`insertvalue` / `extractvalue`) from TIR. The code generator keeps record layout and
hands the lowering a per-symbol `TirRecLayout`; a record it did not register by value
stays on the AST path with a census reason.

`native-via-tir-e2e.sh` builds `native-via-tir/records.l` (nested records, `.copy`,
records as parameters and results) both ways and compares the output with the
specified output.
