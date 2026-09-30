//! contracts-gating-test/src/main.l
//! Tests that aspect-composed requires:/ensures: clauses are gated by [contracts] enabled = false.
//!
//! This program is compiled with [contracts] enabled = false in lyric.toml.
//! It applies an aspect with an ensures: clause that would fail at runtime if enforced.
//! The function returns a value that violates the ensures contract.
//!
//! When contracts are disabled, the function executes without assertion failure.
//! This verifies that aspect-composed contracts are properly gated by the [contracts] manifest setting.
package contracts_gating_test

import Std.String

aspect ContractViolationAspect {
  matches: name in { violatesContract }
  ensures: result >= 100
  around(call) -> ret {
    ret = call.proceed()
  }
}

func violatesContract(): Int {
  50
}

// `Std.String.indexOfFrom` declares `requires: from <= s.length`. The consuming
// project's `[contracts] enabled = false` must not strip the stdlib's own
// contract, so this call still has to panic (#7748).
func stdlibContractStillEnforced(): Bool {
  try {
    val _ = indexOfFrom("abc", "b", 10)
    false
  } catch Bug as _ {
    true
  }
}

func main(): Int {
  let value = violatesContract()
  println("Contract-gating test: value = {value}")

  if value == 50 {
    println("OK: Function executed successfully with aspect-composed ensures disabled")
    if stdlibContractStillEnforced() {
      println("OK: stdlib requires: still enforced with [contracts] enabled = false")
      0
    } else {
      println("FAIL: stdlib contract was stripped by [contracts] enabled = false")
      1
    }
  } else {
    println("FAIL: Unexpected value")
    1
  }
}
