# D517 - The TIR verifier checks that an upcast names the interface its node's type is

**Status:** accepted, implemented in `Lyric.Tir.Verify` (docs/70 phase 3c, §6.4; follows D516)

## Decision

1. **`CvUpcast(iface)` rule.** When the converted expression's type is a named type, its symbol is the conversion's `iface`; otherwise I0003 `convert-type` ("CvUpcast names interface #N but the expression has type T"). It holds before monomorphisation (`Holder[Int]` names `Holder`) and after (D516 renames both to the instance).
2. A node whose type is not a named type (a nullable, a type parameter, a host type) is not checked: the rule reports only the mismatch D516 fixed, so it cannot turn a working program into an I0003.
