//! init_self_test.l — exercises the pure helper of Lyric.Init
//! (derivePackageName) via the native `@test_module` runner.
//!
//! The filesystem-driving part of Lyric.Init (runInit: createRecursive,
//! writeText) is integration-tested by the "lyric init e2e" CI step against the
//! real binary — it can't run through `lyric test` (host-backed stdlib at
//! runtime, #2001).  derivePackageName is pure and gets direct unit coverage of
//! its boundary cases here.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/init_self_test.l
@test_module
package Lyric.InitSelfTest

import Std.Core
import Std.Testing
import Lyric.Init as Init

test "derivePackageName: lowercase basename is capitalised" {
  match Init.derivePackageName("demo") {
    case Ok(n) -> assertEqual(n, "Demo", "demo -> Demo")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + e)
  }
}

test "derivePackageName: already-UpperCamelCase is preserved" {
  match Init.derivePackageName("MyApp") {
    case Ok(n) -> assertEqual(n, "MyApp", "MyApp unchanged")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + e)
  }
}

test "derivePackageName: only the leading letter is touched" {
  match Init.derivePackageName("webServer") {
    case Ok(n) -> assertEqual(n, "WebServer", "internal capitals preserved")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + e)
  }
}

test "derivePackageName: a trailing digit is allowed" {
  match Init.derivePackageName("app2") {
    case Ok(n) -> assertEqual(n, "App2", "app2 -> App2")
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + e)
  }
}

test "derivePackageName: empty string is rejected" {
  match Init.derivePackageName("") {
    case Ok(n) -> assertTrue(false, "expected Err, got Ok: " + n)
    case Err(_) -> assertTrue(true, "empty rejected")
  }
}

test "derivePackageName: hyphenated name is rejected" {
  match Init.derivePackageName("bad-name") {
    case Ok(n) -> assertTrue(false, "expected Err, got Ok: " + n)
    case Err(_) -> assertTrue(true, "hyphen rejected")
  }
}

test "derivePackageName: digit-leading name is rejected" {
  match Init.derivePackageName("3d") {
    case Ok(n) -> assertTrue(false, "expected Err, got Ok: " + n)
    case Err(_) -> assertTrue(true, "digit-leading rejected")
  }
}

test "derivePackageName: dotted name is rejected" {
  match Init.derivePackageName("my.app") {
    case Ok(n) -> assertTrue(false, "expected Err, got Ok: " + n)
    case Err(_) -> assertTrue(true, "dot rejected")
  }
}

test "derivePackageName: underscore is rejected" {
  match Init.derivePackageName("my_app") {
    case Ok(n) -> assertTrue(false, "expected Err, got Ok: " + n)
    case Err(_) -> assertTrue(true, "underscore rejected")
  }
}
