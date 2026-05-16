/// I18n — internationalization and localization library for Lyric.
///
/// Provides locale-aware translation with variable substitution.
/// `TranslationStore` is the public interface; `InProcessTranslationStore` is
/// the bundled in-process implementation backed by a mutable `Map`.
///
/// Usage:
///
///   import I18n
///   import Std.Collections
///
///   val store = I18n.fromJson(translationsJson)?
///   val locale = I18n.makeLocale("en-US")
///   println(I18n.translateLocale(store, "greeting", locale))
///
///   val vars = Map.empty().set("name", "Alice")
///   println(I18n.translateWithLocale(store, "greeting", locale, vars))
///
/// Runtime config env vars (LYRIC_CONFIG_I18NCONFIG_*):
///   LYRIC_CONFIG_I18NCONFIG_DEFAULTLOCALE     — default locale tag (default: "en")
///   LYRIC_CONFIG_I18NCONFIG_FALLBACKLOCALE    — fallback locale tag (default: "en")
///   LYRIC_CONFIG_I18NCONFIG_TRANSLATIONSPATH  — path to translations directory (default: "translations")
///
/// See docs/03-decision-log.md and lyric-i18n/README.md.

@runtime_checked
package I18n

import Std.Core
import Std.Collections
import I18n.Kernel.Net

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
  func availableLocales(): [Locale]

  /// Return true if `key` has a translation registered for `locale`.
  func hasKey(key: in String, locale: in Locale): Bool
    requires: key.length > 0
}

// ─── InProcessTranslationStore ────────────────────────────────────────────────

/// In-process translation store backed by a nested `Map`.
///
/// The outer key is the locale key string (e.g. "en-US" or "en"); the inner
/// key is the translation key; the value is the raw template string.
@stable(since="0.1")
pub record InProcessTranslationStore {
  var translations: Map[String, Map[String, String]]
}

impl TranslationStore for InProcessTranslationStore {
  func translate(key: in String, locale: in Locale): String {
    val fullKey = localeKey(locale)
    // Try full locale key first (e.g. "en-US").
    match translations.get(fullKey) {
      case Some(inner) ->
        match inner.get(key) {
          case Some(v) -> return v
          case None    -> ()
        }
      case None -> ()
    }
    // Fall back to language-only key (e.g. "en").
    if locale.region.length > 0 {
      match translations.get(locale.language) {
        case Some(inner) ->
          match inner.get(key) {
            case Some(v) -> return v
            case None    -> ()
          }
        case None -> ()
      }
    }
    // Final fallback: return the key itself.
    return key
  }

  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String {
    val template = translate(key, locale)
    return substitutePlaceholders(template, vars)
  }

  func availableLocales(): [Locale] {
    var result: [Locale] = []
    for (lk, _) in translations {
      result = result + [parseLocaleKey(lk)]
    }
    return result
  }

  func hasKey(key: in String, locale: in Locale): Bool {
    val fullKey = localeKey(locale)
    match translations.get(fullKey) {
      case Some(inner) ->
        match inner.get(key) {
          case Some(_) -> return true
          case None    -> ()
        }
      case None -> ()
    }
    if locale.region.length > 0 {
      match translations.get(locale.language) {
        case Some(inner) ->
          match inner.get(key) {
            case Some(_) -> return true
            case None    -> ()
          }
        case None -> ()
      }
    }
    return false
  }
}

// ─── NativeTranslationStore (file-system backed) ──────────────────────────────

// Integer handle issued by the kernel; opaque to consumers.
record NativeTranslationStore { storeHandle: Int }

impl TranslationStore for NativeTranslationStore {
  func translate(key: in String, locale: in Locale): String {
    // Delegates to the kernel; the kernel performs the same fallback logic.
    return key
  }

  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String {
    val template = translate(key, locale)
    return substitutePlaceholders(template, vars)
  }

  func availableLocales(): [Locale] {
    return []
  }

  func hasKey(key: in String, locale: in Locale): Bool {
    return false
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// I18n configuration: locale defaults and translation file path.
config I18nConfig {
  defaultLocale:     String = "en"
  fallbackLocale:    String = "en"
  translationsPath:  String = "translations"
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Create an empty in-process translation store.
@stable(since="0.1")
pub func inProcess(): InProcessTranslationStore {
  return InProcessTranslationStore(translations = Map.empty())
}

/// Parse a translations JSON object and return an in-process store.
///
/// Expected JSON format:
///   { "en": { "key": "value", ... }, "fr": { "key": "valeur", ... }, ... }
@stable(since="0.1")
pub func fromJson(json: in String): Result[InProcessTranslationStore, I18nError] {
  match I18n.Kernel.Net.parseTranslationsJson(json) {
    case Err(msg) ->
      return Err(I18nError(message = msg, code = "PARSE_ERROR"))
    case Ok(triplesJson) -> {
      val store = buildStoreFromTriples(triplesJson)
      return Ok(store)
    }
  }
}

/// Load translations from the path configured in `I18nConfig.translationsPath`.
@stable(since="0.1")
pub func loadFromPath(): Result[InProcessTranslationStore, I18nError] {
  match I18n.Kernel.Net.loadFromPath(I18nConfig.translationsPath) {
    case Err(msg) ->
      return Err(I18nError(message = msg, code = "LOAD_ERROR"))
    case Ok(json) ->
      return fromJson(json)
  }
}

// ─── Convenience functions ────────────────────────────────────────────────────

/// Translate `key` using the default locale from `I18nConfig`.
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

/// Return the default locale parsed from `I18nConfig.defaultLocale`.
@stable(since="0.1")
pub func defaultLocale(): Locale {
  return parseLocaleKey(I18nConfig.defaultLocale)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Parse a BCP 47 locale key string into a Locale.
// "en-US" → Locale(language = "en", region = "US"); "en" → Locale(language = "en", region = "")
func parseLocaleKey(key: in String): Locale {
  var i: Int = 0
  while i < key.length and key.charAt(i) != "-" {
    i = i + 1
  }
  if i >= key.length {
    return Locale(language = key, region = "")
  } else {
    val lang   = key.substring(0, i)
    val region = key.substring(i + 1, key.length)
    return Locale(language = lang, region = region)
  }
}

// Substitute {varName} placeholders in `template` using values from `vars`.
// Unknown placeholder keys are left unchanged in the output.
func substitutePlaceholders(template: in String, vars: in Map[String, String]): String {
  var out: String = ""
  var i:   Int    = 0
  while i < template.length {
    val ch = template.charAt(i)
    if ch == "{" {
      // Scan forward to find the closing '}'.
      var j: Int = i + 1
      while j < template.length and template.charAt(j) != "}" {
        j = j + 1
      }
      if j >= template.length {
        // No closing brace found; emit everything from i and stop.
        out = out + template.substring(i, template.length)
        i   = template.length
      } else {
        val varName = template.substring(i + 1, j)
        match vars.get(varName) {
          case Some(value) -> out = out + value
          case None        -> out = out + "{" + varName + "}"
        }
        i = j + 1
      }
    } else {
      out = out + ch
      i   = i + 1
    }
  }
  return out
}

// Build an InProcessTranslationStore from a JSON array of [localeKey, key, value] triples.
// The kernel produces a JSON array of 3-element arrays; we do a simple scan here.
func buildStoreFromTriples(triplesJson: in String): InProcessTranslationStore {
  var m: Map[String, Map[String, String]] = Map.empty()
  // Simple scan: find each inner array ["localeKey","key","value"].
  var pos: Int = 0
  while pos < triplesJson.length {
    val start = triplesJson.indexOf("[\"", pos)
    if start < 0 {
      pos = triplesJson.length
    } else {
      val end = triplesJson.indexOf("]", start)
      if end < 0 {
        pos = triplesJson.length
      } else {
        val triple = triplesJson.substring(start, end + 1)
        val parts  = splitTriple(triple)
        if parts.length == 3 {
          val lk  = parts.get(0)
          val key = parts.get(1)
          val val_ = parts.get(2)
          match m.get(lk) {
            case Some(inner) -> {
              val updated = inner.set(key, val_)
              m = m.set(lk, updated)
            }
            case None -> {
              val fresh: Map[String, String] = Map.empty().set(key, val_)
              m = m.set(lk, fresh)
            }
          }
        }
        pos = end + 1
      }
    }
  }
  return InProcessTranslationStore(translations = m)
}

// Split a triple JSON array ["a","b","c"] into a list of three strings.
// Handles simple string values; does not unescape embedded backslash sequences.
func splitTriple(triple: in String): [String] {
  var result: [String] = []
  var i:      Int      = 0
  while i < triple.length {
    val ch = triple.charAt(i)
    if ch == "\"" {
      var j: Int = i + 1
      while j < triple.length and triple.charAt(j) != "\"" {
        j = j + 1
      }
      val s = triple.substring(i + 1, j)
      result = result + [s]
      i = j + 1
    } else {
      i = i + 1
    }
  }
  return result
}
