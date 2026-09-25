//! A union case constructed through its imported union's name
//! (`Std.Errors.IOError.InvalidPath(...)`, `IOError.InvalidPath(...)`).
//!
//! On the JVM the imported-type seed puts imported type names into the
//! extern-type table, so these calls were routed to the auto-FFI static-call
//! path and failed with J008 "class 'Std.Errors.IOError' not found in JDK
//! jmods".  A library aspect building its own union's case
//! (`Lambda.LambdaError.TimeoutError(...)` in `DeadlineGuard`) hit this in
//! every JVM consumer.
@test_module
package ImportedUnionCaseCtorSelfTest

import Std.Core
import Std.Errors
import Std.Testing

func pathOf(e: in IOError): String {
  match e {
    case InvalidPath(p, _) -> p
    case _ -> "other"
  }
}

test "a case built through the package-qualified union name" {
  val e: IOError = Std.Errors.IOError.InvalidPath(path = "p", reason = "r")
  assertEqual(pathOf(e), "p", "InvalidPath carries its path")
}

test "a case built through the imported union's simple name" {
  val e: IOError = IOError.InvalidPath(path = "q", reason = "s")
  assertEqual(pathOf(e), "q", "InvalidPath carries its path")
}
