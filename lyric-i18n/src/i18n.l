// I18n — internationalization and localization library for Lyric.
//
// Provides locale-aware translation with variable substitution.
// `TranslationStore` is the public interface; `InProcessTranslationStore` is
// the bundled in-process implementation backed by a mutable `Map`.
//
// Usage:
//
//   import I18n
//   import Std.Collections
//
//   val store = I18n.fromJson(translationsJson)?
//   val locale = I18n.makeLocale("en-US")
//   println(I18n.translateLocale(store, "greeting", locale))
//
//   val vars = newMap()
//   vars.add("name", "Alice")
//   println(I18n.translateWithLocale(store, "greeting", locale, vars))
//
// See docs/03-decision-log.md and lyric-i18n/README.md.

@runtime_checked
package I18n

import Std.Core
import Std.Collections
import Std.Json
import Std.File as File

// ─── Locale type ──────────────────────────────────────────────────────────────

/// A BCP 47 locale identifier split into language and region components.
/// The `region` field is empty for language-only tags such as "en".
@stable(since="0.1")
pub record Locale {
  language: String    // e.g. "en", "fr", "zh"
  region:   String    // e.g. "US", "GB" — may be empty
}

// ─── Error type ───────────────────────────────────────────────────────────────

/// An error returned by a translation store operation.
@stable(since="0.1")
pub record I18nError {
  message: String
  code:    String
}

// ─── TranslationStore interface ───────────────────────────────────────────────

/// A translation store.  Obtain one with `inProcess()`, `fromJson()`, or
/// `loadFromPath()`.
@stable(since="0.1")
pub interface TranslationStore {
  /// Return the translation for `key` in `locale`.
  /// Falls back to the language-only variant, then returns `key` itself when
  /// no translation is found (graceful degradation).
  func translate(key: in String, locale: in Locale): String
    requires: key.length > 0

  /// Return the translation for `key` in `locale` with `{varName}` placeholders
  /// substituted from `vars`.  Missing placeholder keys are left unchanged.
  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String
    requires: key.length > 0

  /// Return all locales for which at least one translation key is registered.
  func availableLocales(): slice[Locale]

  /// Return true if `key` has a translation registered for `locale`.
  func hasKey(key: in String, locale: in Locale): Bool
    requires: key.length > 0
}

// ─── InProcessTranslationStore ────────────────────────────────────────────────

/// In-process translation store backed by a flat `Map[String, String]`.
///
/// Keys are compound: `"<localeKey>|<translationKey>"`, e.g. `"en-US|greeting"`.
/// This avoids nested generic maps, which the bootstrap emitter cannot index
/// reliably in impl blocks.
@stable(since="0.1")
pub record InProcessTranslationStore {
  var translations: Map[String, String]
  var localeKeys:   List[String]
}

impl TranslationStore for InProcessTranslationStore {
  func translate(key: in String, locale: in Locale): String {
    val fullKey = localeKey(locale)
    val compoundFull = fullKey + "|" + key
    val r1 = mapGet(self.translations, compoundFull)
    if isSome(r1) {
      return unwrapOr(r1, key)
    }
    if locale.region.length > 0 {
      val compoundLang = locale.language + "|" + key
      val r2 = mapGet(self.translations, compoundLang)
      if isSome(r2) {
        return unwrapOr(r2, key)
      }
    }
    return key
  }

  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String {
    val template = self.translate(key, locale)
    return substitutePlaceholders(template, vars)
  }

  func availableLocales(): slice[Locale] {
    val result: List[Locale] = newList()
    var i: Int = 0
    while i < self.localeKeys.count {
      result.add(parseLocaleKey(self.localeKeys[i]))
      i = i + 1
    }
    return result.toArray()
  }

  func hasKey(key: in String, locale: in Locale): Bool {
    val fullKey = localeKey(locale)
    val compoundFull = fullKey + "|" + key
    val r1 = mapGet(self.translations, compoundFull)
    if isSome(r1) {
      return true
    }
    if locale.region.length > 0 {
      val compoundLang = locale.language + "|" + key
      val r2 = mapGet(self.translations, compoundLang)
      if isSome(r2) {
        return true
      }
    }
    return false
  }
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Create an empty in-process translation store.
@stable(since="0.1")
pub func inProcess(): InProcessTranslationStore {
  return InProcessTranslationStore(translations = newMap(), localeKeys = newList())
}


/// Parse a translations JSON object and return an in-process store.
///
/// Expected JSON format:
///   { "en": { "key": "value", ... }, "fr": { "key": "valeur", ... }, ... }
@stable(since="0.1")
pub func fromJson(json: in String): Result[InProcessTranslationStore, I18nError] {
  val store = buildStoreFromObject(json)
  return Ok(store)
}

/// Load translations from `path` and return an in-process store.
@stable(since="0.1")
pub func loadFromPath(path: in String): Result[InProcessTranslationStore, I18nError] {
  val readResult = readText(path)
  if isErr(readResult) {
    return Err(I18nError(message = "Failed to read file: " + path, code = "LOAD_ERROR"))
  }
  val json = unwrapResultOr(readResult, "")
  return fromJson(json)
}

// ─── Convenience functions ────────────────────────────────────────────────────

/// Translate `key` using the default locale ("en").
@stable(since="0.1")
pub func translate(store: in TranslationStore, key: in String): String
  requires: key.length > 0
{
  val loc = defaultLocale()
  return store.translate(key, loc)
}

/// Translate `key` using the given `locale`.
@stable(since="0.1")
pub func translateLocale(store: in TranslationStore, key: in String, locale: in Locale): String
  requires: key.length > 0
{
  return store.translate(key, locale)
}

/// Translate `key` with variable substitution using the default locale.
@stable(since="0.1")
pub func translateWith(store: in TranslationStore, key: in String, vars: in Map[String, String]): String
  requires: key.length > 0
{
  val loc = defaultLocale()
  return store.translateWith(key, loc, vars)
}

/// Translate `key` with variable substitution using the given `locale`.
@stable(since="0.1")
pub func translateWithLocale(
  store:  in TranslationStore,
  key:    in String,
  locale: in Locale,
  vars:   in Map[String, String]
): String
  requires: key.length > 0
{
  return store.translateWith(key, locale, vars)
}

/// Parse a BCP 47 tag string into a `Locale`.
/// "en-US" → Locale(language = "en", region = "US")
/// "en"    → Locale(language = "en", region = "")
@stable(since="0.1")
pub func makeLocale(tag: in String): Locale {
  return parseLocaleKey(tag)
}

/// Convert a `Locale` back to its BCP 47 key string.
/// Returns "en-US" when region is non-empty, "en" otherwise.
@stable(since="0.1")
pub func localeKey(locale: in Locale): String {
  if locale.region.length > 0 {
    return locale.language + "-" + locale.region
  } else {
    return locale.language
  }
}

/// Return the default locale ("en").
@stable(since="0.1")
pub func defaultLocale(): Locale {
  return parseLocaleKey("en")
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Parse a BCP 47 locale key string into a Locale.
// "en-US" → Locale(language = "en", region = "US"); "en" → Locale(language = "en", region = "")
func parseLocaleKey(key: in String): Locale {
  var i: Int = 0
  while i < key.length and key.substring(i, 1) != "-" {
    i = i + 1
  }
  if i >= key.length {
    return Locale(language = key, region = "")
  } else {
    val lang   = key.substring(0, i)
    val region = key.substring(i + 1, key.length - i - 1)
    return Locale(language = lang, region = region)
  }
}

// Maximum output length for substitutePlaceholders (1 MiB).
// Prevents unbounded output when a substitution value is very large.
val maxSubstOutputLength: Int = 1048576

// Substitute {varName} placeholders in `template` using values from `vars`.
// Unknown placeholder keys are left unchanged in the output.
// Substitution values are inserted verbatim; they are NOT re-scanned for
// further placeholders.  Returns `template` unchanged if the expanded output
// would exceed `maxSubstOutputLength` characters.
func substitutePlaceholders(template: in String, vars: in Map[String, String]): String {
  var buf: String = ""
  var i:   Int    = 0
  while i < template.length {
    val ch = template.substring(i, 1)
    if ch == "{" {
      // Scan forward to find the closing '}'.
      var j: Int = i + 1
      while j < template.length and template.substring(j, 1) != "}" {
        j = j + 1
      }
      if j >= template.length {
        // No closing brace found; emit everything from i and stop.
        buf = buf + template.substring(i, template.length - i)
        i   = template.length
      } else {
        val varName = template.substring(i + 1, j - i - 1)
        val getResult = mapGet(vars, varName)
        if isSome(getResult) {
          val value = unwrapOr(getResult, "")
          if buf.length + value.length > maxSubstOutputLength {
            return template
          }
          buf = buf + value
        } else {
          buf = buf + "{" + varName + "}"
        }
        i = j + 1
      }
    } else {
      buf = buf + ch
      i   = i + 1
    }
  }
  return buf
}

// Build an InProcessTranslationStore by directly parsing the translations JSON object.
// Expected format: { "en": { "key": "value", ... }, "fr": { ... }, ... }
// Keys in the flat map are compound: "<localeKey>|<translationKey>".
func buildStoreFromObject(json: in String): InProcessTranslationStore {
  var m:    Map[String, String] = newMap()
  var keys: List[String] = newList()
  val doc     = parseJson(json)
  val root    = rootElement(doc)
  if valueKind(root) != 1 {
    return InProcessTranslationStore(translations = m, localeKeys = keys)
  }
  var outerEn = enumerateObject(root)
  while objectMoveNext(outerEn) {
    val localeProp = objectCurrent(outerEn)
    val lk = propertyName(localeProp)
    val localeVal = propertyValue(localeProp)
    if valueKind(localeVal) == 1 {
      var innerEn = enumerateObject(localeVal)
      while objectMoveNext(innerEn) {
        val tkeyProp = objectCurrent(innerEn)
        val tkey = propertyName(tkeyProp)
        val tval = getString(propertyValue(tkeyProp))
        val compound = lk + "|" + tkey
        if not m.containsKey(compound) {
          m.add(compound, tval)
        }
      }
      // Track locale keys (without duplicates).
      var found: Bool = false
      var ki: Int = 0
      while ki < keys.count {
        if keys[ki] == lk {
          found = true
        }
        ki = ki + 1
      }
      if not found {
        keys.add(lk)
      }
    }
  }
  return InProcessTranslationStore(translations = m, localeKeys = keys)
}
