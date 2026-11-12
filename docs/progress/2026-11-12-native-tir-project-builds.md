# Native backend on TIR: project builds (docs/70 phase 4a, D520)

`lyric build --manifest ... --target native --via-tir` lowers every own package of a project from
TIR, not only a single file, and prints one fallback census over all of them. Bundled stdlib
packages stay on the AST path until the builder covers them. `native-via-tir/project/` pins
calls, a record and a union across a package boundary, both ways.
