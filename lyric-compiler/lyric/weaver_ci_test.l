// weaver_ci_test.l — CI coverage for the three todo/06 weaver features
// (#683 config wiring, #682 call prelude, #681 @inline_template).
//
// Compiled and executed by the F# Expecto runner at
// bootstrap/tests/Lyric.Emitter.Tests/SelfHostedWeaverTests.fs.
// This is a regular Lyric program (no @test_module) so the bootstrap
// emitter can compile it directly.  Exit 0 + "ok" in stdout means
// every assertion held.  Closes #1347.
package Lyric.WeaverCiTest

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.Weaver


// ─────────────────────────────────────────────────────────────────────────────
// Helpers — shared with weaver_self_test.l conventions.
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

func firstFunctionFromItems(items: in List[Item], name: in String): FunctionDecl {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(fn) -> {
        if fn.name == name { return fn }
      }
      case _ -> {}
    }
    i = i + 1
  }
  panic("firstFunctionFromItems: no function named '" + name + "'")
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
    case SExpr(e)          -> exprMentionsPath(e, name)
    case SReturn(o)        -> match o {
                               case Some(e) -> exprMentionsPath(e, name)
                               case None    -> false
                             }
    case SLocal(b)         -> {
      match b {
        case LBVal(_, _, init) -> exprMentionsPath(init, name)
        case LBLet(_, _, init) -> exprMentionsPath(init, name)
        case LBVar(_, _, init) -> match init {
                                    case Some(e) -> exprMentionsPath(e, name)
                                    case None    -> false
                                  }
      }
    }
    case SAssign(t, _, v)  -> exprMentionsPath(t, name) or exprMentionsPath(v, name)
    case SThrow(e)         -> exprMentionsPath(e, name)
    case _ -> false
  }
}

func exprMentionsPath(e: in Expr, name: in String): Bool {
  match e.kind {
    case EPath(p)      -> p.segments.count == 1 and p.segments[0] == name
    case EParen(inner) -> exprMentionsPath(inner, name)
    case ECall(f, args) -> {
      if exprMentionsPath(f, name) { return true }
      var i = 0
      while i < args.count {
        val v = match args[i] {
          case CAPositional(v)    -> v
          case CANamed(_, v, _)   -> v
        }
        if exprMentionsPath(v, name) { return true }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r)    -> exprMentionsPath(l, name) or exprMentionsPath(r, name)
    case EPrefix(_, operand) -> exprMentionsPath(operand, name)
    case EMember(recv, _)   -> exprMentionsPath(recv, name)
    case _ -> false
  }
}

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
    case SAssign(t, _, v) -> exprHasMemberAccess(t, recv, mem) or exprHasMemberAccess(v, recv, mem)
    case SThrow(e)        -> exprHasMemberAccess(e, recv, mem)
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
    case EParen(inner)   -> exprHasMemberAccess(inner, recv, mem)
    case ECall(f, args)  -> {
      if exprHasMemberAccess(f, recv, mem) { return true }
      var i = 0
      while i < args.count {
        val v = match args[i] {
          case CAPositional(v)  -> v
          case CANamed(_, v, _) -> v
        }
        if exprHasMemberAccess(v, recv, mem) { return true }
        i = i + 1
      }
      false
    }
    case EBinop(_, l, r)     -> exprHasMemberAccess(l, recv, mem) or exprHasMemberAccess(r, recv, mem)
    case EPrefix(_, operand) -> exprHasMemberAccess(operand, recv, mem)
    case _ -> false
  }
}

func diagsHaveCode(diags: in List[Diagnostic], code: in String): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].code == code { return true }
    i = i + 1
  }
  false
}

func check(cond: in Bool, msg: in String): Unit {
  if not cond { panic("FAIL: " + msg) }
}


// ─────────────────────────────────────────────────────────────────────────────
// §1. #683 — config { } wiring
// ─────────────────────────────────────────────────────────────────────────────

func testConfigPreludeInjected(): Unit {
  val src =
    "package P\n" +
    "aspect Limit {\n" +
    "  config { maxRetries: Int = 3 }\n" +
    "  matches: name like \"f*\"\n" +
    "  around(args) -> ret {\n" +
    "    val r = config.maxRetries\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func foo(x: in Int): Int { x + 1 }\n"
  val woven = parseWeave(src)
  val wrapper = firstFunction(woven, "foo")
  val body    = functionBody(wrapper)
  check(isValBinding(body.statements[0], "__aspect_cfg_maxRetries"),
        "config prelude: first stmt must be __aspect_cfg_maxRetries val binding")
  val initExpr = findValInit(body, "__aspect_cfg_maxRetries")
  check(literalIntValue(initExpr) == 3i64,
        "config prelude: default literal must be 3")
}

func testConfigMemberRewritten(): Unit {
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
  check(not bodyHasMemberAccess(body, "config", "maxRetries"),
        "config rewrite: config.maxRetries member access must be gone")
  check(bodyMentionsPath(body, "__aspect_cfg_maxRetries"),
        "config rewrite: __aspect_cfg_maxRetries path must appear")
}

func testConfigNoDefaultEmitsA0044(): Unit {
  val src =
    "package P\n" +
    "aspect Limit {\n" +
    "  config { undefaulted: Int }\n" +
    "  matches: name like \"d\"\n" +
    "  around(args) -> ret {\n" +
    "    val v = config.undefaulted\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func d(): Int { 0 }\n"
  val wr = parseWeaveDiags(src)
  check(diagsHaveCode(wr.diagnostics, "A0044"),
        "config no-default: A0044 must be emitted")
}


// ─────────────────────────────────────────────────────────────────────────────
// §2. #682 — call ambient prelude
// ─────────────────────────────────────────────────────────────────────────────

func testCallShortNameInjected(): Unit {
  val src =
    "package MyApp.Handlers\n" +
    "aspect Trace {\n" +
    "  matches: name like \"handle*\"\n" +
    "  around(args) -> ret {\n" +
    "    val sn = call.shortName\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func handleX(): Int { 1 }\n"
  val woven  = parseWeave(src)
  val wrapper = firstFunction(woven, "handleX")
  val body    = functionBody(wrapper)
  check(not bodyHasMemberAccess(body, "call", "shortName"),
        "call prelude: call.shortName member access must be rewritten away")
  check(bodyMentionsPath(body, "__lyric_call_shortName"),
        "call prelude: __lyric_call_shortName path must appear")
  val initExpr = findValInit(body, "__lyric_call_shortName")
  check(literalStringValue(initExpr) == "handleX",
        "call prelude: shortName literal must equal the function name")
}

func testCallUnknownFieldEmitsA0043(): Unit {
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
  val wr = parseWeaveDiags(src)
  check(diagsHaveCode(wr.diagnostics, "A0043"),
        "call unknown field: A0043 must be emitted for call.elapsed")
}


// ─────────────────────────────────────────────────────────────────────────────
// §3. #681 — @inline_template args.<param> rewriting
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
  check(not diagsHaveCode(wr.diagnostics, "A0042"),
        "inline_template valid: no A0042 for matching args.x")
  val wrapper = firstFunctionFromItems(wr.file.items, "h")
  val body    = functionBody(wrapper)
  check(not bodyHasMemberAccess(body, "args", "x"),
        "inline_template valid: args.x must be rewritten away")
  check(bodyMentionsPath(body, "x"),
        "inline_template valid: bare path 'x' must appear after rewrite")
}

func testInlineTemplateMismatchEmitsA0042(): Unit {
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
  check(diagsHaveCode(wr.diagnostics, "A0042"),
        "inline_template mismatch: A0042 must be emitted for args.unknownField")
}

func testNonTemplateAspectLeavesArgsMemberAlone(): Unit {
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
  check(not diagsHaveCode(wr.diagnostics, "A0042"),
        "non-template: no A0042 emitted when @inline_template absent")
  val wrapper = firstFunctionFromItems(wr.file.items, "h")
  val body    = functionBody(wrapper)
  check(bodyHasMemberAccess(body, "args", "x"),
        "non-template: args.x must be left intact")
}


// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

func main(): Int {
  testConfigPreludeInjected()
  testConfigMemberRewritten()
  testConfigNoDefaultEmitsA0044()
  testCallShortNameInjected()
  testCallUnknownFieldEmitsA0043()
  testInlineTemplateRewritesArgs()
  testInlineTemplateMismatchEmitsA0042()
  testNonTemplateAspectLeavesArgsMemberAlone()
  println("ok")
  0
}
