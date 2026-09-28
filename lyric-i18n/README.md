# lyric-i18n

Internationalization with placeholder substitution and locale fallback.

## Platform parity

| Feature flag | Backend                                              | Status                |
|--------------|------------------------------------------------------|-----------------------|
| `dotnet`     | `Std.File` + `Std.Json` for translation file loads   | Available             |
| `jvm`        | `Std.File` + `Std.Json` for translation file loads   | Available, one known gap (below) |

`I18n`'s public API (`src/i18n.l`) needs no platform-specific kernel at
all: `Std.File`/`Std.Json` are already cross-platform (`Std.Json`'s
JVM backend was rewritten to pure Lyric in D-progress-555). Verified
against `tests/i18n_tests.l` on both targets.
`translate`/`translateWith`/`hasKey`/`fromJson`/`loadFromPath` are all
confirmed working on JVM.

One gap this surfaced: passing a `JsonElement`/`JsonDoc` (from
`Std.Json`) as the parameter type of a function declared in *this*
package fails at runtime on the self-hosted JVM backend
(`NoClassDefFoundError`, confirmed with an isolated repro — it resolves
the type against the caller's own package instead of the imported
one; tracked in #7652). `fromJson` avoids the pattern rather than working around it: its
whole JSON tree walk lives in one function body, with no such value
ever crossing a function boundary.

`I18n.Kernel` is a separate, standalone handle-based entry point
(`loadStore`/`translate`/`hasKey`/`availableLocalesJson`/
`parseTranslationsJson`) for consumers that want that specific
contract. It is a single, ungated, pure-Lyric package over
`Std.File`/`Std.Json`/`Std.Collections` (no platform split needed since
the logic has no platform-specific behavior at all), real and tested on
both targets (see `tests/i18n_kernel_tests.l` and
`docs/03-decision-log.md` D-progress-628).

## Packages

| Package | Purpose |
|---|---|
| `I18n` | Core types, `TranslationStore` interface, in-process and file-backed implementations, and public API |
| `I18n.Kernel` | Standalone handle-based translation-file kernel (pure Lyric, no platform-specific code — see Platform parity above) |

## Quick start

```lyric
import I18n
import Std.Collections

val translationsJson = "{\"en\": {\"greeting\": \"Hello, {name}!\", \"farewell\": \"Goodbye\"}, " +
  "\"es\": {\"greeting\": \"Hola, {name}!\", \"farewell\": \"Adiós\"}}"

val store = I18n.fromJson(translationsJson)?
val locale = I18n.makeLocale("en-US")

println(I18n.translateLocale(store, "greeting", locale))  // "Hello, {name}!" (no vars → placeholder unsubstituted)

var vars: Map[String, String] = newMap()
vars.add("name", "Alice")
println(I18n.translateWithLocale(store, "greeting", locale, vars))  // "Hello, Alice!"
```

## TranslationStore interface

`TranslationStore` is a pluggable interface (`src/i18n.l`); the shipped
implementation is `InProcessTranslationStore`, obtained via
`I18n.inProcess()`, `I18n.fromJson(json)`, or `I18n.loadFromPath(path)`:

```lyric
pub interface TranslationStore {
  func translate(key: in String, locale: in Locale): String
  func translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String
  func availableLocales(): slice[Locale]
  func hasKey(key: in String, locale: in Locale): Bool
}
```

## Placeholder substitution

Translation values support `{varName}` placeholders:

```lyric
import I18n
import Std.Collections

val translationsJson = "{\"en\": {\"welcome\": \"Welcome back, {username}! You have {count} messages.\"}}"
val store = I18n.fromJson(translationsJson)?
val loc = I18n.makeLocale("en")

var vars: Map[String, String] = newMap()
vars.add("username", "bob")
vars.add("count", "3")

val result = I18n.translateWithLocale(store, "welcome", loc, vars)
// Returns: "Welcome back, bob! You have 3 messages."
```

Missing placeholder keys in the vars map leave the `{varName}` unchanged.
Extra vars in the map are ignored. If the substituted output would exceed
`I18n.maxSubstitutionOutputLength` characters (1 MiB), `translateWith`
returns the un-substituted template unchanged instead — a documented part
of the contract, not a silent internal fallback.

## Locale parsing

`Locale` is opaque: the only ways to build one are `I18n.makeLocale(tag)`
(panics via `requires:` on a malformed tag) and `I18n.parseLocale(tag)`
(returns `Option[Locale]`); the only way to read one back apart is the
`Locale.language`/`Locale.script`/`Locale.region` accessors. Both parse a
BCP 47 `language[-script][-region]` tag, accept `_` as well as `-` as the
subtag separator, and normalise casing (language lowercase, script
Titlecase, region uppercase — a 3-digit UN M49 region code is left as-is):

```lyric
import I18n

val loc = I18n.makeLocale("en-US")
// I18n.makeLocale panics if the tag doesn't parse; use parseLocale for
// untrusted input instead:
match I18n.parseLocale("zh-hant-tw") {
  case Some(loc) -> {
    Locale.language(loc)  // "zh"
    Locale.script(loc)    // "Hant"
    Locale.region(loc)    // "TW"
  }
  case None -> println("not a valid BCP 47 tag")
}

I18n.localeKey(loc)  // "en-US"
```

`Locale`'s invariants enforce both subtag length and character class:
`language` is 2 or 3 lowercase ASCII letters; `script`, when present, is
one uppercase ASCII letter followed by three lowercase ASCII letters
(e.g. `"Hant"`); `region`, when present, is either 2 uppercase ASCII
letters or 3 ASCII digits (a UN M49 numeric region). Every `Locale` built
via `makeLocale`/`parseLocale` already satisfies this; the invariant
exists so no other construction path can produce one that doesn't.

## fromJson error handling

`I18n.fromJson` parses a translations JSON object shaped
`{ "<locale>": { "<key>": "<value>" } }` and never throws. It returns
`Err(I18nError)` for:

| `code` | When |
|---|---|
| `PARSE_ERROR` | The input is not well-formed JSON |
| `INVALID_ROOT` | The JSON root is not an object |
| `INVALID_LOCALE_KEY` | A top-level key does not parse as a BCP 47 tag (`I18n.parseLocale`) |
| `DUPLICATE_LOCALE` | Two top-level keys canonicalise to the same locale (e.g. `"en_US"` and `"EN-us"`) |
| `INVALID_KEY` | A translation key contains `\|` (the flat store's internal compound-key separator) |
| `INVALID_VALUE` | A translation value is not a JSON string (names the offending key) |

Each top-level locale key is stored under its *canonical* `I18n.localeKey`
form (not the raw JSON key), so `"en_US"`, `"EN-us"`, and `"en-US"` are all
equivalent and looked up identically by `translate`/`translateWith`/`hasKey`:

```lyric
match I18n.fromJson(json) {
  case Ok(store) -> ...
  case Err(e) -> println(e.code + ": " + e.message)
}
```

## Locale fallback

`translate`/`translateWith`/`hasKey` follow a two-step fallback chain. For
example, requesting `"greeting"` for the locale `"en-GB"`:

1. Try the exact locale key: `"en-GB"`
2. Fall back to the language-only key: `"en"`
3. If neither is found, `translate`/`translateWith` return the key itself
   unchanged (`hasKey` returns `false`)

```lyric
import I18n
import Std.Collections

val store = I18n.fromJson("{\"en\": {\"greeting\": \"Hello\"}, \"en-GB\": {\"greeting\": \"Howdy\"}}")?

I18n.translateLocale(store, "greeting", I18n.makeLocale("en-GB"))  // "Howdy" (exact match)
I18n.translateLocale(store, "greeting", I18n.makeLocale("en-US"))  // "Hello" (falls back to "en")
I18n.translateLocale(store, "missing", I18n.makeLocale("en"))      // "missing" (key itself, final fallback)
```

`translate`/`translateWithLocale` (module-level convenience functions)
use `I18n.defaultLocale()` (`"en"`) when no locale is given explicitly.

## API reference

```lyric
// Locale
I18n.makeLocale(tag: in String): Locale
I18n.parseLocale(tag: in String): Option[Locale]
I18n.localeKey(locale: in Locale): String
I18n.defaultLocale(): Locale
Locale.language(locale: in Locale): String
Locale.script(locale: in Locale): String
Locale.region(locale: in Locale): String

// Store construction
I18n.inProcess(): InProcessTranslationStore
I18n.fromJson(json: in String): Result[InProcessTranslationStore, I18nError]
I18n.loadFromPath(path: in String): Result[InProcessTranslationStore, I18nError]

// TranslationStore interface methods
store.translate(key: in String, locale: in Locale): String
store.translateWith(key: in String, locale: in Locale, vars: in Map[String, String]): String
store.availableLocales(): slice[Locale]
store.hasKey(key: in String, locale: in Locale): Bool

// Module-level convenience functions (use I18n.defaultLocale() when no locale is given)
I18n.translate(store: in TranslationStore, key: in String): String
I18n.translateLocale(store: in TranslationStore, key: in String, locale: in Locale): String
I18n.translateWith(store: in TranslationStore, key: in String, vars: in Map[String, String]): String
I18n.translateWithLocale(store: in TranslationStore, key: in String, locale: in Locale, vars: in Map[String, String]): String

I18n.maxSubstitutionOutputLength: Int
```

## File-backed store

Load translations from a JSON file on disk using `loadFromPath`:

```lyric
import I18n

val store = I18n.loadFromPath("./translations/all.json")?

val greeting = I18n.translate(store, "greeting")
```

The file is the same JSON shape `fromJson` expects — a single object
keyed by locale, e.g.:

```json
{
  "en": { "greeting": "Hello", "farewell": "Goodbye" },
  "fr": { "greeting": "Bonjour", "farewell": "Au revoir" }
}
```

## Decision log

See `docs/03-decision-log.md` D-progress-261.
