//! I18n — internationalization and localization library for Lyric.
//! Stability: @experimental — the surface compiles and the JSON-loaded
//! translation store has tests; the BCP-47 locale parser has not been
//! exercised against the full IANA tag set.
//!
//! Provides locale-aware translation with variable substitution.
//! `TranslationStore` is the public interface; `InProcessTranslationStore` is
//! the bundled in-process implementation backed by a mutable `Map`.
//!
//! Usage:
//!
//!   import I18n
//!   import Std.Collections
//!
//!   val store = I18n.fromJson(translationsJson)?
//!   val locale = I18n.makeLocale("en-US")
//!   println(I18n.translateLocale(store, "greeting", locale))
//!
//!   val vars = newMap()
//!   vars.add("name", "Alice")
//!   println(I18n.translateWithLocale(store, "greeting", locale, vars))
//!
//! `Locale` is opaque: `makeLocale`/`parseLocale` are the only ways to build
//! one, and `Locale.language`/`Locale.script`/`Locale.region` are the only
//! way to read one back apart, so every `Locale` in existence is guaranteed
//! normalised and structurally valid.
//!
//! See docs/03-decision-log.md and lyric-i18n/README.md.
@runtime_checked
@io
package I18n

import Std.Core
import Std.Collections
import Std.Char
import Std.Json
import Std.File as File
import Std.String as Str

// ─── Locale type ──────────────────────────────────────────────────────────────
/// A BCP 47 locale identifier: a primary language subtag, an optional script
/// subtag, and an optional region subtag. `script`/`region` are empty when
/// absent from the tag (e.g. "en" has both empty; "en-US" has an empty
/// `script`).
///
/// Opaque: build one with `makeLocale`/`parseLocale` (which normalise
/// casing and validate shape), read one back with the `Locale.language`/
/// `Locale.script`/`Locale.region` accessors below. This guarantees every
/// `Locale` value satisfies the invariant, so downstream code (compound-key
/// construction, `localeKey`) never has to re-validate.
@stable(since = "0.1")
pub opaque type Locale {
  language: String    // lowercase, e.g. "en", "fr", "zh" — always 2 or 3 letters
  script: String    // Titlecase, e.g. "Hant" — always empty or 4 letters
  region: String    // uppercase, e.g. "US", "GB", or 3 digits (UN M49) — always empty, 2 letters, or 3 digits

  invariant: (language.length == 2 or language.length == 3) and isLowercaseAsciiLetters(language)
  invariant: script.length == 0 or isTitlecaseAsciiScript(script)
  invariant: region.length == 0 or isUppercaseAsciiLetterRegion(region) or isDigitRegion(region)
}

/// Read the language subtag back off a `Locale` (opaque field accessor).
@stable(since = "0.2")
pub func Locale.language(locale: in Locale): String {
  locale.language
}

/// Read the script subtag back off a `Locale` (opaque field accessor).
/// Empty when the locale has no script subtag.
@stable(since = "0.2")
pub func Locale.script(locale: in Locale): String {
  locale.script
}

/// Read the region subtag back off a `Locale` (opaque field accessor).
/// Empty when the locale has no region subtag.
@stable(since = "0.2")
pub func Locale.region(locale: in Locale): String {
  locale.region
}

// ─── Error type ───────────────────────────────────────────────────────────────
/// An error returned by a translation store operation.
@stable(since = "0.1")
pub record I18nError {
  message: String
  code: String
}

// ─── TranslationStore interface ───────────────────────────────────────────────
/// A translation store.  Obtain one with `inProcess()`, `fromJson()`, or
/// `loadFromPath()`.
@stable(since = "0.1")
pub interface TranslationStore {
  /// Return the translation for `key` in `locale`.
  /// Falls back to the language-only variant, then returns `key` itself when
  /// no translation is found (graceful degradation).
  func translate(key: in String, locale: in Locale): String
    requires: key.length > 0

  /// Return the translation for `key` in `locale` with `{varName}` placeholders
  /// substituted from `vars`.  Missing placeholder keys are left unchanged.
  /// If the substituted output would exceed `maxSubstitutionOutputLength`
  /// characters, returns the un-substituted template unchanged instead.
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
@stable(since = "0.1")
pub record InProcessTranslationStore {
  var translations: Map[String, String]
  var localeKeys: List[String]
}

impl TranslationStore for InProcessTranslationStore {
  func translate(key: in String, locale: in Locale): String {
    val fullKey = localeKey(locale)
    val compoundFull = fullKey + "|" + key
    // Use the Map `containsKey` + index methods rather than the generic
    // free function `mapGet` (`Option`-returning): a cross-package call to a
    // generic stdlib free function is not resolved by the self-hosted MSIL
    // backend yet (it skips generic functions in `registerStdlibFunc`), so
    // `mapGet`/`isSome`/`unwrapOr` mis-bind here.  The non-generic Map methods
    // bind correctly, matching the `containsKey`/`add` usage in
    // `buildStoreFromObject`.
    if self.translations.containsKey(compoundFull) {
      return self.translations[compoundFull]
    }
    if locale.region.length > 0 {
      val compoundLang = locale.language + "|" + key
      if self.translations.containsKey(compoundLang) {
        return self.translations[compoundLang]
      }
    }
    return key
  }

  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String {
    val template = self.translate(key, locale)
    return substitutePlaceholders(template, vars)
  }

  func availableLocales(): slice[Locale] {
    // `localeKeys` holds raw top-level JSON keys, which are untrusted input
    // and not guaranteed to be well-formed BCP 47 tags; skip any that don't
    // parse rather than constructing an invalid `Locale` (impossible now
    // that `Locale` is opaque and invariant-checked) or panicking.
    val result: List[Locale] = newList()
    var i: Int = 0
    while i < self.localeKeys.count {
      match parseLocale(self.localeKeys[i]) {
        case Some(loc) -> result.add(loc)
        case None -> ()
      }
      i = i + 1
    }
    return result.toArray()
  }

  func hasKey(key: in String, locale: in Locale): Bool {
    val fullKey = localeKey(locale)
    val compoundFull = fullKey + "|" + key
    // Non-generic Map `containsKey` method (see `translate` for why the
    // generic `mapGet`/`isSome` free functions are avoided here).
    if self.translations.containsKey(compoundFull) {
      return true
    }
    if locale.region.length > 0 {
      val compoundLang = locale.language + "|" + key
      if self.translations.containsKey(compoundLang) {
        return true
      }
    }
    return false
  }
}

// ─── Factory functions ────────────────────────────────────────────────────────
/// Create an empty in-process translation store.
@stable(since = "0.1")
pub func inProcess(): InProcessTranslationStore {
  return InProcessTranslationStore(translations = newMap(), localeKeys = newList())
}

/// Parse a translations JSON object and return an in-process store.
///
/// Expected JSON format:
///   { "en": { "key": "value", ... }, "fr": { "key": "valeur", ... }, ... }
///
/// Each top-level key must parse as a BCP 47 tag (`parseLocale`); it is
/// stored under its *canonical* `localeKey` form, so `"en_US"`, `"EN-us"`,
/// and `"en-US"` all land in the same bucket. This keeps storage consistent
/// with lookup: `translate`/`hasKey` always look up `localeKey(locale)`.
///
/// Never throws: malformed JSON, a non-object root, a locale key that is not
/// a well-formed BCP 47 tag, two locale keys that canonicalise to the same
/// locale, or a translation value that is not a JSON string all return
/// `Err` (naming the offending key, where applicable) instead of raising a
/// `Bug`.
func decodeLocaleTranslations(
  // Decode one locale's `{ "key": "value", ... }` object into `m`, keyed
  // `"<canonicalKey>|<translationKey>"`. Takes the locale's `JsonElement`
  // directly as a parameter — a plain free-function helper, not inlined into
  // `fromJson` (#7357: this used to be impossible on the self-hosted JVM
  // backend, which resolved a bare `JsonElement` parameter/lambda-parameter
  // type declared outside the CURRENT package — here, imported transitively
  // via `Std.Json`'s own `import Std.JsonHost`, never imported directly by
  // this file — to a phantom same-package class instead of the real
  // `Std.JsonHost.JsonElement`, throwing `NoClassDefFoundError` at class-load;
  // fixed by resolving a bare type reference through the file's TRANSITIVE
  // import closure, not just its direct imports).
  localeVal: in JsonElement,
  lk: in String,
  canonicalKey: in String,
  m: in Map[String, String],
): Result[Unit, I18nError] {
  var innerEn = enumerateObject(localeVal)
  while objectMoveNext(innerEn) {
    val tkeyProp = objectCurrent(innerEn)
    val tkey = propertyName(tkeyProp)
    if tkey.contains("|") {
      return Err(I18nError(message = "Translation key \"" + tkey + "\" must not contain '|'", code = "INVALID_KEY"))
    }
    val tvalElem = propertyValue(tkeyProp)
    if not isJsonString(tvalElem) {
      return Err(
        I18nError(
          message = "Translation value for key \"" + tkey + "\" in locale \"" + lk + "\" is not a string",
          code = "INVALID_VALUE"
        )
      )
    }
    val tval = getString(tvalElem)
    val compound = canonicalKey + "|" + tkey
    if not m.containsKey(compound) {
      m.add(compound, tval)
    }
  }
  return Ok(value = ())
}

@stable(since = "0.1")
pub func fromJson(json: in String): Result[InProcessTranslationStore, I18nError] {
  match tryParseJson(json) {
    case Err(msg) -> return Err(I18nError(message = "Malformed translations JSON: " + msg, code = "PARSE_ERROR"))
    case Ok(doc) -> {
      defer {
        disposeJson(doc)
      }
      val root = rootElement(doc)
      if valueKind(root) != 1 {
        return Err(
          I18nError(message = "Translations JSON root must be an object, e.g. {\"en\": {...}}", code = "INVALID_ROOT")
        )
      }
      var m: Map[String, String] = newMap()
      var keys: List[String] = newList()
      var outerEn = enumerateObject(root)
      while objectMoveNext(outerEn) {
        val localeProp = objectCurrent(outerEn)
        val lk = propertyName(localeProp)
        val localeVal = propertyValue(localeProp)
        match parseLocale(lk) {
          case None -> {
            return Err(I18nError(message = "Locale key \"" + lk + "\" is not a valid BCP 47 tag", code = "INVALID_LOCALE_KEY"))
          }
          case Some(loc) -> {
            // Store under the canonical locale key, not the raw JSON key: two
            // JSON keys that canonicalise to the same locale (e.g. "en_US"
            // and "EN-us") must land in the same bucket, matching
            // `translate`/`hasKey`, which always look up `localeKey(locale)`.
            val canonicalKey = localeKey(loc)
            if valueKind(localeVal) == 1 {
              // Two distinct JSON keys canonicalising to the same locale
              // would otherwise silently merge into one bucket (last-write
              // wins) instead of surfacing the ambiguity to the caller.
              var dup: Bool = false
              var ki: Int = 0
              while ki < keys.count {
                if keys[ki] == canonicalKey {
                  dup = true
                }
                ki = ki + 1
              }
              if dup {
                return Err(
                  I18nError(
                    message = "Locale key \"" + lk + "\" duplicates already-registered locale \"" + canonicalKey + "\"",
                    code = "DUPLICATE_LOCALE"
                  )
                )
              }
              match decodeLocaleTranslations(localeVal, lk, canonicalKey, m) {
                case Err(e) -> return Err(e)
                case Ok(_) -> ()
              }
              // A locale-value entry that isn't itself an object is silently
              // skipped (unchanged from the pre-existing behaviour;
              // `fromJson`'s documented error cases don't cover it), so
              // `keys` only grows for entries that reach here.
              keys.add(canonicalKey)
            }
          }
        }
      }
      return Ok(value = InProcessTranslationStore(translations = m, localeKeys = keys))
    }
  }
}

/// Load translations from `path` and return an in-process store.
@stable(since = "0.1")
pub func loadFromPath(path: in String): Result[InProcessTranslationStore, I18nError] {
  // Pattern-match the Result directly rather than the generic `isErr` /
  // `unwrapResultOr` free functions, which the self-hosted MSIL backend does
  // not yet resolve across packages (see `translate`).
  match File.readText(path) {
    case Ok(json) -> {
      return fromJson(json)
    }
    case Err(_) -> {
      return Err(I18nError(message = "Failed to read file: " + path, code = "LOAD_ERROR"))
    }
  }
}

// ─── Convenience functions ────────────────────────────────────────────────────
/// Translate `key` using the default locale ("en").
@stable(since = "0.1")
pub func translate(store: in TranslationStore, key: in String): String
  requires: key.length > 0
{
  val loc = defaultLocale()
  return store.translate(key, loc)
}

/// Translate `key` using the given `locale`.
@stable(since = "0.1")
pub func translateLocale(store: in TranslationStore, key: in String, locale: in Locale): String
  requires: key.length > 0
{
  return store.translate(key, locale)
}

/// Translate `key` with variable substitution using the default locale.
@stable(since = "0.1")
pub func translateWith(store: in TranslationStore, key: in String, vars: in Map[String, String]): String
  requires: key.length > 0
{
  val loc = defaultLocale()
  return store.translateWith(key, loc, vars)
}

/// Translate `key` with variable substitution using the given `locale`.
@stable(since = "0.1")
pub func translateWithLocale(
  store: in TranslationStore, key: in String, locale: in Locale, vars: in Map[String, String]
): String
  requires: key.length > 0
{
  return store.translateWith(key, locale, vars)
}

/// Parse a BCP 47 tag string into a `Locale`, normalising and validating it.
/// A validating constructor: panics (via `requires:`) if `tag` is not a
/// well-formed `language[-script][-region]` tag — use `parseLocale` instead
/// for untrusted input.
/// "en-US"     → language "en", region "US"
/// "en"        → language "en", no script, no region
/// "zh-Hant-TW"→ language "zh", script "Hant", region "TW"
/// "en_us"     → normalised to language "en", region "US" (accepts `_`,
///               normalises case, same as "en-US")
@stable(since = "0.1")
pub func makeLocale(tag: in String): Locale
  requires: isValidLocaleTag(tag)
{
  match parseLocale(tag) {
    case Some(loc) -> loc
    case None -> panic("unreachable: makeLocale's requires: already validated the tag")
  }
}

/// Parse a BCP 47 `language[-script][-region]` tag string into a `Locale`,
/// or `None` if it is not well-formed. Accepts `_` as a subtag separator
/// (e.g. "en_US") in addition to `-`, and normalises casing: language
/// lowercase, script Titlecase, region uppercase (or left as-is for a
/// 3-digit UN M49 region code).
/// "en-US"      → Some(language "en", region "US")
/// "en"         → Some(language "en")
/// "zh-Hant-TW" → Some(language "zh", script "Hant", region "TW")
/// "en_us"      → Some(language "en", region "US")
/// "e"          → None (language subtag too short)
/// "en-USA"     → None (region subtag is neither 2 letters nor 3 digits)
@stable(since = "0.2")
pub func parseLocale(tag: in String): Option[Locale] {
  val normalized = tag.replace("_", "-")
  val parts = normalized.split("-")
  if parts.length < 1 {
    return None
  }
  val langPart = parts[0]
  if not isAsciiAlphaOnly(langPart) or (langPart.length != 2 and langPart.length != 3) {
    return None
  }
  val language = langPart.toLower()

  var script = ""
  var region = ""
  var idx = 1

  if idx < parts.length and parts[idx].length == 4 and isAsciiAlphaOnly(parts[idx]) {
    script = titleCaseAscii(parts[idx])
    idx = idx + 1
  }

  if idx < parts.length {
    val regionPart = parts[idx]
    if regionPart.length == 2 and isAsciiAlphaOnly(regionPart) {
      region = regionPart.toUpper()
      idx = idx + 1
    } else if regionPart.length == 3 and isAsciiDigitOnly(regionPart) {
      region = regionPart
      idx = idx + 1
    } else {
      return None
    }
  }

  if idx != parts.length {
    // Leftover subtags (variants, extensions, ...) — not supported.
    return None
  }

  return Some(value = Locale(language = language, script = script, region = region))
}

/// Convert a `Locale` back to its BCP 47 key string.
/// "en" → "en"; "en-US" → "en-US"; "zh-Hant-TW" → "zh-Hant-TW".
@stable(since = "0.1")
pub func localeKey(locale: in Locale): String {
  var key = locale.language
  if locale.script.length > 0 {
    key = key + "-" + locale.script
  }
  if locale.region.length > 0 {
    key = key + "-" + locale.region
  }
  return key
}

/// Return the default locale ("en").
@stable(since = "0.1")
pub func defaultLocale(): Locale {
  return makeLocale("en")
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// True when `tag` is a well-formed BCP 47 `language[-script][-region]` tag
// (`makeLocale`'s `requires:` predicate). `@pure` is required for any
// function called from a `requires:`/`ensures:` clause (§6.3); `parseLocale`
// itself does no I/O or mutation, so this is honest, not just a compiler
// workaround.
@pure
func isValidLocaleTag(tag: in String): Bool {
  match parseLocale(tag) {
    case Some(_) -> true
    case None -> false
  }
}

// True iff every character of `s` is a lowercase ASCII letter (the
// `Locale.language` invariant's character-class check).
@pure
func isLowercaseAsciiLetters(s: in String): Bool {
  var i = 0
  while i < s.length {
    if not isAsciiLower(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  return true
}

// True iff `s` is exactly 4 characters, an uppercase ASCII letter followed
// by three lowercase ASCII letters (the `Locale.script` invariant's
// character-class check, e.g. "Hant").
@pure
func isTitlecaseAsciiScript(s: in String): Bool {
  if s.length != 4 {
    return false
  }
  if not isAsciiUpper(Str.charAtOrReplacement(s, 0)) {
    return false
  }
  var i = 1
  while i < 4 {
    if not isAsciiLower(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  return true
}

// True iff `s` is exactly 2 uppercase ASCII letters (the `Locale.region`
// invariant's letter-region character-class check, e.g. "US").
@pure
func isUppercaseAsciiLetterRegion(s: in String): Bool {
  if s.length != 2 {
    return false
  }
  return isAsciiUpper(Str.charAtOrReplacement(s, 0)) and isAsciiUpper(Str.charAtOrReplacement(s, 1))
}

// True iff `s` is exactly 3 ASCII digits (the `Locale.region` invariant's
// UN M49 numeric-region character-class check, e.g. "419").
@pure
func isDigitRegion(s: in String): Bool {
  if s.length != 3 {
    return false
  }
  return isAsciiDigit(Str.charAtOrReplacement(s, 0)) and isAsciiDigit(Str.charAtOrReplacement(s, 1)) and
    isAsciiDigit(Str.charAtOrReplacement(s, 2))
}

// True iff `s` is non-empty and every character is an ASCII letter.
func isAsciiAlphaOnly(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    if not isAsciiLetter(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  return true
}

// True iff `s` is non-empty and every character is an ASCII digit.
func isAsciiDigitOnly(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    if not isAsciiDigit(Str.charAtOrReplacement(s, i)) {
      return false
    }
    i = i + 1
  }
  return true
}

// Titlecase an ASCII alphabetic subtag: first letter upper, the rest lower
// (e.g. "hant" / "HANT" / "Hant" all become "Hant").
func titleCaseAscii(s: in String): String {
  return s.substring(0, 1).toUpper() + s.substring(1, s.length - 1).toLower()
}

/// Maximum output length, in characters, that `translateWith`/
/// `translateWithLocale` (and the `TranslationStore.translateWith` interface
/// method) will produce by substituting `{varName}` placeholders. If
/// substitution would exceed this, the raw un-substituted template is
/// returned unchanged instead — a documented, honest part of the public
/// contract (not a silent internal fallback), so callers who need to detect
/// that case can compare their template against the returned string, or
/// simply keep their inputs well under this bound.
@stable(since = "0.2")
pub val maxSubstitutionOutputLength: Int = 1048576

// Substitute {varName} placeholders in `template` using values from `vars`.
// Unknown placeholder keys are left unchanged in the output.
// Substitution values are inserted verbatim; they are NOT re-scanned for
// further placeholders.  Returns `template` unchanged if the expanded output
// would exceed `maxSubstitutionOutputLength` characters — see that
// constant's doc comment; this is a documented part of the public contract.
func substitutePlaceholders(template: in String, vars: in Map[String, String]): String {
  var buf: String = ""
  var i: Int = 0
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
        i = template.length
      } else {
        val varName = template.substring(i + 1, j - i - 1)
        // Non-generic Map `containsKey` + index methods rather than the
        // generic `mapGet`/`isSome`/`unwrapOr` free functions, which the
        // self-hosted MSIL backend does not yet resolve across packages (see
        // `translate`).  An unknown placeholder is left verbatim.
        if vars.containsKey(varName) {
          val value = vars[varName]
          if buf.length + value.length > maxSubstitutionOutputLength {
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
      i = i + 1
    }
  }
  return buf
}
