//! verifier/vcgen_contracts.l — contract-call cycle detection, diagnostics de-duplication.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// The names of the functions on a cycle of the contract-call graph: an edge
// runs from a function to every function its `requires:`/`ensures:` (and,
// for a `@pure` function, its body, which a call unfolds) calls, matched by
// last name segment so a method or qualified call is never missed.  A
// cycle — a function reaching itself, directly or through others — is what
// unfolding contracts at calls cannot settle (#8102).
func contractCycles(
  env: in VEnv,
  decls: in List[FunctionDecl],
  recordNames: in List[String],
  recordDefaults: in Map[String, List[Option[Expr]]],
): List[String] {
  // Nodes: the functions, then the records (whose field defaults a
  // constructor call translates).  A record is named by itself, as its
  // constructor's call is.
  val nodeNames: List[String] = newList()
  val nodeCalls: List[List[String]] = newList()
  var i = 0
  while i < decls.count {
    val eff = emptyEffects()
    val d = decls[i]
    var ci = 0
    while ci < d.contracts.count {
      match d.contracts[ci] {
        case CCRequires(x, _) -> effExpr(env, x, false, eff)
        case CCEnsures(x, _) -> effExpr(env, x, false, eff)
        case _ -> ()
      }
      ci = ci + 1
    }
    // A call translates the defaults of the parameters it omits.
    var pi = 0
    while pi < d.params.count {
      match d.params[pi].dflt {
        case Some(x) -> effExpr(env, x, false, eff)
        case None -> ()
      }
      pi = pi + 1
    }
    if isPure(d) {
      match d.body {
        case Some(b) -> match b {
          case FBExpr(x) -> effExpr(env, x, false, eff)
          case FBBlock(blk) -> effBlock(env, blk, false, eff)
        }
        case None -> ()
      }
    }
    nodeNames.add(d.name)
    nodeCalls.add(eff.calls)
    i = i + 1
  }
  i = 0
  while i < recordNames.count {
    val eff = emptyEffects()
    match mapGet(recordDefaults, recordNames[i]) {
      case Some(ds) -> {
        var di = 0
        while di < ds.count {
          match ds[di] {
            case Some(x) -> effExpr(env, x, false, eff)
            case None -> ()
          }
          di = di + 1
        }
      }
      case None -> ()
    }
    nodeNames.add(recordNames[i])
    nodeCalls.add(eff.calls)
    i = i + 1
  }
  val succs: List[List[Int]] = newList()
  i = 0
  while i < nodeNames.count {
    val targets: List[Int] = newList()
    var j = 0
    while j < nodeNames.count {
      if nodeCalls[i].contains(nameLeaf(nodeNames[j])) {
        targets.add(j)
      }
      j = j + 1
    }
    succs.add(targets)
    i = i + 1
  }
  val cyclic: List[String] = newList()
  i = 0
  while i < decls.count {
    if reachesItself(succs, i) {
      addName(cyclic, decls[i].name)
    }
    i = i + 1
  }
  cyclic
}

// The part of a function name after its last `.` or `::`.
func nameLeaf(name: in String): String {
  var start = 0
  var k = 0
  while k < name.length {
    val ch = name.substring(k, 1)
    if ch == "." or ch == ":" {
      start = k + 1
    }
    k = k + 1
  }
  name.substring(start, name.length - start)
}

func reachesItself(succs: in List[List[Int]], start: in Int): Bool {
  val seen: List[Int] = newList()
  val todo: List[Int] = newList()
  var k = 0
  while k < succs[start].count {
    todo.add(succs[start][k])
    k = k + 1
  }
  var t = 0
  while t < todo.count {
    val n = todo[t]
    if n == start {
      return true
    }
    if not seen.contains(n) {
      seen.add(n)
      var m = 0
      while m < succs[n].count {
        todo.add(succs[n][m])
        m = m + 1
      }
    }
    t = t + 1
  }
  false
}

// Drop a diagnostic identical (code, message and span) to an earlier one: an
// expression translated more than once — a callee contract at each call, a
// loop condition before and after the havoc — reports its construct once.
func dedupeDiagnostics(diags: in List[Diagnostic]): List[Diagnostic] {
  val seen: Map[String, Bool] = newMap()
  val kept: List[Diagnostic] = newList()
  var i = 0
  while i < diags.count {
    val d = diags[i]
    val key = d.code + "@" + spanKey(d.span) + ":" + d.message
    if not seen.containsKey(key) {
      seen.add(key, true)
      kept.add(d)
    }
    i = i + 1
  }
  kept
}

