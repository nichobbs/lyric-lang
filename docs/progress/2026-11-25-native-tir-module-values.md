# 2026-11-25: native TIR reads module-level values (D535)

`lyric build --target native --via-tir` lowers reads of module-level `val`s from TIR: literal initialisers are inlined, string literals are built at the read, and computed initialisers go through the hoisted initialiser's `mvensure.<init>` and global exactly as on the AST path. Covered by `scripts/ci/native-via-tir/globals.l` under AddressSanitizer. The census exposed a TIR builder evaluation-order bug for `inout` array element arguments (#9383), listed as a known gap in the census script.
