/// I18n.Kernel.Net — extern boundary for translation file loading and JSON parsing.
///
/// Bridges Lyric's I18n package to .NET platform libraries:
///   System.IO.I18n — file-system loading and JSON parsing for translation files.
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
extern package System.IO.I18n {
  /// Read the contents of the translations file at `path`.
  /// Returns the raw JSON string on success, or an error message on failure.
  pub func loadFromPath(path: String): Result[String, String]

  /// Parse a translations JSON object into a flat JSON array of
  /// [localeKey, translationKey, value] triples.
  /// Returns the JSON array on success, or an error message on failure.
  pub func parseTranslationsJson(json: String): Result[String, String]
}

// ─── Re-exports with `in` mode ────────────────────────────────────────────────

/// Read the translations file at `path` and return its contents as a JSON string.
pub func loadFromPath(path: in String): Result[String, String] {
  return System.IO.I18n.loadFromPath(path)
}

/// Parse a translations JSON object into a flat array of [localeKey, key, value] triples.
pub func parseTranslationsJson(json: in String): Result[String, String] {
  return System.IO.I18n.parseTranslationsJson(json)
}
