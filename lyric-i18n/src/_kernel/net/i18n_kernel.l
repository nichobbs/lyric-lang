/// I18n.Kernel.Net — extern boundary for translation file loading and JSON parsing.
///
/// Bridges Lyric's I18n package to .NET platform libraries:
///   Lyric.I18n.FileLoader — file-system loading and JSON parsing for translation files.
///
/// The translation file format is a JSON object whose top-level keys are BCP 47
/// language tags (e.g. "en", "en-US", "fr-FR").  The value for each key is a flat
/// JSON object mapping translation keys to template strings.
///
/// Example input:
///   {
///     "en":    { "greeting": "Hello, {name}!", "farewell": "Goodbye." },
///     "en-US": { "greeting": "Hey, {name}!" },
///     "fr":    { "greeting": "Bonjour, {name}!", "farewell": "Au revoir." }
///   }
///
/// `parseTranslationsJson` returns a JSON array of three-element arrays:
///   [["en","greeting","Hello, {name}!"],["en","farewell","Goodbye."],...]
///
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

package I18n.Kernel.Net

import Std.Core

// ─── File loading and JSON parsing ───────────────────────────────────────────

@axiom("System.IO and JSON parsing for translation file loading")
extern package Lyric.I18n.FileLoader {
  /// Read the contents of the translations file at `path`.
  /// Returns the raw JSON string on success, or an error message on failure.
  pub func loadFromPath(path: String): Result[String, String]

  /// Parse a translations JSON object into a flat JSON array of
  /// [localeKey, translationKey, value] triples.
  /// Returns the JSON array on success, or an error message on failure.
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
  return Lyric.I18n.FileLoader.loadFromPath(path)
}

/// Parse a translations JSON object into a flat array of [localeKey, key, value] triples.
pub func parseTranslationsJson(json: in String): Result[String, String] {
  return Lyric.I18n.FileLoader.parseTranslationsJson(json)
}

/// Load translations from a file path into a kernel-managed store.
pub func loadStore(path: in String, fallbackLocale: in String): Result[Int, String] {
  return Lyric.I18n.FileLoader.loadStore(path, fallbackLocale)
}

/// Translate `key` for `localeKey` using the kernel store.
pub func translate(storeHandle: in Int, key: in String, localeKey: in String): String {
  return Lyric.I18n.FileLoader.translate(storeHandle, key, localeKey)
}

/// Return a JSON array of locale keys available in the store.
pub func availableLocalesJson(storeHandle: in Int): String {
  return Lyric.I18n.FileLoader.availableLocalesJson(storeHandle)
}

/// Return true iff `key` exists for `localeKey` (or its language-only fallback).
pub func hasKey(storeHandle: in Int, key: in String, localeKey: in String): Bool {
  return Lyric.I18n.FileLoader.hasKey(storeHandle, key, localeKey)
}
