// weaver_self_test.l — exercises the self-hosted `Lyric.Weaver` library.
// Compiled and executed by SelfHostedWeaverTests.fs.  Exit 0 + "ok" in
// stdout means every assertion held.
//
// Covers the three todo/06 features that land in weaver.l:
//
//   - #683: `config { }` block values become synthetic
//           `val __aspect_cfg_<name>` locals at the top of the woven
//           body; `config.<name>` references rewrite to those locals.
//
//   - #682: the woven body carries `__lyric_call_<name>` locals for
//           the compile-time-known fields (shortName, qualifiedName,
//           modulePath, sourceLocation, annotations, aspect);
//           `call.<name>` member access rewrites to those locals.
//
//   - #681: aspects marked `@inline_template` have `args.<field>`
//           rewritten to bare `<field>` paths at weave time; field
//           names that don't match a parameter accumulate as A0042
//           diagnostics.
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
        if fn.name == name { return fn }
      }
      case _ -> {}
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
        case FBExpr(_)    -> panic("functionBody: '" + fn.name + "' has FBExpr body")
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
              case _              -> ()
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

func isValBinding(s: in Statement, name: in String): Bool {
  match s.kind {
    case SLocal(b) -> {
      match b {
        case LBVal(pat, _, _) -> {
          match pat.kind {
            case PBinding(n, _) -> n == name
            case _              -> false
          }
        }
        case _ -> false
      }
    }
    case _ -> false
  }
}

func isPathExpr(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p) -> p.segments.count == 1 and p.segments[0] == name
    case _        -> false
  }
}

func literalIntValue(e: in Expr): Long {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _) -> v
        case _          -> panic("literalIntValue: not an Int literal")
      }
    }
    case _ -> panic("literalIntValue: not a literal")
  }
}

func literalStringValue(e: in Expr): String {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LString(s)       -> s
        case LTripleString(s) -> s
        case LRawString(s)    -> s
        case _                -> panic("literalStringValue: not a String literal")
      }
    }
    case _ -> panic("literalStringValue: not a literal")
  }
}

/// Find any `SExpr` whose top-level expression contains a path leaf
/// matching `name`.  Used to assert that `config.<x>` was rewritten
/// to `__aspect_cfg_<x>` somewhere in the rewritten body.
func bodyMentionsPath(blk: in Block, name: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtMentionsPath(blk.statements[i], name) { return true }
    i = i + 1
  }
  false
}

func stmtMentionsPath(s: in Statement, name: in String): Bool {
  match s.kind {
    case SExpr(e)     -> exprMentionsPath(e, name)
    case SReturn(o)   -> match o {
                          case Some(e) -> exprMentionsPath(e, name)
                          case None    -> false
                        }
    case SLocal(b)    -> {
      match b {
        case LBVal(_, _, init) -> exprMentionsPath(init, name)
        case LBLet(_, _, init) -> exprMentionsPath(init, name)
        case LBVar(_, _, init) -> match init {
                                    case Some(e) -> exprMentionsPath(e, name)
                                    case None    -> false
                                  }
      }
    }
    case _ -> false
  }
}

func exprMentionsPath(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p)               -> p.segments.count == 1 and p.segments[0] == name
    case EParen(inner)          -> exprMentionsPath(inner, name)
    case ECall(f, args)         -> {
      if exprMentionsPath(f, name) { return true }
      var i = 0
      while i < args.count {
        val arg = args[i]
        val v = match arg {
          case CAPositional(v)    -> v
          case CANamed(_, v, _)   -> v
        }
        if exprMentionsPath(v, name) { return true }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r)        -> exprMentionsPath(l, name) or exprMentionsPath(r, name)
    case EPrefix(_, op)         -> exprMentionsPath(op, name)
    case EMember(recv, _)       -> exprMentionsPath(recv, name)
    case EIf(c, t, el, _)       -> {
      if exprMentionsPath(c, name) { return true }
      if eobMentionsPath(t, name)  { return true }
      match el {
        case Some(eb) -> eobMentionsPath(eb, name)
        case None     -> false
      }
    }
    case EBlock(blk)            -> bodyMentionsPath(blk, name)
    case ETuple(xs)             -> {
      var i = 0
      while i < xs.count {
        if exprMentionsPath(xs[i], name) { return true }
        i = i + 1
      }
      false
    }
    case EList(xs)              -> {
      var i = 0
      while i < xs.count {
        if exprMentionsPath(xs[i], name) { return true }
        i = i + 1
      }
      false
    }
    case _ -> false
  }
}

func eobMentionsPath(eob: in ExprOrBlock, name: in String): Bool {
  match eob {
    case EOBExpr(e)   -> exprMentionsPath(e, name)
    case EOBBlock(b)  -> bodyMentionsPath(b, name)
  }
}

/// True iff the body contains a member access `<recv>.<member>` with
/// `recv` a single-segment path matching `receiverName`.  Used to
/// assert that the rewriter DID NOT leave a stray `config.maxRetries`
/// in place after rewriting.
func bodyHasMemberAccess(blk: in Block, receiverName: in String, memberName: in String): Bool {
  var i = 0
  while i < blk.statements.count {
    if stmtHasMemberAccess(blk.statements[i], receiverName, memberName) { return true }
    i = i + 1
  }
  false
}

func stmtHasMemberAccess(s: in Statement, recv: in String, mem: in String): Bool {
  match s.kind {
    case SExpr(e)   -> exprHasMemberAccess(e, recv, mem)
    case SReturn(o) -> match o {
                        case Some(e) -> exprHasMemberAccess(e, recv, mem)
                        case None    -> false
                      }
    case SLocal(b)  -> {
      match b {
        case LBVal(_, _, init) -> exprHasMemberAccess(init, recv, mem)
        case LBLet(_, _, init) -> exprHasMemberAccess(init, recv, mem)
        case LBVar(_, _, init) -> match init {
                                    case Some(e) -> exprHasMemberAccess(e, recv, mem)
                                    case None    -> false
                                  }
      }
    }
    case _ -> false
  }
}

func exprHasMemberAccess(e: in Expr, recv: in String, mem: in String): Bool {
  match e.kind {
    case EMember(r, m) -> {
      if m == mem {
        match r.kind {
          case EPath(p) -> if p.segments.count == 1 and p.segments[0] == recv { return true }
          case _        -> ()
        }
      }
      exprHasMemberAccess(r, recv, mem)
    }
    case EParen(inner)  -> exprHasMemberAccess(inner, recv, mem)
    case ECall(f, args) -> {
      if exprHasMemberAccess(f, recv, mem) { return true }
      var i = 0
      while i < args.count {
        val arg = args[i]
        val v = match arg {
          case CAPositional(v)  -> v
          case CANamed(_, v, _) -> v
        }
        if exprHasMemberAccess(v, recv, mem) { return true }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r) -> exprHasMemberAccess(l, recv, mem) or exprHasMemberAccess(r, recv, mem)
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
      case _         -> ()
    }
    i = i + 1
  }
  n
}


// ─────────────────────────────────────────────────────────────────────────────
// §1. Baseline: no aspects → identity (just IAspect items dropped).
// ─────────────────────────────────────────────────────────────────────────────

func testNoAspectIdentity(): Unit {
  val src = "package P\nfunc f(): Int { 1 }\n"
  val woven = parseWeave(src)
  assertEqualInt(woven.items.count, 1, "no-aspect: items unchanged")
  val fn = firstFunction(woven, "f")
  val blk = functionBody(fn)
  assertEqualInt(blk.statements.count, 1, "no-aspect: body unchanged")
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. #683 — `config { }` wiring.
// ─────────────────────────────────────────────────────────────────────────────

func testConfigPreludeInjected(): Unit {
  val src =
    "package P\n" +
    "aspect Limit {\n" +
    "  config { maxRetries: Int = 3 }\n" +
    "  matches: name like \"f*\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func foo(x: in Int): Int { x + 1 }\n"
  val woven = parseWeave(src)
  // Two IFuncs: `foo` (wrapper) and `foo__aspect_target` (renamed original).
  assertEqualInt(functionCount(woven, "foo"), 1, "config: one wrapper named 'foo'")
  assertEqualInt(functionCount(woven, "foo__aspect_target"), 1, "config: one renamed target")
  // Wrapper body must start with the config prelude.
  val wrapper = firstFunction(woven, "foo")
  val body    = functionBody(wrapper)
  assertTrue(isValBinding(body.statements[0], "__aspect_cfg_maxRetries"),
             "config: first wrapper stmt is __aspect_cfg_maxRetries val")
  val initExpr = findValInit(body, "__aspect_cfg_maxRetries")
  assertTrue(literalIntValue(initExpr) == 3L, "config: default 3 captured")
}

func testConfigDotRewritten(): Unit {
  val src =
    "package P\n" +
    "aspect Limit {\n" +
    "  config { maxRetries: Int = 5 }\n" +
    "  matches: name like \"bar\"\n" +
    "  around(args) -> ret {\n" +
    "    val limit = config.maxRetries\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func bar(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "bar")
  val body    = functionBody(wrapper)
  // `config.maxRetries` should be gone; `__aspect_cfg_maxRetries` should appear.
  assertTrue(not bodyHasMemberAccess(body, "config", "maxRetries"),
             "config: config.maxRetries member access rewritten away")
  assertTrue(bodyMentionsPath(body, "__aspect_cfg_maxRetries"),
             "config: __aspect_cfg_maxRetries path present")
}

func testConfigSkipsFieldsWithoutDefault(): Unit {
  // Field without a default is skipped — no prelude entry emitted (env-var
  // resolution is a follow-up).  We still expect the wrapper to be built;
  // we just shouldn't see __aspect_cfg_<field> for the no-default field.
  val src =
    "package P\n" +
    "aspect Limit {\n" +
    "  config {\n" +
    "    withDefault:   Int = 7\n" +
    "    withoutDefault: Int\n" +
    "  }\n" +
    "  matches: name like \"q\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func q(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "q")
  val body    = functionBody(wrapper)
  assertTrue(bodyMentionsPath(body, "__aspect_cfg_withDefault") or
             isValBinding(body.statements[0], "__aspect_cfg_withDefault"),
             "config: defaulted field materialised")
  // The non-defaulted field MUST NOT appear in the prelude.
  var i = 0
  var saw = false
  while i < body.statements.count {
    if isValBinding(body.statements[i], "__aspect_cfg_withoutDefault") { saw = true }
    i = i + 1
  }
  assertTrue(not saw, "config: non-defaulted field has no prelude entry")
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. #682 — `call` ambient prelude.
// ─────────────────────────────────────────────────────────────────────────────

func testCallPreludeShortName(): Unit {
  val src =
    "package MyApp.Handlers\n" +
    "aspect Trace {\n" +
    "  matches: name like \"handle*\"\n" +
    "  around(args) -> ret { proceed(args) }\n" +
    "}\n" +
    "func handleX(): Int { 1 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "handleX")
  val body    = functionBody(wrapper)
  val sn = findValInit(body, "__lyric_call_shortName")
  assertEqual(literalStringValue(sn), "handleX", "call: shortName literal matches")
  val qn = findValInit(body, "__lyric_call_qualifiedName")
  assertEqual(literalStringValue(qn), "MyApp.Handlers.handleX",
              "call: qualifiedName combines packagePath + name")
  val mp = findValInit(body, "__lyric_call_modulePath")
  assertEqual(literalStringValue(mp), "MyApp.Handlers", "call: modulePath is packagePath")
  val asp = findValInit(body, "__lyric_call_aspect")
  assertEqual(literalStringValue(asp), "Trace", "call: aspect literal is the aspect name")
}

func testCallDotRewritten(): Unit {
  val src =
    "package P\n" +
    "aspect Trace {\n" +
    "  matches: name like \"g\"\n" +
    "  around(args) -> ret {\n" +
    "    val name = call.shortName\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "g")
  val body    = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "call", "shortName"),
             "call: call.shortName member access rewritten away")
  assertTrue(bodyMentionsPath(body, "__lyric_call_shortName"),
             "call: __lyric_call_shortName path present")
}

func testCallUnknownFieldUnchanged(): Unit {
  // call.elapsed is not yet wired; the rewriter must NOT touch it so
  // the downstream type-checker can surface the gap.
  val src =
    "package P\n" +
    "aspect Trace {\n" +
    "  matches: name like \"g\"\n" +
    "  around(args) -> ret {\n" +
    "    val e = call.elapsed\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func g(): Int { 0 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "g")
  val body    = functionBody(wrapper)
  // `call.elapsed` should still be present — we deliberately leave
  // unwired fields alone.
  assertTrue(bodyHasMemberAccess(body, "call", "elapsed"),
             "call: unknown field call.elapsed left intact")
}


// ─────────────────────────────────────────────────────────────────────────────
// §4. #681 — `@inline_template` args.<field> rewriting + A0042.
// ─────────────────────────────────────────────────────────────────────────────

func testInlineTemplateRewritesArgs(): Unit {
  val src =
    "package P\n" +
    "@inline_template\n" +
    "pub aspect Tap {\n" +
    "  matches: name like \"h\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  // No A0042 — args.x matches a param.
  var i = 0
  while i < wr.diagnostics.count {
    assertTrue(wr.diagnostics[i].code != "A0042",
               "inline_template: no A0042 for valid args.<param>")
    i = i + 1
  }
  val wrapper = firstFunction(wr.file, "h")
  val body    = functionBody(wrapper)
  assertTrue(not bodyHasMemberAccess(body, "args", "x"),
             "inline_template: args.x rewritten away")
  assertTrue(bodyMentionsPath(body, "x"),
             "inline_template: bare path 'x' present after rewrite")
}

func testInlineTemplateMissingArgEmitsA0042(): Unit {
  val src =
    "package P\n" +
    "@inline_template\n" +
    "pub aspect Tap {\n" +
    "  matches: name like \"h\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.unknownField\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  // Expect at least one A0042.
  var found = false
  var i = 0
  while i < wr.diagnostics.count {
    if wr.diagnostics[i].code == "A0042" { found = true }
    i = i + 1
  }
  assertTrue(found, "inline_template: A0042 emitted for args.unknownField")
}

func testNonTemplateLeavesArgsAlone(): Unit {
  // Without @inline_template, args.<field> must pass through unchanged
  // — no rewrite, no A0042 (parity with the F# weaver's contract).
  val src =
    "package P\n" +
    "aspect Tap {\n" +
    "  matches: name like \"h\"\n" +
    "  around(args) -> ret {\n" +
    "    val a = args.x\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func h(x: in Int): Int { x }\n"
  val wr = parseWeaveDiags(src)
  var i = 0
  while i < wr.diagnostics.count {
    assertTrue(wr.diagnostics[i].code != "A0042",
               "non-template: no A0042 emitted")
    i = i + 1
  }
  val wrapper = firstFunction(wr.file, "h")
  val body    = functionBody(wrapper)
  assertTrue(bodyHasMemberAccess(body, "args", "x"),
             "non-template: args.x left intact")
}


// ─────────────────────────────────────────────────────────────────────────────
// Test runner.
// ─────────────────────────────────────────────────────────────────────────────

func main(): Unit {
  testNoAspectIdentity()
  testConfigPreludeInjected()
  testConfigDotRewritten()
  testConfigSkipsFieldsWithoutDefault()
  testCallPreludeShortName()
  testCallDotRewritten()
  testCallUnknownFieldUnchanged()
  testInlineTemplateRewritesArgs()
  testInlineTemplateMissingArgEmitsA0042()
  testNonTemplateLeavesArgsAlone()
  println("weaver self-test: ok")
}
