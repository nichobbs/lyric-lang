//! tests/aspect_weaving_tests.l — runtime weaving regression suite for the
//! Validation.Aspects templates.
//!
//! STATUS: staged but NOT registered in lyric.toml's [project.tests]. It is a
//! ready-to-wire regression test for #3543: aspect weaving is currently
//! non-functional for the C-mode @inline_template + `from`-instance pattern
//! these templates use (the `args.<field>` rewrite and config wiring do not
//! reach the woven body, so the short-circuit never fires). Once #3543 is
//! fixed, register this suite in lyric.toml and wire it into the
//! ecosystem-security-tests CI job.
//!
//! Unlike validation_tests.l (which exercises the combinators directly), this
//! module instantiates the cross-package `ValidateInput` aspect against a
//! handler and asserts that the woven handler short-circuits with `Err` when
//! the guarded `input` argument falls outside the configured length bounds —
//! and proceeds when it is in bounds. If weaving does not run, the
//! out-of-bounds cases reach the handler and return `Ok`, failing these
//! assertions (which is the current #3543 behaviour).
@test_module
package Validation.AspectWeavingTests

import Std.Core
import Std.Testing
import Validation
import Validation.Aspects

// Instantiate the cross-package ValidateInput template against any handler
// named `guarded*`. The aspect must reject inputs shorter than 3 or longer
// than 10 characters before the handler runs.
aspect InputGuard from Validation.Aspects.ValidateInput {
  matches: name like "guarded*"
  config {
    minLen: Int = 3
    maxLen: Int = 10
  }
}

// The guarded handler. Its return type must be Result[T, slice[ValidationError]]
// so the aspect's `Err(errors)` short-circuit composes.
pub func guardedEcho(input: in String): Result[String, slice[Validation.ValidationError]] {
  return Ok("handled:" + input)
}

test "ValidateInput aspect: valid input proceeds to the handler body" {
  match guardedEcho("hello") {
    case Ok(v) -> assertEqual(v, "handled:hello", "handler must run for in-bounds input")
    case Err(_) -> assertTrue(false, "valid input must not be short-circuited")
  }
}

test "ValidateInput aspect: too-short input short-circuits with Err" {
  match guardedEcho("ab") {
    case Ok(_) -> assertTrue(false, "too-short input must be rejected before the handler")
    case Err(errs) -> assertTrue(errs.length > 0, "short-circuit returns at least one validation error")
  }
}

test "ValidateInput aspect: too-long input short-circuits with Err" {
  match guardedEcho("this-is-way-too-long") {
    case Ok(_) -> assertTrue(false, "too-long input must be rejected before the handler")
    case Err(errs) -> assertTrue(errs.length > 0, "short-circuit returns at least one validation error")
  }
}
