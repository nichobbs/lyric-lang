# Native backend on TIR: the `--via-tir` build path and the fallback census (docs/70 phase 4a, D520)

`lyric build --target native --via-tir` builds the checked user file as a TIR
package (`buildPackage`, D570), hands it to the native code generator, and
lowers each function `Lyric.LlvmTir` covers from TIR. The code generator keeps
the IR names, linkage and attributes of the AST lowering, refuses a TIR lowering
whose signature differs, and counts every function that stays on the AST path
with its reason; the build prints the census. `native-via-tir-e2e.sh` runs a
scalar program both ways and compares the output and the census.

Single-file builds only; project builds, the bundled packages, and the
constructs the lowering does not cover yet (strings, records and unions with
ARC, calls into the standard library, tuples, lists, closures) are the next
slices.
