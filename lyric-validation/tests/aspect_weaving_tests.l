//! tests/aspect_weaving_tests.l — runtime weaving regression suite covering
//! the three aspect-instantiation forms the ecosystem relies on (#3543):
//!
//!   1. cross-package `from Lib.Aspects.Template` instantiation,
//!   2. same-package unqualified `from Template` instantiation,
//!   3. a direct `@inline_template` aspect (matches + around in one).
//!
//! Each asserts that the woven handler actually short-circuits with `Err`
//! when the guarded `input` argument is out of bounds and proceeds when it
//! is valid. If weaving regresses (config not wired, `args.<field>` not
//! rewritten, `from` template not resolved), the out-of-bounds cases reach
//! the handler and return `Ok`, failing these assertions.
@test_module
package Validation.AspectWeavingTests

import Std.Core
import Std.Testing
import Validation
import Validation.Aspects

// ── Form 1: cross-package `from Validation.Aspects.ValidateInput` ────────────
// The instance overrides only minLen/maxLen; `enabled`/`field` fall back to
// the template's config defaults (exercises the config-merge path).
aspect InputGuard from Validation.Aspects.ValidateInput {
  matches: name like "guarded*"
  config {
    minLen: Int = 3
    maxLen: Int = 10
  }
}

pub func guardedEcho(input: in String): Result[String, slice[Validation.ValidationError]] {
  return Ok("handled:" + input)
}

test "cross-package from: valid input proceeds to the handler body" {
  match guardedEcho("hello") {
    case Ok(v) -> assertEqual(v, "handled:hello", "handler must run for in-bounds input")
    case Err(_) -> assertTrue(false, "valid input must not be short-circuited")
  }
}

test "cross-package from: too-short input short-circuits with Err" {
  match guardedEcho("ab") {
    case Ok(_) -> assertTrue(false, "too-short input must be rejected before the handler")
    case Err(errs) -> assertTrue(errs.length > 0, "short-circuit returns at least one validation error")
  }
}

test "cross-package from: too-long input short-circuits with Err" {
  match guardedEcho("this-is-way-too-long") {
    case Ok(_) -> assertTrue(false, "too-long input must be rejected before the handler")
    case Err(errs) -> assertTrue(errs.length > 0, "short-circuit returns at least one validation error")
  }
}

// ── Form 2: same-package unqualified `from LenTemplate` ──────────────────────
// `enabled` is left to the template default (true), `minLen` is overridden,
// and `args.input` is read C-mode — all under the bare-config spelling.
@inline_template
pub aspect LenTemplate {
  config {
    minLen: Int = 0
    enabled: Bool = true
  }
  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      if args.input.length < minLen {
        ret = Err("too-short")
      } else {
        ret = call.proceed()
      }
    }
  }
}

aspect LocalLenGuard from LenTemplate {
  matches: name like "localGuarded*"
  config {
    minLen: Int = 4
  }
}

pub func localGuardedEcho(input: in String): Result[String, String] {
  return Ok("handled:" + input)
}

test "same-package unqualified from: too-short short-circuits, valid proceeds" {
  match localGuardedEcho("abc") {
    case Ok(_) -> assertTrue(false, "len 3 < minLen 4 must be rejected")
    case Err(e) -> assertEqual(e, "too-short", "short-circuit error propagated")
  }
  match localGuardedEcho("abcd") {
    case Ok(v) -> assertEqual(v, "handled:abcd", "len 4 >= minLen 4 proceeds")
    case Err(_) -> assertTrue(false, "valid input must not be short-circuited")
  }
}

// ── Form 3: direct `@inline_template` aspect (matches + around in one) ────────
@inline_template
aspect DirectLenGuard {
  matches: name like "directGuarded*"
  config {
    minLen: Int = 5
  }
  around(call) -> ret {
    if args.input.length < minLen {
      ret = Err("too-short")
    } else {
      ret = call.proceed()
    }
  }
}

pub func directGuardedEcho(input: in String): Result[String, String] {
  return Ok("handled:" + input)
}

test "direct inline_template aspect: too-short short-circuits, valid proceeds" {
  match directGuardedEcho("1234") {
    case Ok(_) -> assertTrue(false, "len 4 < minLen 5 must be rejected")
    case Err(e) -> assertEqual(e, "too-short", "short-circuit error propagated")
  }
  match directGuardedEcho("12345") {
    case Ok(v) -> assertEqual(v, "handled:12345", "len 5 >= minLen 5 proceeds")
    case Err(_) -> assertTrue(false, "valid input must not be short-circuited")
  }
}

// ── Form 4: C-mode `from`-template that reads args but never references call ──
// Regression for #3592: C-mode detection must key on the literal `args`
// keyword, not the `around(<name>)` binding. This template reads `args.input`
// and proceeds via bare `proceed(...)` with no `call.*` reference at all, so a
// detector keyed on the `call` binding would misclassify it as non-C-mode,
// skip the `args.<field>` rewrite, and regress the #3543 NullReferenceException.
@inline_template
pub aspect NoCallTemplate {
  config {
    minLen: Int = 0
  }
  around(call) -> ret {
    if args.input.length < minLen {
      ret = Err("too-short")
    } else {
      ret = proceed(args)
    }
  }
}

aspect NoCallGuard from NoCallTemplate {
  matches: name like "noCallGuarded*"
  config {
    minLen: Int = 4
  }
}

pub func noCallGuardedEcho(input: in String): Result[String, String] {
  return Ok("handled:" + input)
}

test "C-mode from-template without a call reference still weaves args (#3592)" {
  match noCallGuardedEcho("ab") {
    case Ok(_) -> assertTrue(false, "len 2 < minLen 4 must be rejected")
    case Err(e) -> assertEqual(e, "too-short", "short-circuit error propagated")
  }
  match noCallGuardedEcho("abcd") {
    case Ok(v) -> assertEqual(v, "handled:abcd", "len 4 >= minLen 4 proceeds")
    case Err(_) -> assertTrue(false, "valid input must not be short-circuited")
  }
}
