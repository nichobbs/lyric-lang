//! I18n.Kernel.Net — translation file loading and JSON parsing for I18n.
//!
//! Backed by plain Lyric (`Std.File` + `Std.Json` + `Std.Collections`), not
//! an extern boundary: reading a text file and parsing/looking up a JSON
//! object needs no BCL/JDK object reference, so this package is pure Lyric
//! and behaves identically on every compilation target. It used to be an
//! `extern package Lyric.I18n.FileLoader` declaration; `extern package`
//! never resolves to a real binding on either backend (issue #5324), so
//! every function here was silently unreachable — never noticed because
//! `I18n`'s own public package (`i18n.l`) never imported this kernel at all
//! (it reimplements the same translation-loading logic directly against
//! `Std.File`/`Std.Json`). This kernel now provides the same handle-based
//! contract as a real, working, standalone alternative entry point for
//! consumers that want it, mirroring `Flags.Registry`'s "eliminate the
//! extern boundary entirely" fix (`docs/03-decision-log.md` D-progress-627).
//!
//! Store state is two parallel `Map[Int, ...]` tables (translations,
//! fallback locale) keyed by handle, rather than a single `Map[Int,
//! SomeRecord]` whose record wraps a `Map` field — a record-with-a-Map-field
//! read back out through a `match`-bound local produced a JVM-only
//! `ClassCastException` (the record itself getting cast as if it were the
//! `java.util.HashMap` backing its field) — see issue #5422 for the
//! standalone repro. The flattened two-table shape sidesteps the bug
//! entirely and is no less clear.
//!
//! The translation file format is a JSON object whose top-level keys are BCP
//! 47 language tags (e.g. "en", "en-US", "fr-FR"). The value for each key is
//! a flat JSON object mapping translation keys to template strings.
//!
//! Example input:
//!   {
//!     "en":    { "greeting": "Hello, {name}!", "farewell": "Goodbye." },
//!     "en-US": { "greeting": "Hey, {name}!" },
//!     "fr":    { "greeting": "Bonjour, {name}!", "farewell": "Au revoir." }
//!   }
//!
//! `parseTranslationsJson` returns a JSON array of three-element arrays:
//!   [["en","greeting","Hello, {name}!"],["en","farewell","Goodbye."],...]
package I18n.Kernel.Net

import Std.Core
import Std.Collections
import Std.Json
import Std.File as File

record I18nKernelState {
  var translationsByHandle: Map[Int, Map[String, Map[String, String]]]
  var fallbackLocaleByHandle: Map[Int, String]
  var nextHandle: Int
}

func newKernelState(): I18nKernelState {
  return I18nKernelState(translationsByHandle = newMap(), fallbackLocaleByHandle = newMap(), nextHandle = 1)
}

val globalState: I18nKernelState = newKernelState()

func languageOnly(localeKey: in String): String {
  val idx = localeKey.indexOf("-")
  if idx >= 0 {
    localeKey.substring(0, idx)
  } else {
    localeKey
  }
}

func lookupTranslation(
  translations: in Map[String, Map[String, String]],
  fallbackLocale: in String,
  key: in String,
  localeKey: in String,
): Option[String] {
  match mapGet(translations, localeKey) {
    case Some(bucket) -> match mapGet(bucket, key) { case Some(v) -> return Some(value = v); case None -> {  } }
    case None -> {
    }
  }
  val lang = languageOnly(localeKey)
  if lang != localeKey {
    match mapGet(translations, lang) {
      case Some(bucket) -> match mapGet(bucket, key) { case Some(v) -> return Some(value = v); case None -> {  } }
      case None -> {
      }
    }
  }
  match mapGet(translations, fallbackLocale) {
    case Some(bucket) -> mapGet(bucket, key)
    case None -> None
  }
}

func parseTranslationsObject(json: in String): Map[String, Map[String, String]] {
  val doc = parseJson(json)
  val root = rootElement(doc)
  val result: Map[String, Map[String, String]] = newMap()
  var localeCursor = enumerateObject(root)
  while objectMoveNext(localeCursor) {
    val localeProp = objectCurrent(localeCursor)
    val localeKey = propertyName(localeProp)
    val bucket: Map[String, String] = newMap()
    var keyCursor = enumerateObject(propertyValue(localeProp))
    while objectMoveNext(keyCursor) {
      val keyProp = objectCurrent(keyCursor)
      bucket[propertyName(keyProp)] = getString(propertyValue(keyProp))
    }
    result[localeKey] = bucket
  }
  disposeJson(doc)
  return result
}

/// Read the contents of the translations file at `path`.
/// Returns the raw JSON string on success, or an error message on failure.
pub func loadFromPath(path: in String): Result[String, String] {
  match File.readText(path) {
    case Ok(text) -> Ok(value = text)
    case Err(e) -> Err(error = "Failed to read file: " + path)
  }
}

/// Parse a translations JSON object into a flat JSON array of
/// [localeKey, translationKey, value] triples.
pub func parseTranslationsJson(json: in String): Result[String, String] {
  val translations = parseTranslationsObject(json)
  var sb = "["
  var first = true
  val locales = mapKeys(translations)
  var li = 0
  while li < locales.count {
    val localeKey = locales[li]
    val bucket = mapGet(translations, localeKey)
    match bucket {
      case Some(b) -> {
        val bucket2: Map[String, String] = b
        val keys = mapKeys(bucket2)
        var ki = 0
        while ki < keys.count {
          val k = keys[ki]
          val v = mapGet(bucket2, k)
          match v {
            case Some(value) -> {
              if not first {
                sb = sb + ","
              }
              first = false
              sb = sb + "[" + encodeString(localeKey) + "," + encodeString(k) + "," + encodeString(value) + "]"
            }
            case None -> {
            }
          }
          ki = ki + 1
        }
      }
      case None -> {
      }
    }
    li = li + 1
  }
  sb = sb + "]"
  return Ok(value = sb)
}

/// Load translations from `path` into the kernel store and return an opaque
/// handle. All subsequent translate/hasKey/availableLocalesJson calls use
/// this handle to look up values from the loaded store.
pub func loadStore(path: in String, fallbackLocale: in String): Result[Int, String] {
  match File.readText(path) {
    case Ok(text) -> {
      val translations = parseTranslationsObject(text)
      val handle = globalState.nextHandle
      globalState.translationsByHandle[handle] = translations
      globalState.fallbackLocaleByHandle[handle] = fallbackLocale
      globalState.nextHandle = handle + 1
      return Ok(value = handle)
    }
    case Err(e) -> return Err(error = "Failed to read file: " + path)
  }
}

/// Look up `key` for `localeKey` (e.g. "en-US") in the store identified by
/// `storeHandle`. Falls back to language-only key ("en") and then to
/// `fallbackLocale`. Returns the key itself when no translation is found.
pub func translate(storeHandle: in Int, key: in String, localeKey: in String): String {
  match mapGet(globalState.translationsByHandle, storeHandle) {
    case Some(translations) -> {
      val fallback = match mapGet(globalState.fallbackLocaleByHandle, storeHandle) { case Some(f) -> f; case None -> "" }
      match lookupTranslation(translations, fallback, key, localeKey) {
        case Some(v) -> v
        case None -> key
      }
    }
    case None -> key
  }
}

/// Return a JSON array of locale keys available in the store, e.g.
/// `["en","en-US","fr"]`. Returns `"[]"` for an empty or unknown handle.
pub func availableLocalesJson(storeHandle: in Int): String {
  match mapGet(globalState.translationsByHandle, storeHandle) {
    case Some(translations) -> {
      val translationsMap: Map[String, Map[String, String]] = translations
      val locales = mapKeys(translationsMap)
      var sb = "["
      var i = 0
      while i < locales.count {
        if i > 0 {
          sb = sb + ","
        }
        sb = sb + encodeString(locales[i])
        i = i + 1
      }
      sb + "]"
    }
    case None -> "[]"
  }
}

/// Return true iff the store contains `key` for `localeKey` (or its
/// language-only fallback).
pub func hasKey(storeHandle: in Int, key: in String, localeKey: in String): Bool {
  match mapGet(globalState.translationsByHandle, storeHandle) {
    case Some(translations) -> {
      val fallback = match mapGet(globalState.fallbackLocaleByHandle, storeHandle) { case Some(f) -> f; case None -> "" }
      match lookupTranslation(translations, fallback, key, localeKey) {
        case Some(_) -> true
        case None -> false
      }
    }
    case None -> false
  }
}
