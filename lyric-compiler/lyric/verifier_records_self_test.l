//! verifier_records_self_test.l — #3843: SMT codegen pre-registers user-defined
//! records as datatypes so z3 can typecheck constructor calls and field reads.
//!
//! Before this fix the verifier emitted SMT that referenced record constructors
//! (`Amount`) as undeclared constants and field accessors as uninterpreted
//! functions with sort `SUninterp("field.<name>")`, so z3 rejected the proof
//! attempt with `unknown constant Amount (Int)` or
//! `Sorts field.value and Int are incompatible` and the whole goal returned
//! `unexpected output`.
//!
//! The fix walks each `IRecord` at the start of `goalsForFile`, emits
//! `DeclDatatype(name, [DatatypeCtor(name, fields)])`, and routes ECall's
//! record-constructor lowering + EMember's field selector through the
//! registered datatype.  The SMT renderer pre-seeds `seenSorts` so the
//! datatype's own sort isn't redeclared via `declare-sort`.
//!
//! Run in CI via native `lyric test --target dotnet`.
@test_module
package Lyric.VerifierRecordsSelfTest

import Std.Core
import Std.Testing
import Lyric.Verifier

func proveOk(src: in String): Bool {
  val summary = proveSource(src)
  // Every goal discharged AND no error-severity diagnostics.
  if summary.results.count == 0 {
    return false
  }
  if summaryHasFailure(summary) {
    return false
  }
  if summaryHasErrorDiag(summary) {
    return false
  }
  true
}

test "record constructor + field read discharges" {
  val src = "@proof_required\n" + "package T1\n" + "pub record Amount { value: Int }\n" +
    "pub func makeAmount(c: Int): Amount\n" +
    "  requires: c > 0\n" +
    "  ensures: result.value == c\n" +
    "{\n" +
    "  return Amount(value = c)\n" +
    "}\n"
  assertTrue(proveOk(src), "Amount(value=c).value == c discharges")
}

test "record with multiple fields discharges" {
  val src = "@proof_required\n" + "package T2\n" + "pub record Point { x: Int; y: Int }\n" +
    "pub func makePoint(a: Int, b: Int): Point\n" +
    "  ensures: result.x == a and result.y == b\n" +
    "{\n" +
    "  return Point(x = a, y = b)\n" +
    "}\n"
  assertTrue(proveOk(src), "Point(x=a, y=b) preserves both coords")
}

test "record field equality through let-binding discharges" {
  val src = "@proof_required\n" + "package T3\n" + "pub record Box { n: Int }\n" + "pub func roundTrip(k: Int): Int\n" +
    "  ensures: result == k\n" +
    "{\n" +
    "  val b = Box(n = k)\n" +
    "  return b.n\n" +
    "}\n"
  assertTrue(proveOk(src), "round-trip through a Box discharges")
}
