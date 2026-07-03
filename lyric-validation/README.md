# lyric-validation

Declarative input validation that produces user-facing error messages.

## Packages

| Package | Purpose |
|---|---|
| `Validation` | Core types, validator combinators, and public API |
| `Validation.Aspects` | Reusable aspect templates: `ValidateInput` and `ValidateEmail` |

## Quick start

```lyric
import Validation

// Define individual validators
val required = Validation.required("username is required")
val minLen = Validation.minLength(3, "must be at least 3 chars")
val maxLen = Validation.maxLength(50, "must not exceed 50 chars")

// Combine them
val usernameValidator = Validation.combine([required, minLen, maxLen])

// Validate input
val username = "ab"
match Validation.toResult(username, usernameValidator) {
  case Ok(value)  -> println("valid: " + value)
  case Err(error) -> println("error: " + error.message)
}
```

## Validator interface

Validators are composable predicates that produce `ValidationError` messages:

```lyric
pub interface Validator[T] {
  func validate(value: in T): Option[ValidationError]
}
```

Use combinator functions to build complex validators from simple ones.
All validators are immutable and reusable.

## Core validators

```lyric
Validation.required(message)           // Rejects empty/null
Validation.minLength(n, message)       // String length >= n
Validation.maxLength(n, message)       // String length <= n
Validation.exactLength(n, message)     // String length == n
Validation.notBlank(message)           // Rejects whitespace-only strings
Validation.email(message)              // Email format (RFC 5322 subset)
Validation.url(message)                // URL format validation
Validation.oneOf(choices, message)     // String in allowed set
Validation.minValue(n, message)        // Numeric >= n
Validation.maxValue(n, message)        // Numeric <= n
Validation.rangeValue(min, max, msg)   // Numeric in [min, max]
```

## Composition

```lyric
Validation.combine(validators)         // All validators must pass
Validation.all(values, validator)      // Apply validator to each item
Validation.toResult(value, validator)  // Result[T, ValidationError]
Validation.isValid(value, validator)   // Bool
```

## API reference

```lyric
Validation.required(message)           // Validator[String]
Validation.minLength(n, message)       // Validator[String]
Validation.maxLength(n, message)       // Validator[String]
Validation.exactLength(n, message)     // Validator[String]
Validation.notBlank(message)           // Validator[String]
Validation.email(message)              // Validator[String]
Validation.url(message)                // Validator[String]
Validation.oneOf(choices, message)     // Validator[String]
Validation.minValue(n, message)        // Validator[Int/Long]
Validation.maxValue(n, message)        // Validator[Int/Long]
Validation.rangeValue(min, max, msg)   // Validator[Int/Long]
Validation.combine(validators)         // Validator[T]
Validation.all(values, validator)      // Option[ValidationError]
Validation.toResult(value, validator)  // Result[T, ValidationError]
Validation.isValid(value, validator)   // Bool
```

## Aspect templates (`Validation.Aspects`)

### ValidateInput

Row-constrained B'-mode (docs/56): validates the `input: String` parameter of a matched handler.

```lyric
import Validation.Aspects

aspect UserInput from Validation.Aspects.ValidateInput {
  matches: name like "create*"
  config { mode: String = "error" }
}

// Handler receives validated parameters
func createUser(username: in String, email: in String): Result[User, String] { ... }
```

Validator specs are declared via `@validate` annotations on parameters.
If validation fails, the handler is not invoked and an error is returned.

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `mode` | `String` | `"error"` | `"error"` rejects, `"warn"` logs |

### ValidateEmail

Row-constrained B'-mode (docs/56): validates the `email: String` parameter of a matched handler.

```lyric
aspect EmailValidation from Validation.Aspects.ValidateEmail {
  matches: name like "*email*"
  config { checkDomainMx: Bool = false }
}

func setEmail(address: in String, cacheKey: in String): Result[Unit, String] { ... }
```

Config fields (env prefix `LYRIC_ASPECT_<INSTANTIATION>_`):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | `Bool` | `true` | Master switch |
| `checkDomainMx` | `Bool` | `false` | Perform DNS MX record lookup |

## Decision log

See `docs/03-decision-log.md` D061 and `docs/10-bootstrap-progress.md`.
