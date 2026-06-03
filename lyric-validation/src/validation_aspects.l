// Validation.Aspects — pub aspect templates for input validation concerns.
//
// Two templates:
//
//   ValidateInput — C-mode (@inline_template): validates the `args.input`
//                   string parameter of a handler for minimum and maximum
//                   length before the handler runs.
//
//   ValidateEmail — C-mode (@inline_template): validates that `args.email`
//                   is a syntactically valid email address before the handler
//                   runs.
//
// Both templates short-circuit and return `Err([ValidationError])` when
// validation fails.  The handler's return type must therefore be
// `Result[T, [ValidationError]]` for these aspects to compose correctly.
//
// Typical consumer usage:
//
//   import Validation.Aspects
//
//   aspect InputGuard from Validation.Aspects.ValidateInput {
//     matches: name like "handle*"
//     config { minLen: Int = 1; maxLen: Int = 1000; field: String = "input" }
//   }
//
//   aspect EmailGuard from Validation.Aspects.ValidateEmail {
//     matches: name like "handleRegister*"
//     inside:  InputGuard
//   }
//
// See docs/26-aspects.md §18, docs/27-aspect-libraries.md.

@runtime_checked
package Validation.Aspects

import Std.Core
import Validation

// ─── ValidateInput ────────────────────────────────────────────────────────────

/// Validate the `input: String` parameter of a matched handler for minimum and
/// maximum length before the handler runs.
///
/// C-mode (@inline_template): body reads `args.input` from the concrete handler.
/// Apply only to handlers that declare a parameter named `input: String`.
///
/// When validation fails, the aspect short-circuits and returns
/// `Err(errors)` without calling the handler.  The handler's return type must
/// be `Result[T, [ValidationError]]` for this to compose correctly.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled Bool   — master switch (default: true)
///   field   String — field name used in error messages (default: "input")
///   minLen  Int    — minimum allowed length, inclusive (default: 0)
///   maxLen  Int    — maximum allowed length, inclusive (default: 65536)
@stable(since="0.1")
@inline_template
pub aspect ValidateInput {
  config {
    enabled: Bool   = true
    field:   String = "input"
    minLen:  Int    = 0
    maxLen:  Int    = 65536
  }

  requires:
    args.input != ""    // handler must declare an input: String parameter

  // The handler's return type must be Result[T, [ValidationError]] for the
  // short-circuit Err path to type-check correctly at the call site.
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val errors = Validation.all([
        Validation.minLength(args.input, field, minLen),
        Validation.maxLength(args.input, field, maxLen),
      ])
      if Validation.isValid(errors) {
        ret = call.proceed()
      } else {
        ret = Err(errors)
      }
    }
  }
}

// ─── ValidateEmail ────────────────────────────────────────────────────────────

/// Validate that the `email: String` parameter of a matched handler is a
/// syntactically valid email address before the handler runs.
///
/// C-mode (@inline_template): body reads `args.email` from the concrete handler.
/// Apply only to handlers that declare a parameter named `email: String`.
///
/// When validation fails, the aspect short-circuits and returns
/// `Err(errors)` without calling the handler.  The handler's return type must
/// be `Result[T, [ValidationError]]` for this to compose correctly.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled Bool — master switch (default: true)
@stable(since="0.1")
@inline_template
pub aspect ValidateEmail {
  config {
    enabled: Bool = true
  }

  requires:
    args.email != ""    // handler must declare an email: String parameter

  // The handler's return type must be Result[T, [ValidationError]] for the
  // short-circuit Err path to type-check correctly at the call site.
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val errors = Validation.email(args.email, "email")
      if Validation.isValid(errors) {
        ret = call.proceed()
      } else {
        ret = Err(errors)
      }
    }
  }
}
