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
import Std.Json
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
    return I18n.Kernel.Net.translate(storeHandle, key, localeKey(locale))
  }

  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String {
    val template = translate(key, locale)
    return substitutePlaceholders(template, vars)
  }

  func availableLocales(): [Locale] {
    val json = I18n.Kernel.Net.availableLocalesJson(storeHandle)
    return parseLocaleArray(json)
  }

  func hasKey(key: in String, locale: in Locale): Bool {
    return I18n.Kernel.Net.hasKey(storeHandle, key, localeKey(locale))
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
/// Returns an `InProcessTranslationStore` backed by a parsed in-memory map.
@stable(since="0.1")
pub func loadFromPath(): Result[InProcessTranslationStore, I18nError] {
  match I18n.Kernel.Net.loadFromPath(I18nConfig.translationsPath) {
    case Err(msg) ->
      return Err(I18nError(message = msg, code = "LOAD_ERROR"))
    case Ok(json) ->
      return fromJson(json)
  }
}

/// Load translations from the path and return a kernel-backed `NativeTranslationStore`.
/// Prefer `loadFromPath` for most uses; use `loadNative` when the translation
/// file is large enough that an in-memory copy is undesirable.
@stable(since="0.1")
pub func loadNative(): Result[NativeTranslationStore, I18nError] {
  match I18n.Kernel.Net.loadStore(I18nConfig.translationsPath, I18nConfig.fallbackLocale) {
    case Ok(handle) -> Ok(NativeTranslationStore(storeHandle = handle))
    case Err(msg)   -> Err(I18nError(message = msg, code = "LOAD_ERROR"))
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

// Parse a JSON array of locale-key strings (from availableLocalesJson) into [Locale].
func parseLocaleArray(json: in String): [Locale] {
  var result: [Locale] = []
  val doc  = Std.Json.parseJson(json)
  val root = Std.Json.rootElement(doc)
  if Std.Json.valueKind(root) != 2 { return result }
  var en = Std.Json.enumerateArray(root)
  while Std.Json.arrayMoveNext(en) {
    val elem = Std.Json.arrayCurrent(en)
    if Std.Json.valueKind(elem) == 3 {
      result = result + [parseLocaleKey(Std.Json.getString(elem))]
    }
  }
  return result
}

// Parse a BCP 47 locale key string into a Locale.
// "en-US" → Locale(language = "en", region = "US"); "en" → Locale(language = "en", region = "")
func parseLocaleKey(key: in String): Locale {
  var i: Int = 0
  while i < key.length and key.charAt(i).toString() != "-" {
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
    val ch = template.charAt(i).toString()
    if ch == "{" {
      // Scan forward to find the closing '}'.
      var j: Int = i + 1
      while j < template.length and template.charAt(j).toString() != "}" {
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
// The kernel produces a JSON array of 3-element arrays; parsed via Std.Json.
func buildStoreFromTriples(triplesJson: in String): InProcessTranslationStore {
  var m: Map[String, Map[String, String]] = Map.empty()
  val doc    = Std.Json.parseJson(triplesJson)
  val root   = Std.Json.rootElement(doc)
  var outerEn = Std.Json.enumerateArray(root)
  while Std.Json.arrayMoveNext(outerEn) {
    val triple  = Std.Json.arrayCurrent(outerEn)
    var innerEn = Std.Json.enumerateArray(triple)
    var parts: [String] = []
    while Std.Json.arrayMoveNext(innerEn) {
      val elem = Std.Json.arrayCurrent(innerEn)
      parts = parts + [Std.Json.getString(elem)]
    }
    if parts.length == 3 {
      val lk  = parts[0]
      val key = parts[1]
      val value = parts[2]
      match m.get(lk) {
        case Some(inner) -> m = m.set(lk, inner.set(key, value))
        case None        -> m = m.set(lk, Map.empty().set(key, value))
      }
    }
  }
  return InProcessTranslationStore(translations = m)
}
