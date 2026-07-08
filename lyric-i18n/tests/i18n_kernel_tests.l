//! tests/i18n_kernel_tests.l — test suite for I18n.Kernel.Net, the
//! standalone handle-based translation-file kernel (docs/03-decision-log.md
//! D-progress-627). Exercises loadStore/translate/hasKey/availableLocalesJson
//! against a real JSON fixture on disk, and parseTranslationsJson directly.
@test_module
package I18n.I18nKernelTests

import Std.Core
import Std.Testing
import Std.File as File
import I18n.Kernel.Net

val fixtureJson: String = "{\"en\":{\"greeting\":\"Hello, {name}!\",\"farewell\":\"Goodbye.\"},\"en-US\":{\"greeting\":\"Hey, {name}!\"},\"fr\":{\"greeting\":\"Bonjour, {name}!\",\"farewell\":\"Au revoir.\"}}"

func withFixtureFile(body: in (String) -> Unit): Unit {
  val path = "i18n_kernel_test_fixture.json"
  val _ = File.writeText(path, fixtureJson)
  body(path)
}

test "loadStore loads a real file and returns a usable handle" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> assertTrue(handle > 0, "handle is a positive Int")
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "translate resolves an exact locale match" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> assertEqual(translate(handle, "greeting", "en-US"), "Hey, {name}!", "en-US exact match")
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "translate falls back to language-only locale" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> assertEqual(translate(handle, "greeting", "en-GB"), "Hello, {name}!", "en-GB falls back to en")
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "translate falls back to the configured fallback locale" {
  withFixtureFile(
    { path ->
      match loadStore(path, "fr") {
        case Ok(handle) -> assertEqual(translate(handle, "farewell", "de"), "Au revoir.", "unknown locale de falls back to fr")
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "translate returns the key itself when no translation is found anywhere" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> assertEqual(translate(handle, "nonexistent", "en"), "nonexistent", "missing key returns itself")
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "hasKey is true for a present key and false for an absent one" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> {
          assertTrue(hasKey(handle, "greeting", "en-US"), "greeting exists for en-US")
          assertTrue(not hasKey(handle, "nonexistent", "en"), "nonexistent key is absent")
        }
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "availableLocalesJson lists every registered locale" {
  withFixtureFile(
    { path ->
      match loadStore(path, "en") {
        case Ok(handle) -> {
          val locales: String = availableLocalesJson(handle)
          assertTrue(locales.contains("\"en\""), "contains en")
          assertTrue(locales.contains("\"en-US\""), "contains en-US")
          assertTrue(locales.contains("\"fr\""), "contains fr")
        }
        case Err(e) -> panic("loadStore failed: " + e)
      }
    }
  )
}

test "loadStore reports an error for a missing file" {
  match loadStore("this_file_definitely_does_not_exist.json", "en") {
    case Ok(_) -> panic("expected an error for a missing file")
    case Err(_) -> assertTrue(true, "correctly reported an error")
  }
}

test "parseTranslationsJson produces a flat array of locale/key/value triples" {
  val result = parseTranslationsJson(fixtureJson)
  match result {
    case Ok(json) -> {
      // Re-bind before calling .contains(): on JVM, calling a String method
      // directly on a match-bound value can erase to java.lang.Object and
      // crash JVM auto-FFI resolution (issue #5423).
      val jsonStr: String = json
      assertTrue(jsonStr.contains("\"en\",\"greeting\",\"Hello, {name}!\""), "contains the en greeting triple")
      assertTrue(jsonStr.contains("\"fr\",\"farewell\",\"Au revoir.\""), "contains the fr farewell triple")
    }
    case Err(e) -> panic("parseTranslationsJson failed: " + e)
  }
}

test "loadFromPath reads the raw file contents" {
  withFixtureFile(
    { path ->
      match loadFromPath(path) {
        case Ok(text) -> {
          // See issue #5423 (JVM match-bound String auto-FFI erasure).
          val textStr: String = text
          assertTrue(textStr.contains("greeting"), "raw file content contains the greeting key")
        }
        case Err(e) -> panic("loadFromPath failed: " + e)
      }
    }
  )
}
