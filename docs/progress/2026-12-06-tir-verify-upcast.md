# The TIR verifier checks upcasts (docs/70 phase 3c, D517)

## What shipped

- `Lyric.Tir.Verify` reports I0003 `convert-type` for a `CvUpcast` whose interface is not the symbol of the node's type (D517). The mismatch D516 fixed in mono was accepted before.
- `tir_verify_self_test.l`: a matching upcast verifies, a generic interface against its instance's type is reported.
