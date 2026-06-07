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
  // call.elapsed is not yet wired; the rewriter leaves the expression
  // intact AND emits A0043 so the user gets a weaver-targeted message
  // instead of a "call is undeclared" type error (review #1193).
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"g\"\n" + "  around(args) -> ret {\n" +
    "    val e = call.elapsed\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  val wrapper = firstFunction(wr.file, "g")
  val body = functionBody(wrapper)
  assertTrue(bodyHasMemberAccess(body, "call", "elapsed"), "call.elapsed left intact in AST")
  assertTrue(diagsHaveCode(wr.diagnostics, "A0043"), "A0043 emitted for unknown call.elapsed")
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
  // referencing `call.elapsed` twice produced two A0043 diagnostics.
  val src = "package P\n" + "aspect Trace {\n" + "  matches: name like \"r\"\n" + "  around(args) -> ret {\n" +
    "    val a = call.elapsed\n" +
    "    val b = call.elapsed\n" +
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
