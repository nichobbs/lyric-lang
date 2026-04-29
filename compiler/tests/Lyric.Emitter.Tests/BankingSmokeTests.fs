/// E17 — banking-example smoke. The full worked-example banking
/// program (docs/02-worked-examples.md §1) leans on several Phase-1-
/// deferred features (opaque + @projectable, distinct/range types
/// with derived operators, multi-package imports, axiom-style FFI
/// for `Guid`/`Time.Instant`, full proof obligations). Instead of
/// pinning a literal compile of that file, M1.4's exit criterion is
/// a *curated banking-like program* that exercises every M1.4
/// emitter feature in concert: variant unions (E11), interfaces
/// + dispatch (E12), erasure-based generics (E13), async + await
/// blocking shim (E14), and @runtime_checked contracts (E15) —
/// plus the M1.3 base of records, control flow, and pattern
/// matching.
///
/// The full lowering's gaps land in Phase 2 / Phase 4 per D035.
module Lyric.Emitter.Tests.BankingSmokeTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private bankingProgram = """
package Banking

union AccountResult {
  case Ok(value: Int)
  case Err(code: Int)
}

union MaybeBalance {
  case Some(amount: Int)
  case None
}

record Account { id: Int, balance: Int }

interface AccountRepo {
  async func findBalance(id: in Int): MaybeBalance
}

record InMemoryRepo { sentinel: Int }

impl AccountRepo for InMemoryRepo {
  async func findBalance(id: in Int): MaybeBalance {
    if id == 1 then Some(amount = 100)
    else if id == 2 then Some(amount = 50)
    else None
  }
}

async func transfer(
  repo: in AccountRepo,
  fromId: in Int,
  toId: in Int,
  amount: in Int
): AccountResult
  requires: fromId != toId
  requires: amount > 0
{
  match await repo.findBalance(fromId) {
    case None -> Err(code = 404)
    case Some(bal) ->
      if bal < amount then Err(code = 1)
      else Ok(value = bal - amount)
  }
}

func describe(r: in AccountResult): String {
  match r {
    case Ok(v)  -> "ok"
    case Err(c) -> "err"
  }
}

func main(): Unit {
  val repo = InMemoryRepo(sentinel = 0)

  // Sufficient funds: account 1 has 100, transferring 60 is fine.
  val r1 = await transfer(repo, 1, 2, 60)
  println(describe(r1))

  // Insufficient: account 2 has 50, can't transfer 200.
  val r2 = await transfer(repo, 2, 1, 200)
  println(describe(r2))

  // Account not found: id 99 returns None.
  val r3 = await transfer(repo, 99, 1, 10)
  println(describe(r3))
}
"""

let tests =
    testSequenced
    <| testList "banking-example smoke (E17)" [

        testCase "[banking_curated]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "Banking" bankingProgram
            Expect.equal exitCode 0
                (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "ok\nerr\nerr"
                "stdout matches expected ok/err/err sequence"
    ]
