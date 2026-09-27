//! tests/i18n_tests.l — test suite for the I18n package.
//! Covers locale construction, locale key serialisation, and the
//! InProcessTranslationStore: translate, translateWith, hasKey,
//! availableLocales.
@test_module
package I18n.I18nTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.String
import I18n

// Build a store through the public fromJson path so the compound-key flat
// map (`<localeKey>|<translationKey>`) and the localeKeys list are populated
// exactly as production code would. The JSON object shape is
// `{ "<locale>": { "<key>": "<value>" } }`.
func storeFromJson(json: in String): InProcessTranslationStore {
  match I18n.fromJson(json) {
    case Ok(s) -> return s
    // Surface a malformed fixture loudly rather than masking it as an empty
    // store (which would later show up as a misleading "key not found").
    case Err(e) -> {
      assertTrue(false, "test fixture JSON failed to parse: " + e.message)
      return I18n.inProcess()
    }
  }
}

// ─── makeLocale ───────────────────────────────────────────────────────────────
test "makeLocale: parses a full language-region tag" {
  val loc = I18n.makeLocale("en-US")
  assertEqual(Locale.language(loc), "en", "language component")
  assertEqual(Locale.region(loc), "US", "region component")
}

test "makeLocale: parses a language-only tag" {
  val loc = I18n.makeLocale("en")
  assertEqual(Locale.language(loc), "en", "language component")
  assertEqual(Locale.region(loc), "", "region must be empty for language-only tag")
}

test "makeLocale: parses zh-CN correctly" {
  val loc = I18n.makeLocale("zh-CN")
  assertEqual(Locale.language(loc), "zh", "language component")
  assertEqual(Locale.region(loc), "CN", "region component")
}

test "makeLocale: parses fr tag" {
  val loc = I18n.makeLocale("fr")
  assertEqual(Locale.language(loc), "fr", "language component")
  assertEqual(Locale.region(loc), "", "no region for language-only tag")
}

test "makeLocale: parses pt-BR correctly" {
  val loc = I18n.makeLocale("pt-BR")
  assertEqual(Locale.language(loc), "pt", "language component")
  assertEqual(Locale.region(loc), "BR", "region component")
}

// ─── makeLocale: invariant / precondition violations ───────────────────────────
func triggerMakeLocaleTooShortLanguage(): Unit {
  val _ = I18n.makeLocale("e")
}

func triggerMakeLocaleBadRegion(): Unit {
  val _ = I18n.makeLocale("en-USA")
}

func triggerMakeLocaleTrailingSubtag(): Unit {
  val _ = I18n.makeLocale("en-US-extra")
}

test "makeLocale panics on a language subtag that is too short" {
  assertPanics("language too short", triggerMakeLocaleTooShortLanguage)
}

test "makeLocale panics on a region subtag that is neither 2 letters nor 3 digits" {
  assertPanics("bad region", triggerMakeLocaleBadRegion)
}

test "makeLocale panics on a tag with an unsupported trailing subtag" {
  assertPanics("trailing subtag", triggerMakeLocaleTrailingSubtag)
}

// ─── parseLocale ────────────────────────────────────────────────────────────────
test "parseLocale: accepts '_' as a subtag separator, same as '-'" {
  match I18n.parseLocale("en_US") {
    case Some(loc) -> {
      assertEqual(Locale.language(loc), "en", "language component")
      assertEqual(Locale.region(loc), "US", "region component")
    }
    case None -> assertTrue(false, "expected Some for 'en_US'")
  }
}

test "parseLocale: normalises language to lowercase, region to uppercase" {
  match I18n.parseLocale("EN-us") {
    case Some(loc) -> {
      assertEqual(Locale.language(loc), "en", "language normalised to lowercase")
      assertEqual(Locale.region(loc), "US", "region normalised to uppercase")
    }
    case None -> assertTrue(false, "expected Some for 'EN-us'")
  }
}

test "parseLocale: parses language-script-region and titlecases the script" {
  match I18n.parseLocale("zh-hant-tw") {
    case Some(loc) -> {
      assertEqual(Locale.language(loc), "zh", "language component")
      assertEqual(Locale.script(loc), "Hant", "script normalised to titlecase")
      assertEqual(Locale.region(loc), "TW", "region normalised to uppercase")
    }
    case None -> assertTrue(false, "expected Some for 'zh-hant-tw'")
  }
}

test "parseLocale: accepts a 3-digit UN M49 region code" {
  match I18n.parseLocale("en-419") {
    case Some(loc) -> {
      assertEqual(Locale.language(loc), "en", "language component")
      assertEqual(Locale.region(loc), "419", "numeric region kept as-is")
    }
    case None -> assertTrue(false, "expected Some for 'en-419'")
  }
}

test "parseLocale: returns None for a language subtag that is too short" {
  match I18n.parseLocale("e") {
    case Some(_) -> assertTrue(false, "expected None for a 1-letter language")
    case None -> ()
  }
}

test "parseLocale: returns None for a language subtag that is too long" {
  match I18n.parseLocale("english") {
    case Some(_) -> assertTrue(false, "expected None for a 7-letter language")
    case None -> ()
  }
}

test "parseLocale: returns None for a region that is neither 2 letters nor 3 digits" {
  match I18n.parseLocale("en-USA") {
    case Some(_) -> assertTrue(false, "expected None for a 3-letter region")
    case None -> ()
  }
}

test "parseLocale: returns None for a 2-digit numeric region" {
  match I18n.parseLocale("en-42") {
    case Some(_) -> assertTrue(false, "expected None for a 2-digit region")
    case None -> ()
  }
}

test "parseLocale: returns None for an unsupported trailing subtag" {
  match I18n.parseLocale("en-US-extra") {
    case Some(_) -> assertTrue(false, "expected None for a trailing 4th subtag")
    case None -> ()
  }
}

test "parseLocale: returns None for an empty string" {
  match I18n.parseLocale("") {
    case Some(_) -> assertTrue(false, "expected None for an empty tag")
    case None -> ()
  }
}

// ─── localeKey ────────────────────────────────────────────────────────────────
test "localeKey: full locale produces 'language-REGION' string" {
  val loc = I18n.makeLocale("en-US")
  assertEqual(I18n.localeKey(loc), "en-US", "localeKey for en-US")
}

test "localeKey: language-only locale produces just the language code" {
  val loc = I18n.makeLocale("en")
  assertEqual(I18n.localeKey(loc), "en", "localeKey for language-only locale")
}

test "localeKey: zh-CN round-trips through makeLocale and localeKey" {
  val loc = I18n.makeLocale("zh-CN")
  assertEqual(I18n.localeKey(loc), "zh-CN", "round-trip localeKey for zh-CN")
}

test "localeKey: language-only round-trips through makeLocale and localeKey" {
  val loc = I18n.makeLocale("fr")
  assertEqual(I18n.localeKey(loc), "fr", "round-trip localeKey for fr")
}

test "localeKey: language-script-region round-trips through parseLocale and localeKey" {
  match I18n.parseLocale("zh-Hant-TW") {
    case Some(loc) -> assertEqual(I18n.localeKey(loc), "zh-Hant-TW", "round-trip localeKey for zh-Hant-TW")
    case None -> assertTrue(false, "expected Some for 'zh-Hant-TW'")
  }
}

// ─── InProcessTranslationStore: translate ─────────────────────────────────────
test "translate: returns the exact match for a full locale" {
  val store = storeFromJson("{\"en-US\": {\"greeting\": \"Hello\"}, \"fr\": {\"greeting\": \"Bonjour\"}}")
  val loc = I18n.makeLocale("en-US")
  assertEqual(store.translate("greeting", loc), "Hello", "exact locale match")
}

test "translate: falls back to language-only when full locale key is absent" {
  val store = storeFromJson("{\"en\": {\"greeting\": \"Hello\"}}")
  // "en-GB" is not in the store; must fall back to "en".
  val loc = I18n.makeLocale("en-GB")
  assertEqual(store.translate("greeting", loc), "Hello", "must fall back to language-only locale")
}

test "translate: returns the key itself when no translation is found" {
  val store = storeFromJson("{\"en\": {\"other-key\": \"Other\"}}")
  val loc = I18n.makeLocale("en")
  assertEqual(
    store.translate("missing-key", loc),
    "missing-key",
    "missing key must be returned unchanged as the final fallback"
  )
}

test "translate: language-only locale uses language key directly" {
  val store = storeFromJson("{\"fr\": {\"bye\": \"Au revoir\"}}")
  val loc = I18n.makeLocale("fr")
  assertEqual(store.translate("bye", loc), "Au revoir", "language-only locale match")
}

test "translate: full locale match takes priority over language-only fallback" {
  val store = storeFromJson("{\"en\": {\"colour\": \"color\"}, \"en-GB\": {\"colour\": \"colour\"}}")
  val locUs = I18n.makeLocale("en-US")
  val locGb = I18n.makeLocale("en-GB")
  assertEqual(store.translate("colour", locGb), "colour", "en-GB exact match must be preferred")
  assertEqual(store.translate("colour", locUs), "color", "en-US falls back to en (language-only)")
}

// ─── InProcessTranslationStore: translateWith ─────────────────────────────────
test "translateWith: substitutes a single {name} placeholder" {
  val store = storeFromJson("{\"en\": {\"welcome\": \"Hello, {name}!\"}}")
  val loc = I18n.makeLocale("en")
  var vars: Map[String, String] = newMap()
  vars.add("name", "Alice")
  assertEqual(store.translateWith("welcome", loc, vars), "Hello, Alice!", "placeholder must be substituted")
}

test "translateWith: leaves unknown placeholders unchanged" {
  val store = storeFromJson("{\"en\": {\"msg\": \"Hello, {name}! You have {count} messages.\"}}")
  val loc = I18n.makeLocale("en")
  var vars: Map[String, String] = newMap()
  vars.add("name", "Bob")
  // {count} has no entry in vars — must be left as-is.
  assertEqual(
    store.translateWith("msg", loc, vars),
    "Hello, Bob! You have {count} messages.",
    "unknown placeholder must remain unchanged"
  )
}

test "translateWith: returns key itself with no substitution when translation is absent" {
  val store = I18n.inProcess()
  val loc = I18n.makeLocale("en")
  var vars: Map[String, String] = newMap()
  vars.add("name", "Carol")
  // Missing translation → key returned; then substitution is applied on the key.
  // The key "no-key" contains no placeholders, so the result is just "no-key".
  assertEqual(store.translateWith("no-key", loc, vars), "no-key", "missing translation key must be returned unchanged")
}

test "translateWith: empty vars map leaves template unchanged" {
  val store = storeFromJson("{\"en\": {\"greet\": \"Hi, {user}!\"}}")
  val loc = I18n.makeLocale("en")
  val vars: Map[String, String] = newMap()
  assertEqual(store.translateWith("greet", loc, vars), "Hi, {user}!", "empty vars must leave placeholder unchanged")
}

// ─── InProcessTranslationStore: hasKey ───────────────────────────────────────
test "hasKey: returns true when the key exists for the exact locale" {
  val store = storeFromJson("{\"en-US\": {\"hello\": \"Hello\"}}")
  val loc = I18n.makeLocale("en-US")
  assertTrue(store.hasKey("hello", loc), "hasKey must return true for registered key")
}

test "hasKey: returns false when key is absent for the locale" {
  val store = storeFromJson("{\"en\": {\"hello\": \"Hello\"}}")
  val loc = I18n.makeLocale("en")
  assertTrue(not store.hasKey("missing", loc), "hasKey must return false for an absent key")
}

test "hasKey: falls back to language-only locale" {
  val store = storeFromJson("{\"en\": {\"title\": \"Title\"}}")
  // "en-AU" is not in the store but "en" is.
  val loc = I18n.makeLocale("en-AU")
  assertTrue(store.hasKey("title", loc), "hasKey must fall back to language-only locale")
}

test "hasKey: returns false when no translations are registered at all" {
  val store = I18n.inProcess()
  val loc = I18n.makeLocale("en")
  assertTrue(not store.hasKey("any-key", loc), "empty store must return false for hasKey")
}

// ─── InProcessTranslationStore: availableLocales ──────────────────────────────
test "availableLocales: returns empty list for an empty store" {
  val store = I18n.inProcess()
  val locs = store.availableLocales()
  assertEqualInt(locs.length, 0, "empty store must have no available locales")
}

test "availableLocales: returns one locale when one locale is registered" {
  val store = storeFromJson("{\"fr\": {\"hi\": \"Salut\"}}")
  val locs = store.availableLocales()
  assertEqualInt(locs.length, 1, "one registered locale must appear")
  assertEqual(Locale.language(locs[0]), "fr", "locale language")
  assertEqual(Locale.region(locs[0]), "", "locale region (language-only)")
}

test "availableLocales: returns all registered locales" {
  val store = storeFromJson("{\"en\": {\"k\": \"v\"}, \"en-GB\": {\"k\": \"v\"}, \"fr\": {\"k\": \"v\"}}")
  val locs = store.availableLocales()
  assertEqualInt(locs.length, 3, "three registered locales must appear")
}

// ─── fromJson: error handling ───────────────────────────────────────────────────
test "fromJson: returns Err for malformed JSON" {
  match I18n.fromJson("{ not valid json") {
    case Ok(_) -> assertTrue(false, "expected Err for malformed JSON")
    case Err(e) -> assertEqual(e.code, "PARSE_ERROR", "error code for malformed JSON")
  }
}

test "fromJson: returns Err for a non-object root" {
  match I18n.fromJson("[\"en\", \"fr\"]") {
    case Ok(_) -> assertTrue(false, "expected Err for a non-object root")
    case Err(e) -> assertEqual(e.code, "INVALID_ROOT", "error code for a non-object root")
  }
}

test "fromJson: returns Err naming the key for a non-string translation value" {
  match I18n.fromJson("{\"en\": {\"greeting\": 42}}") {
    case Ok(_) -> assertTrue(false, "expected Err for a non-string translation value")
    case Err(e) -> {
      assertEqual(e.code, "INVALID_VALUE", "error code for a non-string translation value")
      assertTrue(e.message.contains("greeting"), "error message names the offending key")
    }
  }
}

test "fromJson: still succeeds for well-formed input (never throws on the happy path)" {
  match I18n.fromJson("{\"en\": {\"greeting\": \"hi\"}}") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "expected Ok, got Err: " + e.message)
  }
}

// ─── fromJson: '|' compound-key collision ──────────────────────────────────────
test "fromJson: rejects a locale key containing '|'" {
  match I18n.fromJson("{\"en|US\": {\"greeting\": \"hi\"}}") {
    case Ok(_) -> assertTrue(false, "expected Err for a locale key containing '|'")
    case Err(e) -> assertEqual(e.code, "INVALID_LOCALE_KEY", "error code for a '|' in the locale key")
  }
}

test "fromJson: rejects a translation key containing '|'" {
  match I18n.fromJson("{\"en\": {\"US|foo\": \"hi\"}}") {
    case Ok(_) -> assertTrue(false, "expected Err for a translation key containing '|'")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "error code for a '|' in the translation key")
  }
}

test "fromJson: distinct (locale, key) pairs that could collide via '|' don't silently merge" {
  // Without the '|' rejection above, locale="en" + key="US|foo" would build
  // the exact same compound flat-map key ("en|US|foo") as locale="en|US" +
  // key="foo" — two semantically distinct entries colliding on one slot.
  // Both malformed inputs are now rejected outright, so there is nothing
  // left to collide; this test locks that in.
  match I18n.fromJson("{\"en\": {\"US|foo\": \"one\"}}") {
    case Ok(_) -> assertTrue(false, "expected Err (the '|' rejection above)")
    case Err(e) -> assertEqual(e.code, "INVALID_KEY", "rejected before any collision could occur")
  }
}

// ─── translateWith: substitution output length ─────────────────────────────────
test "translateWith: returns the raw template unchanged when substitution would exceed the documented limit" {
  val store = storeFromJson("{\"en\": {\"big\": \"{filler}\"}}")
  val loc = I18n.makeLocale("en")
  var vars: Map[String, String] = newMap()
  // One character over the documented limit forces the fallback path.
  vars.add("filler", repeat("x", I18n.maxSubstitutionOutputLength + 1))
  assertEqual(
    store.translateWith("big", loc, vars),
    "{filler}",
    "output exceeding maxSubstitutionOutputLength returns the un-substituted template"
  )
}

test "translateWith: substitutes normally when output is within the documented limit" {
  val store = storeFromJson("{\"en\": {\"small\": \"{filler}\"}}")
  val loc = I18n.makeLocale("en")
  var vars: Map[String, String] = newMap()
  vars.add("filler", "ok")
  assertEqual(store.translateWith("small", loc, vars), "ok", "small substitution is unaffected by the length guard")
}
