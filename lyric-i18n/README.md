# lyric-i18n

Internationalization with placeholder substitution and locale fallback.

## Platform parity

| Feature flag | Backend                                              | Status                |
|--------------|------------------------------------------------------|-----------------------|
| `dotnet`     | `System.IO` + `Std.Json` for translation file loads  | Available             |
| `jvm`        | `Std.File` + `Std.Json` (both cross-platform)        | Untested on JVM        |

`I18n` never had a real platform-specific kernel: `src/i18n.l` calls
`Std.File`/`Std.Json` directly, and both of those stdlib modules now
have working JVM backends (`Std.Json`'s JVM kernel was rewritten to
pure Lyric in D-progress-555, replacing a phantom-class shim). An
earlier `I18n.Kernel.Net`/`I18n.Kernel.Jvm` pair existed as `extern
package`-based scaffolding but was never imported by `i18n.l` and was
deleted as dead code (see `docs/03-decision-log.md`). This library has
not yet been built or tested against `--target jvm` in CI, so its
actual JVM status is unverified rather than a known blocker — running
its test suite on `--target jvm` is a small, well-scoped follow-up.

## Packages

| Package | Purpose |
|---|---|
| `I18n` | Core types, `TranslationStore` interface, in-process and file-backed implementations, and public API |

## Quick start

```lyric
import I18n

val translations = {
  "en": {
    "greeting": "Hello, {name}!",
    "farewell": "Goodbye"
  },
  "es": {
    "greeting": "Hola, {name}!",
    "farewell": "Adiós"
  }
}

val store = I18n.fromJson(translations)

match I18n.translate(store, "greeting", "en") {
  case Some(msg) -> println(msg)          // "Hello, {name}!"
  case None      -> println("missing key")
}

val greeted = I18n.translateWithVars(store, "greeting", "en", ["name": "Alice"])
// Returns: "Hello, Alice!"
```

## TranslationStore interface

`TranslationStore` is a pluggable interface so you can implement custom
loading strategies:

```lyric
pub interface TranslationStore {
  func get(key: in String, locale: in String): Option[String]
  func availableLocales(): slice[String]
  func hasKey(key: in String, locale: in String): Bool
}
```

The v1 implementations are `InProcessTranslationStore` (in-memory from JSON)
and `NativeTranslationStore` (file-backed).

## Placeholder substitution

Translation values support `{varName}` placeholders:

```lyric
val translations = {
  "en": {
    "welcome": "Welcome back, {username}! You have {count} messages."
  }
}

val store = I18n.fromJson(translations)

val result = I18n.translateWithVars(
  store,
  "welcome",
  "en",
  ["username": "bob", "count": "3"]
)
// Returns: "Welcome back, bob! You have 3 messages."
```

Missing placeholders in the vars map leave the `{varName}` unchanged.
Extra vars in the map are ignored.

## Locale fallback

Locale lookup follows a fallback chain. For example, requesting "en-GB":

1. Try exact match: `"en-GB"`
2. Fall back to language: `"en"`
3. Fall back to default: `""`

```lyric
val translations = {
  "": { "default": "Default message" },
  "en": { "greeting": "Hello" },
  "en-GB": { "greeting": "Howdy" }
}

val store = I18n.fromJson(translations)

I18n.translate(store, "greeting", "en-GB")  // Some("Howdy")
I18n.translate(store, "greeting", "en")     // Some("Hello")
I18n.translate(store, "default", "fr")      // Some("Default message")
```

## API reference

```lyric
I18n.fromJson(data: in Map[String, Map[String, String]])
  -> TranslationStore

I18n.loadNative(path: in String)
  -> Result[TranslationStore, IoError]

I18n.translate(store: in TranslationStore, key: in String, locale: in String)
  -> Option[String]

I18n.translateWithVars(store: in TranslationStore, key: in String,
                      locale: in String, vars: in Map[String, String])
  -> String

I18n.availableLocales(store: in TranslationStore)
  -> slice[String]

I18n.hasKey(store: in TranslationStore, key: in String, locale: in String)
  -> Bool

I18n.parseLocale(localeStr: in String)
  -> ParsedLocale

I18n.localeToString(locale: in ParsedLocale)
  -> String
```

## Configuration

Config block for locale defaults:

```lyric
pub record I18nConfig {
  defaultLocale: String
  translationsPath: String
}
```

Environment variable defaults (env prefix `LYRIC_CONFIG_I18N_`):

| Env var | Default | Meaning |
|---|---|---|
| `DEFAULTLOCALE` | `"en"` | Default fallback locale |
| `TRANSLATIONSPATH` | `"translations/"` | Path to translation JSON files |

## File-backed store

Load translations from disk using `NativeTranslationStore`:

```lyric
import I18n

val store = I18n.loadNative("./translations")?

val greeting = I18n.translate(store, "greeting", "en")
```

File structure:

```
translations/
  en.json
  es.json
  fr.json
```

Each file is a flat JSON object: `{ "key1": "value1", "key2": "value2" }`

## Decision log

See `docs/03-decision-log.md` D-progress-261.
