//! tests/storage_aspect_weaving_tests.l — runtime weaving test for the
//! Storage.Aspects.ValidateKey DoS fix (#5477 / D-progress-641).
//!
//! ValidateKey previously carried a `requires: args.key != ""` clause, which
//! elaborates into a runtime precondition assert (D118) that PANICKED the
//! process on an empty (caller-/client-supplied) storage key — the same DoS
//! class fixed for `lyric-web`/`lyric-cache`/`lyric-mq`. The fix removed the
//! clause; the aspect body now fails closed with a graceful
//! `Err(StorageError(code = "INVALID_KEY"))` instead. This test pins that an
//! empty key never crashes the *woven* handler and a valid key still reaches
//! it — unlike `storage_tests.l`'s `isSafeKey("")` coverage, which only
//! exercises the standalone helper, not the woven `around(call)` advice
//! itself. Mirrors `lyric-cache/tests/cache_aspect_weaving_tests.l` and
//! `lyric-mq/tests/mq_aspect_weaving_tests.l`.
//!
//! `lyric-storage`'s suite also runs under `--target jvm` in CI
//! (`.github/workflows/ci.yml`, "lyric-storage suite on JVM"), and B'-mode
//! `around(call)` aspect weaving is a known, pre-existing JVM backend gap:
//! any cross-package `aspect X from <Template> { ... }` instantiation of a
//! `call`-context template throws `NoSuchMethodError` on the synthesised
//! `__LyricBModeCallContext` record at runtime — confirmed independently in
//! `lyric-auth`, `lyric-web`, `lyric-feature-flags`, and `lyric-ws` (see
//! docs/03-decision-log.md). Those libraries' JVM legs aren't hard-gated in
//! CI, so they can carry a target-agnostic weaving test that simply fails on
//! JVM; `lyric-storage`'s is (band J6, #1444/#2669), so this file cannot do
//! the same without breaking that step.
//!
//! The aspect instantiation, its target handler and the tests that exercise
//! them are all gated to `dotnet` (`@cfg(feature = "dotnet")`); on `jvm` the
//! tests are absent from the run, so the hard-gated `--target jvm` step stays
//! green without touching the known-broken weaver codegen. Once the JVM
//! B'-mode `call`-context gap is fixed, drop the gates and let the real aspect
//! run on both targets. `Storage.isSafeKey` itself, which the aspect applies, is
//! covered on both targets by the storage suite.
@test_module
package Storage.StorageAspectWeavingTests

import Std.Core
import Std.Testing
import Storage
import Storage.Aspects

@cfg(feature = "dotnet")
aspect KeyGuard from Storage.Aspects.ValidateKey {
  matches: name like "storageKeyGuarded*"
}

@cfg(feature = "dotnet")
pub func storageKeyGuardedHandler(key: in String): Result[String, StorageError] {
  return Ok("stored:" + key)
}

@cfg(feature = "dotnet")
test "ValidateKey aspect: an empty key is rejected with INVALID_KEY (was a panic)" {
  match storageKeyGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "empty key must be rejected, not reach the handler")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "empty key rejected with INVALID_KEY")
  }
}

@cfg(feature = "dotnet")
test "ValidateKey aspect: a valid key passes through to the handler" {
  match storageKeyGuardedHandler("uploads/photo.jpg") {
    case Ok(v) -> assertEqual(v, "stored:uploads/photo.jpg", "valid key reaches the handler")
    case Err(_) -> assertTrue(false, "valid key must not be rejected")
  }
}

// ValidateKey used to check only empty keys, a leading '/' and "..", and had
// an env-settable `allowDots` switch that disabled even that; it now applies
// `Storage.isSafeKey` in full (#7242).
@cfg(feature = "dotnet")
test "ValidateKey aspect: every key isSafeKey rejects is rejected before the handler" {
  val bad = ["../etc/passwd", "%2e%2e/etc", "%252e%252e/etc", "a//b", "a/./b", "dir/", "x.meta.json", "a\u{0001}b"]
  for k in bad {
    match storageKeyGuardedHandler(k) {
      case Ok(_) -> assertTrue(false, "key must be rejected: " + k)
      case Err(e) -> assertEqual(e.code, "INVALID_KEY", "rejected with INVALID_KEY: " + k)
    }
  }
}
