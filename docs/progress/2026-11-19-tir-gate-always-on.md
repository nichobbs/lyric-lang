# docs/70 phase 3a: the TIR gate is always on (D347)

`lyric build`, `test`, `run` and `prove` build every function body of a checked package as TIR and run the verifier on every build: a body the builder cannot build is the error I0002 (at the node it has no case for) and an ill-formed node is the error I0003 (at the function), both before any backend runs. `--verify-ir` and `LYRIC_VERIFY_IR=1` now only print the census. Phase 3a is complete; phase 3b (backends consume TIR) is next.
