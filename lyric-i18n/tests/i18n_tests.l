//! tests/i18n_tests.l — test suite for the I18n package.
//! Covers locale construction, locale key serialisation, and the
//! InProcessTranslationStore: translate, translateWith, hasKey,
//! availableLocales.
@test_module
package I18n.I18nTests

import Std.Core
import Std.Testing
import Std.Collections
import I18n

// Build a store through the public fromJson path so the compound-key flat
// map (`<localeKey>|<translationKey>`) and the localeKeys list are populated
// exactly as production code would. The JSON object shape is
// `{ "<locale>": { "<key>": "<value>" } }`.
func storeFromJson(json: in String): InProcessTranslationStore {
  match I18n.fromJson(json) {
    case Ok(s) -> return s
    case Err(_) -> return I18n.inProcess()
  }
}

// ─── makeLocale ───────────────────────────────────────────────────────────────
test "makeLocale: parses a full language-region tag" {
  val loc = I18n.makeLocale("en-US")
  assertEqual(loc.language, "en", "language component")
  assertEqual(loc.region, "US", "region component")
}

test "makeLocale: parses a language-only tag" {
  val loc = I18n.makeLocale("en")
  assertEqual(loc.language, "en", "language component")
  assertEqual(loc.region, "", "region must be empty for language-only tag")
}

test "makeLocale: parses zh-CN correctly" {
  val loc = I18n.makeLocale("zh-CN")
  assertEqual(loc.language, "zh", "language component")
  assertEqual(loc.region, "CN", "region component")
}

test "makeLocale: parses fr tag" {
  val loc = I18n.makeLocale("fr")
  assertEqual(loc.language, "fr", "language component")
  assertEqual(loc.region, "", "no region for language-only tag")
}

test "makeLocale: parses pt-BR correctly" {
  val loc = I18n.makeLocale("pt-BR")
  assertEqual(loc.language, "pt", "language component")
  assertEqual(loc.region, "BR", "region component")
}

// ─── localeKey ────────────────────────────────────────────────────────────────
test "localeKey: full locale produces 'language-REGION' string" {
  val loc = Locale(language = "en", region = "US")
  assertEqual(I18n.localeKey(loc), "en-US", "localeKey for en-US")
}

test "localeKey: language-only locale produces just the language code" {
  val loc = Locale(language = "en", region = "")
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
  assertEqual(locs[0].language, "fr", "locale language")
  assertEqual(locs[0].region, "", "locale region (language-only)")
}

test "availableLocales: returns all registered locales" {
  val store = storeFromJson("{\"en\": {\"k\": \"v\"}, \"en-GB\": {\"k\": \"v\"}, \"fr\": {\"k\": \"v\"}}")
  val locs = store.availableLocales()
  assertEqualInt(locs.length, 3, "three registered locales must appear")
}
