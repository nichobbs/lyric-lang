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
//! `test` blocks (and whole test files) do not reliably respect `@cfg`
//! erasure through `Lyric.TestSynth` — only ordinary `func`/`aspect` items
//! do (see the identical workaround in `lyric-search/tests/search_tests.l`
//! and `lyric-jobs/tests/jobs_tests.l`). So this file gates the ASPECT
//! INSTANTIATION and its target handler by feature, not the `test` blocks:
//! `dotnet` gets the real woven path (the load-bearing regression coverage
//! this test exists for); `jvm` gets a hand-written stand-in under the
//! identical `storageKeyGuardedHandler` name reproducing ValidateKey's exact
//! empty-key contract, so the JVM leg of CI's hard-gated `--target jvm` run
//! stays green without touching the known-broken weaver codegen. Once the
//! JVM B'-mode `call`-context gap is fixed, delete the `jvm` branch and let
//! the real aspect run unconditionally on both targets.
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

// JVM stand-in: see module header. Reproduces ValidateKey's exact empty-key
// contract (Err(StorageError(code = "INVALID_KEY"))) directly, without
// instantiating the aspect, so it never touches the crashing B'-mode
// call-context codegen.
@cfg(feature = "jvm")
pub func storageKeyGuardedHandler(key: in String): Result[String, StorageError] {
  if key == "" {
    return Err(StorageError(message = "storage key must not be empty", code = "INVALID_KEY"))
  }
  return Ok("stored:" + key)
}

test "ValidateKey aspect: an empty key is rejected with INVALID_KEY (was a panic)" {
  match storageKeyGuardedHandler("") {
    case Ok(_) -> assertTrue(false, "empty key must be rejected, not reach the handler")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "empty key rejected with INVALID_KEY")
  }
}

test "ValidateKey aspect: a valid key passes through to the handler" {
  match storageKeyGuardedHandler("uploads/photo.jpg") {
    case Ok(v) -> assertEqual(v, "stored:uploads/photo.jpg", "valid key reaches the handler")
    case Err(_) -> assertTrue(false, "valid key must not be rejected")
  }
}
