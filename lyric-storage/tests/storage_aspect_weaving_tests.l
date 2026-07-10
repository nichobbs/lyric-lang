//! tests/storage_aspect_weaving_tests.l — runtime weaving tests for the
//! Storage.Aspects.ValidateKey template.
//!
//! ValidateKey previously carried a `requires: args.key != ""` clause, which
//! elaborates into a runtime precondition assert (D118) that PANICKED the
//! process on an empty (client-controlled) storage key — the same DoS class
//! fixed for `lyric-web`. The fix removed the clause and the aspect body now
//! fails closed on the empty case with a graceful `Err(INVALID_KEY)`. These
//! tests pin that behaviour, plus the ordinary safe-key and traversal paths.
@test_module
package Storage.StorageAspectWeavingTests

import Std.Core
import Std.Testing
import Storage
import Storage.Aspects

// Guard any handler named `keyGuarded*` with the ValidateKey template.
aspect KeyGuard from Storage.Aspects.ValidateKey {
  matches: name like "keyGuarded*"
  config {
    enabled: Bool = true
  }
}

pub func keyGuardedHandler(key: in String): Result[String, StorageError] {
  return Ok("stored:" + key)
}

test "ValidateKey: an empty key returns INVALID_KEY without crashing (was a panic)" {
  match keyGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "an empty key must be rejected before the handler runs")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "empty key short-circuits with INVALID_KEY, not a crash")
  }
}

test "ValidateKey: a safe key reaches the handler" {
  match keyGuardedHandler("photos/cat.jpg") {
    case Ok(v) -> assertEqual(v, "stored:photos/cat.jpg", "a safe key must reach the handler")
    case Err(_) -> assertTrue(false, "a safe key must not be rejected")
  }
}

test "ValidateKey: a path-traversal key is denied with INVALID_KEY" {
  match keyGuardedHandler("../etc/passwd") {
    case Ok(_) -> assertTrue(false, "a traversal key must be rejected before the handler runs")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "traversal key short-circuits with INVALID_KEY")
  }
}
