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

func main(): Int {
  let value = violatesContract()
  println("Contract-gating test: value = {value}")

  if value == 50 {
    println("OK: Function executed successfully with aspect-composed ensures disabled")
    0
  } else {
    println("FAIL: Unexpected value")
    1
  }
}
