# TIR builder: errors name a position; a type spelled by package resolves without the file's imports (D769)

Every builder message without a position gets the innermost expression's `line:column`, so a gate failure points at code. `annotatedTy` resolves the checker's own spelled annotations (a type of a package the file does not import is spelled `Pkg.Type`) without the import rule, which cleared `reportViewports` in `lyric-ui/native/host/src/run.l` on the native build. Test: `unimported_type_in_open_join` in `scripts/ci/tir-builder-shapes-e2e.sh`.
