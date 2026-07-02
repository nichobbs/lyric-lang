//! weaver_self_test.l — exercises the self-hosted `Lyric.Weaver`
//! library.  Runs automatically in CI via native `lyric test`:
//!
//!   lyric test lyric-compiler/lyric/weaver_self_test.l
//!
//! The compiler-package imports (`Lyric.Lexer`, `Lyric.Parser`,
//! `Lyric.Weaver`) are resolved by LINKING the already-compiled stage-1
//! bundle DLLs as restored dependencies (#2364), so the test's imports
//! resolve without recompiling them from source (the former
//! `LYRIC_LOAD_COMPILER=1` path) and without a subprocess hop.  Resolves
//! issue #1324.
//!
//! Covers the three todo/06 features that land in weaver.l:
//!
//!   - #683: `config { }` block values become synthetic
//!           `val __aspect_cfg_<name>` locals at the top of the woven
//!           body; `config.<name>` references rewrite to those locals.
//!
//!   - #682: the woven body carries `__lyric_call_<name>` locals for
//!           the compile-time-known fields (shortName, qualifiedName,
//!           modulePath, sourceLocation, annotations, aspect); the
//!           prelude is lazy — only fields the body references are
//!           emitted; `call.<name>` member access rewrites to those
//!           locals; unknown fields surface as A0043 weave-time
//!           diagnostics.
//!
//!   - #681: aspects marked `@inline_template` have `args.<field>`
//!           rewritten to bare `<field>` paths at weave time; field
//!           names that don't match a parameter accumulate as A0042
//!           diagnostics.
@test_module
package Lyric.WeaverSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.Weaver

// ─────────────────────────────────────────────────────────────────────────────
// Helpers — parse + weave + shape inspection.
// ─────────────────────────────────────────────────────────────────────────────
func parseWeave(src: in String): SourceFile {
  val pr = parse(src)
  weaveFile(pr.file)
}

func parseWeaveDiags(src: in String): WeaveFileResult {
  val pr = parse(src)
  weaveFileWithDiags(pr.file)
}

func firstFunction(file: in SourceFile, name: in String): FunctionDecl {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        if fn.name == name {
          return fn
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstFunction: no function named '" + name + "'")
}

func functionBody(fn: in FunctionDecl): Block {
  match fn.body {
    case Some(b) -> {
      match b {
        case FBBlock(blk) -> blk
        case FBExpr(_) -> panic("functionBody: '" + fn.name + "' has FBExpr body")
      }
    }
    case None -> panic("functionBody: '" + fn.name + "' has no body")
  }
}

/// Find the `SLocal(LBVal)` statement that binds `name` and return
/// its `init` expression.  Panics if there is no such statement.
func findValInit(blk: in Block, name: in String): Expr {
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SLocal(b) -> {
        match b {
          case LBVal(pat, _, init) -> {
            match pat.kind {
              case PBinding(n, _) -> if n == name { return init }
              case _ -> ()
            }
          }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  panic("findValInit: no local named '" + name + "'")
}

func findValTy(blk: in Block, name: in String): Option[TypeExpr] {
  var i = 0
  while i < blk.statements.count {
    match blk.statements[i].kind {
      case SLocal(b) -> {
        match b {
          case LBVal(pat, ty, _) -> {
            match pat.kind {
              case PBinding(n, _) -> if n == name { return ty }
              case _ -> ()
            }
          }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  panic("findValTy: no local named '" + name + "'")
}

func isValBinding(s: in Statement, name: in String): Bool {
  match s.kind {
    case SLocal(b) -> {
      match b {
        case LBVal(pat, _, _) -> {
          match pat.kind {
            case PBinding(n, _) -> n == name
            case _ -> false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

func isVarBinding(s: in Statement, name: in String): Bool {
  match s.kind {
    case SLocal(b) -> {
      match b {
        case LBVar(n, _, _) -> n == name
        case _ -> false
      }
    }
    case _ -> false
  }
}

/// True iff the block (transitively) defines a local binding (val/let/var)
/// whose binding name equals `name`.  Used to confirm that a woven body
/// contains an injected `val __before = 1`-style statement.
func bodyDefinesLocal(blk: in Block, name: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if isValBinding(blk.statements[i], name) or isVarBinding(blk.statements[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

/// First `IFunc` item whose name starts with `prefix`. Panics if none.
func firstFunctionWithPrefix(file: in SourceFile, prefix: in String): FunctionDecl {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        if Str.startsWith(fn.name, prefix) {
          return fn
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstFunctionWithPrefix: no function with prefix '" + prefix + "'")
}

/// Count `IFunc` items whose name starts with `prefix` — used to assert
/// B'-mode dedup (docs/55): two matched functions sharing a shape should
/// produce exactly one `__lyric_bmode_<template>__<shape>`-named
/// specialised function, not one per match.
func countFunctionsWithPrefix(file: in SourceFile, prefix: in String): Int {
  var n = 0
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        if Str.startsWith(fn.name, prefix) {
          n = n + 1
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

// Count `import <seg0>.<seg1>` entries in the file's import list.
func importCount(file: in SourceFile, seg0: in String, seg1: in String): Int {
  var n = 0
  var i = 0
  while i < file.imports.count {
    val p = file.imports[i].path
    if p.segments.count == 2 and p.segments[0] == seg0 and p.segments[1] == seg1 {
      n = n + 1
    }
    i = i + 1
  }
  n
}

func literalIntValue(e: in Expr): Long {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _, _) -> v
        case _ -> panic("literalIntValue: not an Int literal")
      }
    }
    case _ -> panic("literalIntValue: not a literal")
  }
}

func literalStringValue(e: in Expr): String {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LString(s) -> s
        case LTripleString(s) -> s
        case LRawString(s) -> s
        case _ -> panic("literalStringValue: not a String literal")
      }
    }
    case _ -> panic("literalStringValue: not a literal")
  }
}

/// True iff the body (transitively) contains a bare path expression
/// matching `name`.  Used to assert that `config.<x>` was rewritten
/// to `__aspect_cfg_<x>` somewhere in the rewritten body.
func bodyMentionsPath(blk: in Block, name: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtMentionsPath(blk.statements[i], name) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtMentionsPath(s: in Statement, name: in String): Bool {
  match s.kind {
    case SExpr(e) -> exprMentionsPath(e, name)
    case SReturn(o) -> match o { case Some(e) -> exprMentionsPath(e, name); case None -> false }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> exprMentionsPath(init, name)
        case LBLet(_, _, init) -> exprMentionsPath(init, name)
        case LBVar(_, _, init) -> match init { case Some(e) -> exprMentionsPath(e, name); case None -> false }
      }
    }
    case SAssign(t, _, v) -> exprMentionsPath(t, name) or exprMentionsPath(v, name)
    case SThrow(e) -> exprMentionsPath(e, name)
    case SFor(_, _, iter, body) -> exprMentionsPath(iter, name) or bodyMentionsPath(body, name)
    case SWhile(_, cond, body) -> exprMentionsPath(cond, name) or bodyMentionsPath(body, name)
    case SLoop(_, body) -> bodyMentionsPath(body, name)
    case SScope(_, body) -> bodyMentionsPath(body, name)
    case SDefer(body) -> bodyMentionsPath(body, name)
    case STry(body, catches, finally_) -> {
      if bodyMentionsPath(body, name) {
        return true
      }
      var i = 0
      while i < catches.count {
        if bodyMentionsPath(catches[i].body, name) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> bodyMentionsPath(fb, name)
        case None -> false
      }
    }
    case _ -> false
  }
}

func exprMentionsPath(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p) -> p.segments.count == 1 and p.segments[0] == name
    case EParen(inner) -> exprMentionsPath(inner, name)
    case ECall(f, args) -> {
      if exprMentionsPath(f, name) {
        return true
      }
      var i = 0
      while i < args.count {
        val arg = args[i]
        val v = match arg { case CAPositional(v) -> v; case CANamed(_, v, _) -> v }
        if exprMentionsPath(v, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r) -> exprMentionsPath(l, name) or exprMentionsPath(r, name)
    case EPrefix(_, operand) -> exprMentionsPath(operand, name)
    case EMember(recv, _) -> exprMentionsPath(recv, name)
    case EIf(c, t, el, _) -> {
      if exprMentionsPath(c, name) {
        return true
      }
      if eobMentionsPath(t, name) {
        return true
      }
      match el {
        case Some(eb) -> eobMentionsPath(eb, name)
        case None -> false
      }
    }
    case EMatch(scrut, arms) -> {
      if exprMentionsPath(scrut, name) {
        return true
      }
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> if exprMentionsPath(g, name) { return true }
          case None -> ()
        }
        if eobMentionsPath(arms[i].body, name) {
          return true
        }
        i = i + 1
      }
      false
    }
    case ELambda(_, body) -> bodyMentionsPath(body, name)
    case EBlock(blk) -> bodyMentionsPath(blk, name)
    case EUnsafe(blk) -> bodyMentionsPath(blk, name)
    case ETuple(xs) -> {
      var i = 0
      while i < xs.count {
        if exprMentionsPath(xs[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EList(xs) -> {
      var i = 0
      while i < xs.count {
        if exprMentionsPath(xs[i], name) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EAwait(inner) -> exprMentionsPath(inner, name)
    case EYield(inner) -> exprMentionsPath(inner, name)
    case ESpawn(inner) -> exprMentionsPath(inner, name)
    case ETry(inner) -> exprMentionsPath(inner, name)
    case EPropagate(inner) -> exprMentionsPath(inner, name)
    case EAssign(t, _, v) -> exprMentionsPath(t, name) or exprMentionsPath(v, name)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(_, _) -> ()
          case ISExpr(inner) -> if exprMentionsPath(inner, name) { return true }
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobMentionsPath(eob: in ExprOrBlock, name: in String): Bool {
  match eob {
    case EOBExpr(e) -> exprMentionsPath(e, name)
    case EOBBlock(b) -> bodyMentionsPath(b, name)
  }
}

/// Count the timed-proceed blocks in a woven body.  `proceedSubstitutionTimed`
/// replaces each `proceed(args)` call with an `EBlock` whose first statement
/// is `val __lyric_call_start = monotonicNanos()`, so counting those blocks
/// counts the distinct proceed sites — and confirms each got its own
/// block-scoped start local (issue #3294).
func countTimedProceedBlocks(blk: in Block): Int {
  var n = 0
  var i = 0
  while i < blk.statements.count {
    n = n + countTimedProceedStmt(blk.statements[i])
    i = i + 1
  }
  n
}

func countTimedProceedStmt(s: in Statement): Int {
  match s.kind {
    case SExpr(e) -> countTimedProceedExpr(e)
    case SReturn(o) -> match o { case Some(e) -> countTimedProceedExpr(e); case None -> 0 }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> countTimedProceedExpr(init)
        case LBLet(_, _, init) -> countTimedProceedExpr(init)
        case LBVar(_, _, init) -> match init { case Some(e) -> countTimedProceedExpr(e); case None -> 0 }
      }
    }
    case SAssign(t, _, v) -> countTimedProceedExpr(t) + countTimedProceedExpr(v)
    case SThrow(e) -> countTimedProceedExpr(e)
    case SFor(_, _, iter, body) -> countTimedProceedExpr(iter) + countTimedProceedBlocks(body)
    case SWhile(_, cond, body) -> countTimedProceedExpr(cond) + countTimedProceedBlocks(body)
    case SLoop(_, body) -> countTimedProceedBlocks(body)
    case SScope(_, body) -> countTimedProceedBlocks(body)
    case SDefer(body) -> countTimedProceedBlocks(body)
    case STry(body, catches, finally_) -> {
      var n = countTimedProceedBlocks(body)
      var i = 0
      while i < catches.count {
        n = n + countTimedProceedBlocks(catches[i].body)
        i = i + 1
      }
      n + match finally_ { case Some(fb) -> countTimedProceedBlocks(fb); case None -> 0 }
    }
    case _ -> 0
  }
}

func countTimedProceedExpr(e: in Expr): Int {
  match e.kind {
    case EBlock(blk) -> {
      // A timed-proceed block opens with `val __lyric_call_start`; count it,
      // but still recurse so nested proceed sites are not missed.
      val here = if blk.statements.count > 0 and isValBinding(blk.statements[0], "__lyric_call_start") { 1 } else { 0 }
      here + countTimedProceedBlocks(blk)
    }
    case EParen(inner) -> countTimedProceedExpr(inner)
    case ECall(f, args) -> {
      var n = countTimedProceedExpr(f)
      var i = 0
      while i < args.count {
        val v = match args[i] { case CAPositional(v) -> v; case CANamed(_, v, _) -> v }
        n = n + countTimedProceedExpr(v)
        i = i + 1
      }
      n
    }
    case EBinop(_, l, r) -> countTimedProceedExpr(l) + countTimedProceedExpr(r)
    case EPrefix(_, operand) -> countTimedProceedExpr(operand)
    case EMember(recv, _) -> countTimedProceedExpr(recv)
    case EIf(c, t, el, _) -> {
      val base = countTimedProceedExpr(c) + countTimedProceedEob(t)
      base + match el { case Some(eb) -> countTimedProceedEob(eb); case None -> 0 }
    }
    case EMatch(scrut, arms) -> {
      var n = countTimedProceedExpr(scrut)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> {
            n = n + countTimedProceedExpr(g)
          }
          case None -> ()
        }
        n = n + countTimedProceedEob(arms[i].body)
        i = i + 1
      }
      n
    }
    case ELambda(_, body) -> countTimedProceedBlocks(body)
    case EUnsafe(blk) -> countTimedProceedBlocks(blk)
    case EAwait(inner) -> countTimedProceedExpr(inner)
    case EYield(inner) -> countTimedProceedExpr(inner)
    case ESpawn(inner) -> countTimedProceedExpr(inner)
    case ETry(inner) -> countTimedProceedExpr(inner)
    case EPropagate(inner) -> countTimedProceedExpr(inner)
    case EAssign(t, _, v) -> countTimedProceedExpr(t) + countTimedProceedExpr(v)
    case ETuple(xs) -> countTimedProceedExprList(xs)
    case EList(xs) -> countTimedProceedExprList(xs)
    case _ -> 0
  }
}

func countTimedProceedExprList(xs: in List[Expr]): Int {
  var n = 0
  var i = 0
  while i < xs.count {
    n = n + countTimedProceedExpr(xs[i])
    i = i + 1
  }
  n
}

func countTimedProceedEob(eob: in ExprOrBlock): Int {
  match eob {
    case EOBExpr(e) -> countTimedProceedExpr(e)
    case EOBBlock(b) -> countTimedProceedBlocks(b)
  }
}

/// True iff the body contains a member access `<recv>.<member>` with
/// `recv` a single-segment path matching `receiverName`.  Used to
/// assert that the rewriter DID NOT leave a stray `config.maxRetries`
/// in place after rewriting.
func bodyHasMemberAccess(blk: in Block, receiverName: in String, memberName: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtHasMemberAccess(blk.statements[i], receiverName, memberName) {
      return true
    }
    i = i + 1
  }
  false
}

func stmtHasMemberAccess(s: in Statement, recv: in String, mem: in String): Bool {
  match s.kind {
    case SExpr(e) -> exprHasMemberAccess(e, recv, mem)
    case SReturn(o) -> match o { case Some(e) -> exprHasMemberAccess(e, recv, mem); case None -> false }
    case SLocal(b) -> {
      match b {
        case LBVal(_, _, init) -> exprHasMemberAccess(init, recv, mem)
        case LBLet(_, _, init) -> exprHasMemberAccess(init, recv, mem)
        case LBVar(_, _, init) -> match init { case Some(e) -> exprHasMemberAccess(e, recv, mem); case None -> false }
      }
    }
    case SAssign(t, _, v) -> exprHasMemberAccess(t, recv, mem) or exprHasMemberAccess(v, recv, mem)
    case SThrow(e) -> exprHasMemberAccess(e, recv, mem)
    case SFor(_, _, iter, body) -> exprHasMemberAccess(iter, recv, mem) or blockHasMemberAccess(body, recv, mem)
    case SWhile(_, cond, body) -> exprHasMemberAccess(cond, recv, mem) or blockHasMemberAccess(body, recv, mem)
    case SLoop(_, body) -> blockHasMemberAccess(body, recv, mem)
    case SScope(_, body) -> blockHasMemberAccess(body, recv, mem)
    case SDefer(body) -> blockHasMemberAccess(body, recv, mem)
    case STry(body, catches, finally_) -> {
      if blockHasMemberAccess(body, recv, mem) {
        return true
      }
      var i = 0
      while i < catches.count {
        if blockHasMemberAccess(catches[i].body, recv, mem) {
          return true
        }
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> blockHasMemberAccess(fb, recv, mem)
        case None -> false
      }
    }
    case _ -> false
  }
}

func blockHasMemberAccess(blk: in Block, recv: in String, mem: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtHasMemberAccess(blk.statements[i], recv, mem) {
      return true
    }
    i = i + 1
  }
  false
}

func exprHasMemberAccess(e: in Expr, recv: in String, mem: in String): Bool {
  match e.kind {
    case EMember(r, m) -> {
      if m == mem {
        match r.kind {
          case EPath(p) -> if p.segments.count == 1 and p.segments[0] == recv { return true }
          case _ -> ()
        }
      }
      exprHasMemberAccess(r, recv, mem)
    }
    case EParen(inner) -> exprHasMemberAccess(inner, recv, mem)
    case ECall(f, args) -> {
      if exprHasMemberAccess(f, recv, mem) {
        return true
      }
      var i = 0
      while i < args.count {
        val arg = args[i]
        val v = match arg { case CAPositional(v) -> v; case CANamed(_, v, _) -> v }
        if exprHasMemberAccess(v, recv, mem) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r) -> exprHasMemberAccess(l, recv, mem) or exprHasMemberAccess(r, recv, mem)
    case EPrefix(_, operand) -> exprHasMemberAccess(operand, recv, mem)
    case EIf(c, t, el, _) -> {
      if exprHasMemberAccess(c, recv, mem) {
        return true
      }
      val tHit = match t {
        case EOBExpr(e2) -> exprHasMemberAccess(e2, recv, mem)
        case EOBBlock(b2) -> blockHasMemberAccess(b2, recv, mem)
      }
      if tHit {
        return true
      }
      match el {
        case Some(eb) -> match eb { case EOBExpr(e3) -> exprHasMemberAccess(e3, recv, mem); case EOBBlock(b3) -> blockHasMemberAccess(b3, recv, mem) }
        case None -> false
      }
    }
    case EMatch(scrut, arms) -> {
      if exprHasMemberAccess(scrut, recv, mem) {
        return true
      }
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> if exprHasMemberAccess(g, recv, mem) { return true }
          case None -> ()
        }
        val armHit = match arms[i].body {
          case EOBExpr(e4) -> exprHasMemberAccess(e4, recv, mem)
          case EOBBlock(b4) -> blockHasMemberAccess(b4, recv, mem)
        }
        if armHit {
          return true
        }
        i = i + 1
      }
      false
    }
    case ELambda(_, body) -> blockHasMemberAccess(body, recv, mem)
    case EBlock(blk) -> blockHasMemberAccess(blk, recv, mem)
    case EUnsafe(blk) -> blockHasMemberAccess(blk, recv, mem)
    case ETuple(xs) -> {
      var i = 0
      while i < xs.count {
        if exprHasMemberAccess(xs[i], recv, mem) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EList(xs) -> {
      var i = 0
      while i < xs.count {
        if exprHasMemberAccess(xs[i], recv, mem) {
          return true
        }
        i = i + 1
      }
      false
    }
    case EAwait(inner) -> exprHasMemberAccess(inner, recv, mem)
    case EYield(inner) -> exprHasMemberAccess(inner, recv, mem)
    case ESpawn(inner) -> exprHasMemberAccess(inner, recv, mem)
    case ETry(inner) -> exprHasMemberAccess(inner, recv, mem)
    case EPropagate(inner) -> exprHasMemberAccess(inner, recv, mem)
    case EAssign(t, _, v) -> exprHasMemberAccess(t, recv, mem) or exprHasMemberAccess(v, recv, mem)
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(_, _) -> ()
          case ISExpr(inner) -> if exprHasMemberAccess(inner, recv, mem) { return true }
        }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

// Count how many items in the file have name `name` (an `IFunc`).
// Used to assert the renamed __aspect_target and the wrapper are both
// present after a weave.
func functionCount(file: in SourceFile, name: in String): Int {
  var n = 0
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> if fn.name == name { n = n + 1 }
      case _ -> ()
    }
    i = i + 1
  }
  n
}

func diagsHaveCode(diags: in List[Diagnostic], code: in String): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

// #4621 — find the message of the first diagnostic with `code`, or "" if none.
func diagMessageForCode(diags: in List[Diagnostic], code: in String): String {
  var i = 0
  while i < diags.count {
    if diags[i].code == code {
      return diags[i].message
    }
    i = i + 1
  }
  ""
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Baseline: no aspects → identity (just IAspect items dropped).
// ─────────────────────────────────────────────────────────────────────────────
test "no-aspect file is identity-rewritten" {
  val src = "package P\nfunc f(): Int { 1 }\n"
  val woven = parseWeave(src)
  assertEqualInt(woven.items.count, 1, "items unchanged")
  val fn = firstFunction(woven, "f")
  val blk = functionBody(fn)
  assertEqualInt(blk.statements.count, 1, "body unchanged")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. #683 — `config { }` wiring.
// ─────────────────────────────────────────────────────────────────────────────
test "config { } prelude is injected at the top of the woven body" {
  val src = "package P\n" + "aspect Limit {\n" + "  config { maxRetries: Int = 3 }\n" + "  matches: name like \"f*\"\n" +
    "  around(args) -> ret {\n" +
    "    val r = config.maxRetries\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func foo(x: in Int): Int { x + 1 }\n"
  val woven = parseWeave(src)
  // Two IFuncs: `foo` (wrapper) and `foo__aspect_target` (renamed original).
  assertEqualInt(functionCount(woven, "foo"), 1, "one wrapper named 'foo'")
  assertEqualInt(functionCount(woven, "foo__aspect_target"), 1, "one renamed target")
  // Wrapper body must start with the config prelude.
  val wrapper = firstFunction(woven, "foo")
  val body = functionBody(wrapper)
  assertTrue(
    isValBinding(body.statements[0], "__aspect_cfg_maxRetries"),
    "first wrapper stmt is __aspect_cfg_maxRetries val"
  )
  val initExpr = findValInit(body, "__aspect_cfg_maxRetries")
  assertTrue(literalIntValue(initExpr) == 3i64, "default 3 captured")
}

test "config.<field> member access rewrites to __aspect_cfg_<field>" {
  val src = "package P\n" + "aspect Limit {\n" + "  config { maxRetries: Int = 5 }\n" + "  matches: name like \"bar\"\n" +
    "  around(args) -> ret {\n" +
    "    val limit = config.maxRetries\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func bar(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "bar")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "config", "maxRetries"), "config.maxRetries member access rewritten away")
  assertTrue(bodyMentionsPath(body, "__aspect_cfg_maxRetries"), "__aspect_cfg_maxRetries path present")
}

test "config prelude is omitted when the body never references config.<x>" {
  // Lazy injection mirroring the call prelude — a wrapper whose body
  // never touches config.* must not carry __aspect_cfg_* locals
  // (review #1307).
  val src = "package P\n" + "aspect Skip {\n" + "  config { unused: Int = 99 }\n" + "  matches: name like \"s\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func s(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "s")
  val body = functionBody(wrapper)
  var saw = false
  var i = 0
  while i < body.statements.count {
    if isValBinding(body.statements[i], "__aspect_cfg_unused") {
      saw = true
    }
    i = i + 1
  }
  assertTrue(not saw, "no __aspect_cfg_* prelude when body ignores config.*")
}

test "config fields without a default are skipped in the prelude" {
  val src = "package P\n" + "aspect Limit {\n" + "  config {\n" + "    withDefault:    Int = 7\n" +
    "    withoutDefault: Int\n" +
    "  }\n" +
    "  matches: name like \"q\"\n" +
    "  around(args) -> ret {\n" +
    "    val r = config.withDefault\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func q(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "q")
  val body = functionBody(wrapper)
  assertTrue(isValBinding(body.statements[0], "__aspect_cfg_withDefault"), "defaulted field materialised")
  var i = 0
  var saw = false
  while i < body.statements.count {
    if isValBinding(body.statements[i], "__aspect_cfg_withoutDefault") {
      saw = true
    }
    i = i + 1
  }
  assertTrue(not saw, "non-defaulted field has no prelude entry")
}

test "config.<no-default> reference emits A0044 weave diagnostic" {
  // Regression for review #1323: a body referencing
  // `config.<f>` where `<f>` is declared but has no default
  // previously fell through silently and surfaced as a confusing
  // "config not declared" type error downstream.  The weaver now
  // emits A0044 with a clear message naming the aspect, the
  // matched function, and the offending field, AND materialises
  // the prelude entry with a `panic(...)` stub so downstream
  // codegen sees a resolved reference (compilation halts on the
  // A0044 error before runtime reaches the panic).
  val src = "package P\n" + "aspect Limit {\n" + "  config { undefaulted: Int }\n" + "  matches: name like \"d\"\n" +
    "  around(args) -> ret {\n" +
    "    val v = config.undefaulted\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func d(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0044"), "A0044 emitted for config.<no-default>")
  // Verify the stub is wired so the body type-checks.
  val wrapper = firstFunction(wr.file, "d")
  val body = functionBody(wrapper)
  assertTrue(
    isValBinding(body.statements[0], "__aspect_cfg_undefaulted"),
    "no-default field materialised with stub prelude entry"
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. #682 — `call` ambient prelude.
// ─────────────────────────────────────────────────────────────────────────────
test "call prelude carries the compile-time-known string fields" {
  val src = "package MyApp.Handlers\n" + "aspect Trace {\n" + "  matches: name like \"handle*\"\n" +
    "  around(args) -> ret {\n" +
    "    val sn = call.shortName\n" +
    "    val qn = call.qualifiedName\n" +
    "    val mp = call.modulePath\n" +
    "    val asp = call.aspect\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func handleX(): Int { 1 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "handleX")
  val body = functionBody(wrapper)
  val sn = findValInit(body, "__lyric_call_shortName")
  assertEqual(literalStringValue(sn), "handleX", "shortName literal matches")
  val qn = findValInit(body, "__lyric_call_qualifiedName")
  assertEqual(literalStringValue(qn), "MyApp.Handlers.handleX", "qualifiedName combines packagePath + name")
  val mp = findValInit(body, "__lyric_call_modulePath")
  assertEqual(literalStringValue(mp), "MyApp.Handlers", "modulePath is packagePath")
  val asp = findValInit(body, "__lyric_call_aspect")
  assertEqual(literalStringValue(asp), "Trace", "aspect literal is the aspect name")
}

test "call.sourceLocation literal has <package>:<line> format" {
  // Review #1317: pin the `packagePath:line` format of
  // `__lyric_call_sourceLocation` so it can't silently drift to a
  // different shape.
  val src = "package My.Pkg\n" + "aspect Trace {\n" + "  matches: name like \"t\"\n" + "  around(args) -> ret {\n" +
    "    val s = call.sourceLocation\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func t(): Int { 1 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "t")
  val body = functionBody(wrapper)
  val sl = findValInit(body, "__lyric_call_sourceLocation")
  val sValue = literalStringValue(sl)
  // Expect format "My.Pkg:<some-positive-line>".  Inline-substring
  // check (no Std.String import needed) — first 7 chars must equal
  // "My.Pkg:" and the suffix must carry at least one digit.
  val prefix = "My.Pkg:"
  assertTrue(sValue.length > prefix.length, "sourceLocation carries a line-number suffix")
  var ok = true
  var k = 0
  while k < prefix.length and ok {
    if sValue[k] != prefix[k] {
      ok = false
    }
    k = k + 1
  }
  assertTrue(ok, "sourceLocation starts with the package path + ':'")
}

test "call.sourceLocation / qualifiedName use <unknown>/funcName when packagePath is empty" {
  // `weaveItems` (no SourceFile) and `weaveItemsWithDiags(items, "")`
  // pass an empty package path through to the prelude builder.  The
  // explicit else-branches in buildCallPrelude substitute
  // `qualifiedName = funcName` and `sourceLocation = "<unknown>:<line>"`.
  // These branches have no SourceFile-based coverage, so test them
  // by parsing the source, extracting the items, and calling
  // `weaveItemsWithDiags(items, "")` directly.
  val src = "package Will.Be.Ignored\n" + "aspect Trace {\n" + "  matches: name like \"orphan\"\n" +
    "  around(args) -> ret {\n" +
    "    val q = call.qualifiedName\n" +
    "    val s = call.sourceLocation\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func orphan(): Int { 1 }\n"
  val pr = parse(src)
  val wr = weaveItemsWithDiags(pr.file.items, "")
  // Find the wrapper by scanning the rewritten item list.
  var wrapper: Option[FunctionDecl] = None
  var i = 0
  while i < wr.items.count {
    match wr.items[i].kind {
      case IFunc(fn) -> if fn.name == "orphan" { wrapper = Some(value = fn) }
      case _ -> ()
    }
    i = i + 1
  }
  match wrapper {
    case Some(fn) -> {
      match fn.body {
        case Some(b) -> {
          match b {
            case FBBlock(blk) -> {
              val q = findValInit(blk, "__lyric_call_qualifiedName")
              assertEqual(literalStringValue(q), "orphan", "empty packagePath: qualifiedName falls back to funcName")
              val s = findValInit(blk, "__lyric_call_sourceLocation")
              val sValue = literalStringValue(s)
              val prefix = "<unknown>:"
              assertTrue(sValue.length > prefix.length, "empty packagePath: sourceLocation carries line suffix")
              var ok = true
              var k = 0
              while k < prefix.length and ok {
                if sValue[k] != prefix[k] {
                  ok = false
                }
                k = k + 1
              }
              assertTrue(ok, "empty packagePath: sourceLocation prefix is '<unknown>:'")
            }
            case _ -> panic("orphan wrapper body is not FBBlock")
          }
        }
        case None -> panic("orphan wrapper has no body")
      }
    }
    case None -> panic("orphan wrapper not found in weaved items")
  }
}

test "call.annotations is a string slice of the function's annotation short-names" {
  // Cover the `__lyric_call_annotations` path including the
  // slice[String] type annotation that handles the empty-list case
  // — without the annotation, `EList([])` would infer to whatever
  // shape the resolver picks for an empty list, which is not
  // necessarily `slice[String]`.  Pin both the init expression and
  // the declared type so a regression that drops either is caught.
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"a\"\n" + "  around(args) -> ret {\n" +
    "    val ann = call.annotations\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "@stable(since=\"0.1\")\n" +
    "@pure\n" +
    "func a(): Int { 1 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "a")
  val body = functionBody(wrapper)
  // (a) verify the init expr is `EList(["stable", "pure"])`
  val annInit = findValInit(body, "__lyric_call_annotations")
  match annInit.kind {
    case EList(items) -> {
      assertEqualInt(items.count, 2, "annotations: two literal entries")
      assertEqual(literalStringValue(items[0]), "stable", "annotations[0] = stable")
      assertEqual(literalStringValue(items[1]), "pure", "annotations[1] = pure")
    }
    case _ -> panic("annotations: expected EList init expression")
  }
  // (b) verify the val declaration carries an explicit
  // `slice[String]` type annotation — this is what keeps EList of
  // string literals type-compatible at the val boundary (esp. for
  // the empty-list case).
  val annTy = findValTy(body, "__lyric_call_annotations")
  match annTy {
    case Some(te) -> match te.kind { case TSlice(elem) -> match elem.kind { case TRef(mp) -> { assertEqualInt(mp.segments.count, 1, "slice element type is a single-segment ref"); assertEqual(mp.segments[0], "String", "slice element type is `String`") }; case _ -> panic("annotations: slice element is not a TRef") }; case _ -> panic("annotations: declared type is not a TSlice") }
    case None -> panic("annotations: val carries no explicit type annotation")
  }
}

test "call.<field> member access rewrites to __lyric_call_<field>" {
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"g\"\n" + "  around(args) -> ret {\n" +
    "    val sn = call.shortName\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "g")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "call", "shortName"), "call.shortName member access rewritten away")
  assertTrue(bodyMentionsPath(body, "__lyric_call_shortName"), "__lyric_call_shortName path present")
}

test "unknown call.<field> emits A0043 weave diagnostic" {
  // A genuinely-unknown field: the rewriter leaves the expression
  // intact AND emits A0043 so the user gets a weaver-targeted message
  // instead of a "call is undeclared" type error (review #1193).
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"g\"\n" + "  around(args) -> ret {\n" +
    "    val e = call.bogus\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  val wrapper = firstFunction(wr.file, "g")
  val body = functionBody(wrapper)
  assertTrue(bodyHasMemberAccess(body, "call", "bogus"), "call.bogus left intact in AST")
  assertTrue(diagsHaveCode(wr.diagnostics, "A0043"), "A0043 emitted for unknown call.bogus")
}

test "call.caller emits A0043 (caller-site capture unavailable)" {
  // `call.caller` is specified in docs/26 §4.3 as "when available";
  // the weaver has no caller-site capture, so it stays an A0043 —
  // distinct from `call.elapsed`, which IS wired (#1298).
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"g\"\n" + "  around(args) -> ret {\n" +
    "    val c = call.caller\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  val wrapper = firstFunction(wr.file, "g")
  val body = functionBody(wrapper)
  assertTrue(bodyHasMemberAccess(body, "call", "caller"), "call.caller left intact in AST")
  assertTrue(diagsHaveCode(wr.diagnostics, "A0043"), "A0043 emitted for call.caller")
}

test "call prelude is omitted when the body never references call.<x>" {
  // Lazy injection: a wrapper whose body never touches call.* must
  // not carry __lyric_call_* locals (review #1196 — header comment
  // promised byte-identical output for non-referencing aspects).
  val src = "package P\n" + "aspect Pure {\n" + "  matches: name like \"p\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func p(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "p")
  val body = functionBody(wrapper)
  var saw = false
  var i = 0
  while i < body.statements.count {
    if isValBinding(body.statements[i], "__lyric_call_shortName") {
      saw = true
    }
    i = i + 1
  }
  assertTrue(not saw, "no __lyric_call_* prelude when body ignores call.*")
}

test "duplicate call.<field> references don't crash the pre-scan" {
  // Regression for review #1296: `collectCallRefsExpr` previously
  // called `into.add(name, true)` without a `containsKey` guard, so
  // the second occurrence of `call.shortName` in a body threw an
  // ArgumentException from `Dictionary<K,V>.Add` during weave.
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"q\"\n" + "  around(args) -> ret {\n" +
    "    val a = call.shortName\n" +
    "    val b = call.shortName\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func q(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "q")
  val body = functionBody(wrapper)
  assertTrue(
    bodyMentionsPath(body, "__lyric_call_shortName"),
    "duplicate refs still rewrite + the prelude carries the local"
  )
}

test "repeated unknown call.<field> emits at most one A0043" {
  // Regression for review #1299: `tryMemberRewrite` previously
  // appended to argsErrors once per occurrence, so an aspect body
  // referencing the same unknown field twice produced two A0043
  // diagnostics.  (`call.caller` is the unknown field here —
  // `call.elapsed` no longer qualifies since #1298 wired it.)
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"r\"\n" + "  around(args) -> ret {\n" +
    "    val a = call.caller\n" +
    "    val b = call.caller\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func r(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  var count = 0
  var i = 0
  while i < wr.diagnostics.count {
    if wr.diagnostics[i].code == "A0043" {
      count = count + 1
    }
    i = i + 1
  }
  assertEqualInt(count, 1, "A0043 dedup: at most one diag per (kind, field)")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3.5. #1298 — `call.elapsed` runtime instrumentation.
// ─────────────────────────────────────────────────────────────────────────────
test "call.elapsed after proceed: prelude var + timed proceed, no A0043" {
  val src = "package P\n" + "aspect Timing {\n" + "  matches: name like \"t\"\n" + "  around(args) -> ret {\n" +
    "    val r = proceed(args)\n" +
    "    val e = call.elapsed\n" +
    "    r\n" +
    "  }\n" +
    "}\n" +
    "func t(): Int { 1 }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0043"), "no A0043 for wired call.elapsed")
  val wrapper = firstFunction(wr.file, "t")
  val body = functionBody(wrapper)
  assertTrue(isVarBinding(body.statements[0], "__lyric_call_elapsed"), "prelude starts with the elapsed var")
  assertTrue(not bodyHasMemberAccess(body, "call", "elapsed"), "call.elapsed member access rewritten away")
  assertTrue(bodyMentionsPath(body, "__lyric_call_elapsed"), "__lyric_call_elapsed path present")
  assertTrue(bodyMentionsPath(body, "__lyric_call_start"), "timed proceed captures __lyric_call_start")
  assertTrue(bodyMentionsPath(body, "__lyric_call_proceed_ret"), "timed proceed binds the target result")
  assertTrue(bodyMentionsPath(body, "monotonicNanos"), "timed proceed calls monotonicNanos")
}

test "call.elapsed with no proceed: var prelude only, no instrumentation" {
  // A body that never calls `proceed` still gets the prelude var (so
  // the rewritten reference resolves) but no start-capture — the var
  // stays None for the whole wrapper, per docs/26 §4.3.
  val src = "package P\n" + "aspect Replace {\n" + "  matches: name like \"n\"\n" + "  around(args) -> ret {\n" +
    "    val e = call.elapsed\n" +
    "    0\n" +
    "  }\n" +
    "}\n" +
    "func n(): Int { 1 }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0043"), "no A0043 for wired call.elapsed")
  val wrapper = firstFunction(wr.file, "n")
  val body = functionBody(wrapper)
  assertTrue(isVarBinding(body.statements[0], "__lyric_call_elapsed"), "prelude carries the elapsed var")
  assertTrue(not bodyMentionsPath(body, "__lyric_call_start"), "no start capture without a proceed call")
}

test "Unit-returning target: timed proceed skips the result binding" {
  val src = "package P\n" + "aspect Timing {\n" + "  matches: name like \"u\"\n" + "  around(args) -> ret {\n" +
    "    proceed(args)\n" +
    "    val e = call.elapsed\n" +
    "  }\n" +
    "}\n" +
    "func u(): Unit {\n  val x = 0\n}\n"
  val wr = parseWeaveDiags(src)
  val wrapper = firstFunction(wr.file, "u")
  val body = functionBody(wrapper)
  assertTrue(bodyMentionsPath(body, "__lyric_call_start"), "timed proceed still captures the start instant")
  assertTrue(not bodyMentionsPath(body, "__lyric_call_proceed_ret"), "no result binding for a Unit target")
}

test "two proceed calls in one around body: each gets its own timed block" {
  // A retry-shaped aspect that calls proceed twice.  Each proceed site is
  // independently substituted, so the woven body must contain two distinct
  // timed blocks (each opening with `val __lyric_call_start`).  Block scoping
  // keeps the two start locals from colliding, and the trailing
  // `__lyric_call_elapsed` assignment of the second block wins (#3294).
  val src = "package P\n" + "aspect Retry {\n" + "  matches: name like \"r\"\n" + "  around(args) -> ret {\n" +
    "    val first = proceed(args)\n" +
    "    val second = proceed(args)\n" +
    "    val e = call.elapsed\n" +
    "    second\n" +
    "  }\n" +
    "}\n" +
    "func r(): Int { 1 }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0043"), "no A0043 for wired call.elapsed")
  val wrapper = firstFunction(wr.file, "r")
  val body = functionBody(wrapper)
  assertEqualInt(countTimedProceedBlocks(body), 2, "two proceed sites yield two timed blocks")
  assertTrue(bodyMentionsPath(body, "__lyric_call_proceed_ret"), "each timed block binds the target result")
  assertTrue(bodyMentionsPath(body, "__lyric_call_elapsed"), "elapsed assignment reachable after both proceeds")
}

test "weaveFile auto-injects import Std.Time for call.elapsed" {
  val src = "package P\n" + "aspect Timing {\n" + "  matches: name like \"t\"\n" + "  around(args) -> ret {\n" +
    "    val r = proceed(args)\n" +
    "    val e = call.elapsed\n" +
    "    r\n" +
    "  }\n" +
    "}\n" +
    "func t(): Int { 1 }\n"
  val woven = parseWeave(src)
  assertEqualInt(importCount(woven, "Std", "Time"), 1, "import Std.Time injected once")
}

test "Std.Time auto-import is deduplicated when already present" {
  val src = "package P\n" + "import Std.Time\n" + "aspect Timing {\n" + "  matches: name like \"t\"\n" +
    "  around(args) -> ret {\n" +
    "    val r = proceed(args)\n" +
    "    val e = call.elapsed\n" +
    "    r\n" +
    "  }\n" +
    "}\n" +
    "func t(): Int { 1 }\n"
  val woven = parseWeave(src)
  assertEqualInt(importCount(woven, "Std", "Time"), 1, "no duplicate import Std.Time")
}

test "no Std.Time injection when no aspect references call.elapsed" {
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"t\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func t(): Int { 1 }\n"
  val woven = parseWeave(src)
  assertEqualInt(importCount(woven, "Std", "Time"), 0, "no import injected when elapsed unused")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3.6. #1298 — runtime coverage.  These aspects live in THIS test
// module, so when `lyric test` compiles the file the in-process bridge
// weaves them for real: the tests below execute the instrumented
// wrappers and observe `call.elapsed` at runtime.
// ─────────────────────────────────────────────────────────────────────────────
aspect ElapsedRuntimeProbe {
  matches: name like "elapsedTimedTarget"
  around(args) -> ret {
    val r = proceed(args)
    // Encode the observed elapsed value into the return so the test
    // can assert on it: None -> -1 (fails the >= base check),
    // Some(ms) -> base + ms.
    val ms = match call.elapsed { case Some(v) -> v; case None -> 0 - 1 }
    r + ms
  }
}

aspect ElapsedSkipProbe {
  matches: name like "elapsedSkipTarget"
  around(args) -> ret {
    // Never calls proceed: per docs/26 §4.3 call.elapsed must be None.
    match call.elapsed {
      case Some(_) -> 0 - 1
      case None -> 7
    }
  }
}

func elapsedTimedTarget(): Int {
  1000000
}

func elapsedSkipTarget(): Int {
  42
}

test "runtime: call.elapsed is Some(ms >= 0) after proceed" {
  val v = elapsedTimedTarget()
  // The >= 1000000 lower bound fully captures the correctness intent
  // (elapsed is non-negative after proceed). No upper bound: a tight
  // ceiling could spuriously fire on a stalled CI runner (#3288); the
  // job timeout catches genuinely runaway values.
  assertTrue(v >= 1000000, "call.elapsed must be Some(ms) with ms >= 0 after proceed")
}

test "runtime: skip aspect (no proceed) observes call.elapsed as None" {
  assertEqualInt(elapsedSkipTarget(), 7, "no-proceed wrapper takes the None arm")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. #681 — `@inline_template` args.<field> rewriting + A0042.
// ─────────────────────────────────────────────────────────────────────────────
test "@inline_template rewrites args.<param> to bare <param>" {
  val src = "package P\n" + "@inline_template\n" + "pub aspect Tap {\n" + "  matches: name like \"h\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0042"), "no A0042 for valid args.<param>")
  val wrapper = firstFunction(wr.file, "h")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "args", "x"), "args.x rewritten away")
  assertTrue(bodyMentionsPath(body, "x"), "bare path 'x' present after rewrite")
}

test "@inline_template emits A0042 for args.<missing>" {
  val src = "package P\n" + "@inline_template\n" + "pub aspect Tap {\n" + "  matches: name like \"h\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.unknownField\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0042"), "A0042 emitted for args.unknownField")
}

test "non-template aspects leave args.<field> alone" {
  // Without @inline_template, args.<field> must pass through unchanged
  // — no rewrite, no A0042 (parity with the F# weaver's contract).
  val src = "package P\n" + "aspect Tap {\n" + "  matches: name like \"h\"\n" + "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0042"), "no A0042 emitted")
  val wrapper = firstFunction(wr.file, "h")
  val body = functionBody(wrapper)
  assertTrue(bodyHasMemberAccess(body, "args", "x"), "args.x left intact")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. #3414 — cross-package aspect template resolution.
//
// `weaveFileWithDiagsAndTemplates` accepts a pre-built template map produced
// by calling `collectAspectTemplates` on the template-declaring package; a
// consumer aspect with `from = Some(...)` and no `around` body is resolved
// against the map and gains the template's `around` before weaving.
// ─────────────────────────────────────────────────────────────────────────────
func makeTemplates(src: in String, pkgName: in String): Map[String, CollectedTemplate] {
  val pr = parse(src)
  val dest: Map[String, CollectedTemplate] = newMap()
  collectAspectTemplates(pr.file.items, pkgName, dest)
  dest
}

func weaveWithTemplates(consumeSrc: in String, templates: in Map[String, CollectedTemplate]): WeaveFileResult {
  val pr = parse(consumeSrc)
  weaveFileWithDiagsAndTemplates(pr.file, templates)
}

test "collectAspectTemplates collects pub aspect with around" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  assertTrue(templates.containsKey("Lib.Tap.Tap"), "Lib.Tap.Tap in templates")
}

test "collectAspectTemplates skips private aspect with around" {
  val tplSrc = "package Lib.Tap\n" + "aspect Tap {\n" + "  matches: name like \"*\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  assertTrue(not templates.containsKey("Lib.Tap.Tap"), "private aspect not collected")
}

test "collectAspectTemplates skips aspect with no around (consumer instance)" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap from Other.Tpl {\n" + "  matches: name like \"*\"\n" + "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  assertTrue(not templates.containsKey("Lib.Tap.Tap"), "from-instance not collected as template")
}

// `Tap`'s body never reads `args.<field>` — a B'-mode candidate (docs/55
// §3.2) — so a resolved `from`-instance routes through the shared
// specialisation path (Phase 2) rather than inlining the body directly
// into `doWork`'s wrapper the way C-mode does.  The `__before` local now
// lives in the specialised function, not in `doWork`'s own thin wrapper.
test "from-instance aspect (B'-mode) is resolved to a shared specialised function" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" + "  around(args) -> ret {\n" +
    "    val __before = 1\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"doWork\"\n" + "}\n" +
    "func doWork(x: in Int): Int { x }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  val wrapper = firstFunction(wr.file, "doWork")
  val wrapperBody = functionBody(wrapper)
  assertTrue(not bodyDefinesLocal(wrapperBody, "__before"), "doWork's own wrapper no longer inlines the template body")
  assertTrue(countFunctionsWithPrefix(wr.file, "__lyric_bmode_") == 1, "exactly one specialised function emitted")
  val specFn = firstFunctionWithPrefix(wr.file, "__lyric_bmode_")
  val specBody = functionBody(specFn)
  assertTrue(bodyDefinesLocal(specBody, "__before"), "template around body injected into the specialised function")
}

// Two matched functions with the identical `(Int) -> Int` shape share one
// specialised function — the dedup property B'-mode buys over C-mode
// (docs/55 §3.2 point 2, §5 Phase 2).
test "B'-mode dedups same-shape matches to one specialised function" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret { ret = call.proceed() }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"handle*\"\n" + "}\n" +
    "func handleOne(x: in Int): Int { x + 1 }\n" +
    "func handleTwo(y: in Int): Int { y * 2 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  assertTrue(
    countFunctionsWithPrefix(wr.file, "__lyric_bmode_") == 1,
    "same-shape matches dedup to one specialised function"
  )
}

// A different shape gets its own specialised function — dedup keys on
// shape, not on "any B'-mode match of this template."
test "B'-mode keeps separate specialised functions for distinct shapes" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret { ret = call.proceed() }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"handle*\"\n" + "}\n" +
    "func handleInt(x: in Int): Int { x + 1 }\n" +
    "func handleStr(s: in String): String { s }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  assertTrue(
    countFunctionsWithPrefix(wr.file, "__lyric_bmode_") == 2,
    "distinct shapes get distinct specialised functions"
  )
}

// A0046: a B'-mode (non-`@inline_template`) template whose body reads
// `args.<field>` would otherwise fall through to a confusing downstream
// "unknown name 'args'" error — the weaver flags it explicitly instead
// (docs/55 §5 Phase 1).
test "B'-mode template referencing args.<field> emits A0046" {
  val tplSrc = "package Lib.Tap\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" + "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"doWork\"\n" + "}\n" +
    "func doWork(x: in Int): Int { x }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0046"), "A0046 emitted for B'-mode template reading args.<field>")
}

// docs/56 / D115 — a row-constrained B'-mode template (`where TArgs has
// { ... }`) whose declared field is satisfied by the matched function's
// actual parameter: no A0046 (the row clause covers the reference), the
// body's `args.<field>` rewrites to `__lyric_args.<field>`, and the
// specialised function is still shared/deduped exactly like any other
// B'-mode template.
test "B'-mode row-constrained template rewrites args.<field> to the args record" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    val k = args.apiKey\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(apiKey: in String): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0046"), "row clause covers args.apiKey: no A0046")
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0047"), "matched function provides apiKey: no A0047")
  assertTrue(countFunctionsWithPrefix(wr.file, "__lyric_bmode_") == 1, "one specialised function emitted")
  val specFn = firstFunctionWithPrefix(wr.file, "__lyric_bmode_")
  val specBody = functionBody(specFn)
  assertTrue(
    bodyHasMemberAccess(specBody, "__lyric_args", "apiKey"),
    "args.apiKey rewritten to __lyric_args.apiKey inside the specialised function"
  )
}

// The row clause's coverage is per-field: a body that reads a field NOT
// declared by the row clause still falls through to A0046 (docs/56 §3's
// "narrow scope", not a blanket opt-out of the opacity rule).
test "B'-mode row clause covering only some fields still emits A0046 for the rest" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    val k = args.apiKey\n" +
    "    val other = args.unrelated\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(apiKey: in String): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0046"), "args.unrelated is not covered by the row clause: A0046 fires")
}

// A0047: the matched function has no parameter matching a declared row
// field — the row clause is not satisfied at this specialisation site.
test "B'-mode row-constrained template emits A0047 for a missing field" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    val k = args.apiKey\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(userId: in Int): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0047"), "handleOne has no 'apiKey' parameter: A0047 fires")
  // #4621 — the missing-field message must say so, not "different type"
  // (that wording belongs to the type-mismatch case, tested separately).
  val msg = diagMessageForCode(wr.diagnostics, "A0047")
  assertTrue(Str.contains(msg, "has no parameter named"), "A0047 missing-field message names the gap")
  assertTrue(not Str.contains(msg, "different type"), "A0047 missing-field message must not claim a type mismatch")
}

// A0047 also fires when the field name matches but the type doesn't — a
// same-name, different-type parameter does not satisfy the row constraint.
test "B'-mode row-constrained template emits A0047 for a type mismatch" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    val k = args.apiKey\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(apiKey: in Int): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0047"), "handleOne's 'apiKey' is Int, not String: A0047 fires")
  // #4621 — the type-mismatch message must say so, not "no parameter named"
  // (handleOne DOES have an 'apiKey' parameter — it's just the wrong type).
  val msg = diagMessageForCode(wr.diagnostics, "A0047")
  assertTrue(Str.contains(msg, "different type"), "A0047 type-mismatch message names the gap")
  assertTrue(
    not Str.contains(msg, "has no parameter named"),
    "A0047 type-mismatch message must not claim a missing parameter"
  )
}

// A C-mode (`@inline_template`) resolved from-instance is unaffected by
// B'-mode: it still inlines per match, and never emits A0046 even though
// its body reads `args.<field>` — that's exactly what `@inline_template`
// opts into.
test "C-mode from-instance is unaffected by B'-mode routing" {
  val tplSrc = "package Lib.Tap\n" + "@inline_template\n" + "pub aspect Tap {\n" + "  matches: name like \"*\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Tap")
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"doWork\"\n" + "}\n" +
    "func doWork(x: in Int): Int { x }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0046"), "C-mode template never emits A0046")
  assertTrue(
    countFunctionsWithPrefix(wr.file, "__lyric_bmode_") == 0,
    "C-mode does not route through B'-mode specialisation"
  )
  val wrapper = firstFunction(wr.file, "doWork")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "args", "x"), "args.x rewritten away (C-mode inline path)")
}

// docs/26 §5 specifies that an aspect's `requires:`/`ensures:` clauses are
// runtime-checked, but until now the wrapper's newly-composed contracts
// were spliced onto the `contracts` field verbatim and never elaborated
// into a runtime `assert(...)` — `Lyric.ContractElaborator` runs before
// weaving, so a wrapper's contracts (which don't exist until weaving
// builds the wrapper) were skipped entirely.  A local aspect's `requires:
// args.<field>` must now (a) rewrite `args.<field>` to the matched
// function's bare parameter name and (b) produce a runtime `assert(...)`
// in the wrapper body.
test "local aspect's requires: args.<field> is rewritten and elaborated into a runtime assert" {
  val src = "package P\n" + "aspect Guard {\n" + "  matches: name like \"handle*\"\n" +
    "  requires: args.apiKey != \"\"\n" +
    "  around(args) -> ret {\n" +
    "    ret = proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func handleOne(apiKey: in String): Int { 1 }\n"
  val pr = parse(src)
  val wr = weaveFileWithDiags(pr.file)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  val wrapper = firstFunction(wr.file, "handleOne")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "args", "apiKey"), "args.apiKey rewritten away in the requires: clause")
  assertTrue(bodyMentionsPath(body, "assert"), "requires: args.apiKey != \"\" is elaborated into a runtime assert()")
  assertTrue(bodyMentionsPath(body, "apiKey"), "the elaborated assert references the matched function's own parameter")
}

// Same fix, exercised through a row-constrained B'-mode `from`-instance
// (docs/56 / D115) — contracts land on the per-match wrapper built by
// `buildBModeCallSite`, a separate code path from the local-aspect
// `buildWrapper` case above, and needs its own elaboration wiring.
test "B'-mode from-instance's requires: args.<field> is elaborated into a runtime assert on the wrapper" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  requires: args.apiKey != \"\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(apiKey: in String): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0046"), "row clause covers args.apiKey: no A0046")
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0047"), "matched function provides apiKey: no A0047")
  val wrapper = firstFunction(wr.file, "handleOne")
  val body = functionBody(wrapper)
  assertTrue(
    not bodyHasMemberAccess(body, "args", "apiKey"),
    "args.apiKey rewritten away in the requires: clause on the wrapper"
  )
  assertTrue(bodyMentionsPath(body, "assert"), "requires: args.apiKey != \"\" is elaborated into a runtime assert()")
  assertTrue(bodyMentionsPath(body, "apiKey"), "the elaborated assert references the matched function's own parameter")
}

// The ensures: half of the same fix (#4676). Ensures elaboration is a
// meaningfully different code path from requires: instead of a prepended
// assert, the elaborator rewrites the wrapper's return site to bind the
// produced value into a synthetic `__lyric_result_<n>` local, assert every
// ensures clause against it, then return the local — so this proves the
// post-weave re-elaboration handles return-path rewriting, not just
// body-prefix insertion.
test "local aspect's ensures: args.<field> is rewritten and elaborated at the return site" {
  val src = "package P\n" + "aspect Guard {\n" + "  matches: name like \"handle*\"\n" + "  ensures: args.floor <= 100\n" +
    "  around(args) -> ret {\n" +
    "    ret = proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func handleOne(floor: in Int): Int { floor + 1 }\n"
  val pr = parse(src)
  val wr = weaveFileWithDiags(pr.file)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  val wrapper = firstFunction(wr.file, "handleOne")
  val body = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "args", "floor"), "args.floor rewritten away in the ensures: clause")
  assertTrue(bodyMentionsPath(body, "assert"), "ensures: args.floor <= 100 is elaborated into a runtime assert()")
  assertTrue(
    bodyMentionsPath(body, "__lyric_result_0"),
    "the return site is rewritten through the synthetic __lyric_result_<n> local"
  )
  assertTrue(bodyMentionsPath(body, "floor"), "the elaborated assert references the matched function's own parameter")
}

// Same ensures: path through the B'-mode per-match wrapper built by
// `buildBModeCallSite`, whose body ends in `return <spec>(...)` — the
// elaborator must rewrite that return into the bind-assert-return form.
test "B'-mode from-instance's ensures: args.<field> is elaborated at the wrapper's return site" {
  val tplSrc = "package Lib.Auth\n" + "pub aspect ValidateKey {\n" + "  matches: name like \"*\"\n" +
    "  ensures: args.apiKey != \"\"\n" +
    "  around(call) -> ret where TArgs has { apiKey: String } {\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val templates = makeTemplates(tplSrc, "Lib.Auth")
  val consumeSrc = "package App\n" + "aspect MyValidate from Lib.Auth.ValidateKey {\n" +
    "  matches: name like \"handle*\"\n" +
    "}\n" +
    "func handleOne(apiKey: in String): Int { 1 }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0046"), "row clause covers args.apiKey: no A0046")
  assertTrue(not diagsHaveCode(wr.diagnostics, "A0047"), "matched function provides apiKey: no A0047")
  val wrapper = firstFunction(wr.file, "handleOne")
  val body = functionBody(wrapper)
  assertTrue(
    not bodyHasMemberAccess(body, "args", "apiKey"),
    "args.apiKey rewritten away in the ensures: clause on the wrapper"
  )
  assertTrue(bodyMentionsPath(body, "assert"), "ensures: args.apiKey != \"\" is elaborated into a runtime assert()")
  assertTrue(
    bodyMentionsPath(body, "__lyric_result_0"),
    "the wrapper's return-the-specialised-call site is rewritten through __lyric_result_<n>"
  )
}

test "from-instance aspect with no matching template emits A0045" {
  val templates: Map[String, CollectedTemplate] = newMap()
  val consumeSrc = "package App\n" + "aspect MyTap from Lib.Tap.Tap {\n" + "  matches: name like \"doWork\"\n" + "}\n" +
    "func doWork(x: in Int): Int { x }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(diagsHaveCode(wr.diagnostics, "A0045"), "A0045 emitted for unresolved from-instance template")
  val fn = firstFunction(wr.file, "doWork")
  assertTrue(fn.name == "doWork", "function is unmodified (template not found → no weaving)")
}

test "weaveFileWithDiagsAndTemplates also weaves inline aspects (no from)" {
  val templates: Map[String, CollectedTemplate] = newMap()
  val consumeSrc = "package App\n" + "aspect InlineAspect {\n" + "  matches: name like \"*\"\n" +
    "  around(args) -> ret {\n" +
    "    var __inline = 42\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func doWork(x: in Int): Int { x }\n"
  val wr = weaveWithTemplates(consumeSrc, templates)
  assertTrue(wr.diagnostics.count == 0, "no diagnostics")
  val wrapper = firstFunction(wr.file, "doWork")
  val body = functionBody(wrapper)
  assertTrue(bodyDefinesLocal(body, "__inline"), "inline around body injected: var __inline defined")
}
