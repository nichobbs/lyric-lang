//! I18n.Kernel.Jvm — JVM extern boundary for translation file loading and JSON parsing.
//!
//! JVM implementation of the same contract as I18n.Kernel.Net.  All operations
//! resolve through a single host helper namespace `lyric.i18n.FileLoader`,
//! which the JVM runtime backs with `java.nio.file.Files` for I/O and the
//! stdlib JSON parser for translation-file decoding.
//!
//! Translation file format and the array-of-triples wire format produced by
//! `parseTranslationsJson` are identical to the .NET kernel — the public
//! `I18n` package consumes either kernel without re-shaping.
//!
//! Only active when compiled with feature = "jvm" (Phase 6).
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package I18n.Kernel.Jvm

import Std.Core

// ─── File loading and JSON parsing ───────────────────────────────────────────

@axiom("java.nio.file.Files + stdlib JSON parser for translation file loading")
extern package lyric.i18n.FileLoader {
  /// Read the contents of the translations file at `path`.
  /// Returns the raw JSON string on success, or an error message on failure.
  pub func loadFromPath(path: String): Result[String, String]

  /// Parse a translations JSON object into a flat JSON array of
  /// [localeKey, translationKey, value] triples.
  pub func parseTranslationsJson(json: String): Result[String, String]

  /// Load translations from `path` into the kernel store and return an opaque
  /// handle.  All subsequent translate/hasKey/availableLocalesJson calls use
  /// this handle to look up values from the loaded store.
  pub func loadStore(path: String, fallbackLocale: String): Result[Int, String]

  /// Look up `key` for `localeKey` (e.g. "en-US") in the store identified by
  /// `storeHandle`.  Falls back to language-only key ("en") and then to
  /// `fallbackLocale`.  Returns the key itself when no translation is found.
  pub func translate(storeHandle: Int, key: String, localeKey: String): String

  /// Return a JSON array of locale keys available in the store, e.g.
  /// `["en","en-US","fr"]`.  Returns `"[]"` for an empty or unknown handle.
  pub func availableLocalesJson(storeHandle: Int): String

  /// Return true iff the store contains `key` for `localeKey` (or its
  /// language-only fallback).
  pub func hasKey(storeHandle: Int, key: String, localeKey: String): Bool
}

// ─── Re-exports with `in` mode ────────────────────────────────────────────────

/// Read the translations file at `path` and return its contents as a JSON string.
pub func loadFromPath(path: in String): Result[String, String] {
  return lyric.i18n.FileLoader.loadFromPath(path)
}

/// Parse a translations JSON object into a flat array of [localeKey, key, value] triples.
pub func parseTranslationsJson(json: in String): Result[String, String] {
  return lyric.i18n.FileLoader.parseTranslationsJson(json)
}

/// Load translations from a file path into a kernel-managed store.
pub func loadStore(path: in String, fallbackLocale: in String): Result[Int, String] {
  return lyric.i18n.FileLoader.loadStore(path, fallbackLocale)
}

/// Translate `key` for `localeKey` using the kernel store.
pub func translate(storeHandle: in Int, key: in String, localeKey: in String): String {
  return lyric.i18n.FileLoader.translate(storeHandle, key, localeKey)
}

/// Return a JSON array of locale keys available in the store.
pub func availableLocalesJson(storeHandle: in Int): String {
  return lyric.i18n.FileLoader.availableLocalesJson(storeHandle)
}

/// Return true iff `key` exists for `localeKey` (or its language-only fallback).
pub func hasKey(storeHandle: in Int, key: in String, localeKey: in String): Bool {
  return lyric.i18n.FileLoader.hasKey(storeHandle, key, localeKey)
}
