// derives_self_test.l — exercises the self-hosted Lyric.Derives library.
// Compiled and executed by SelfHostedDerivesTests.fs.
// Exit 0 + "ok" in stdout means all checks held.
package Lyric.DerivesSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Derives


// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────

func parseDeriveAndCount(src: in String): Int {
  val pr  = parse(src)
  val sf  = deriveFile(pr.file)
  sf.items.count
}

func parseDeriveAndFindFunc(src: in String, name: in String): Bool {
  val pr  = parse(src)
  val sf  = deriveFile(pr.file)
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name { return true }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

// Recursively count occurrences of `ECall(EMember(_, methodName), _)` in
// `e`.  Used to verify that synthesised `toJson` bodies for String fields
// dispatch through the five-step `replace` escape chain in `derives.l`
// (#992): a regression that strips any link in that chain reduces the
// `replace` count and fails the assertion.
func countMethodCalls(e: in Expr, methodName: in String): Int {
  var n = 0
  match e.kind {
    case ECall(fn, args) -> {
      match fn.kind {
        case EMember(receiver, name) -> {
          if name == methodName { n = n + 1 }
          n = n + countMethodCalls(receiver, methodName)
        }
        case _ -> { n = n + countMethodCalls(fn, methodName) }
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(expr) -> { n = n + countMethodCalls(expr, methodName) }
          case CANamed(_, value, _) -> { n = n + countMethodCalls(value, methodName) }
        }
        i = i + 1
      }
    }
    case EMember(receiver, _) -> { n = n + countMethodCalls(receiver, methodName) }
    case EBinop(_, lhs, rhs)  -> {
      n = n + countMethodCalls(lhs, methodName)
      n = n + countMethodCalls(rhs, methodName)
    }
    case EBlock(body) -> {
      var i = 0
      while i < body.statements.count {
        match body.statements[i].kind {
          case SExpr(expr)   -> { n = n + countMethodCalls(expr, methodName) }
          case SReturn(opt)  -> {
            match opt {
              case Some(expr) -> { n = n + countMethodCalls(expr, methodName) }
              case None       -> ()
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
    }
    case EParen(inner) -> { n = n + countMethodCalls(inner, methodName) }
    case _ -> ()
  }
  n
}

// Find the synthesised IFunc with the given name and return its body
// expression (the synthesiser wraps the toJson expression in a single
// SReturn).  Returns None if not found or shaped unexpectedly.
func findFuncBody(sf: in SourceFile, name: in String): Option[Expr] {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          match decl.body {
            case Some(fb) -> {
              match fb {
                case FBExpr(expr) -> { return Some(value = expr) }
                case FBBlock(blk) -> {
                  if blk.statements.count > 0 {
                    match blk.statements[0].kind {
                      case SReturn(opt) -> { return opt }
                      case SExpr(e)     -> { return Some(value = e) }
                      case _            -> { return None }
                    }
                  }
                  return None
                }
              }
            }
            case None -> { return None }
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}


// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

func testNoAnnotationNoSynth(): Unit {
  val src = "package P\nrecord Point { x: Int; y: Int }\n"
  val cnt = parseDeriveAndCount(src)
  assertEqualInt(cnt, 1, "no-annot: no synthesis")
}

func testDeriveEqualsRecord(): Unit {
  val src = "package P\n@derive(Equals)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.equals"),
    "equals-rec: Point.equals synthesised")
}

func testDeriveHashRecord(): Unit {
  val src = "package P\n@derive(Hash)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.hash"),
    "hash-rec: Point.hash synthesised")
}

func testDeriveShowRecord(): Unit {
  val src = "package P\n@derive(Show)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.show"),
    "show-rec: Point.show synthesised")
}

func testGenerateJsonRecord(): Unit {
  val src = "package P\n@generate(Json)\nrecord Point { x: Int; y: Int }\n"
  val pr  = parse(src)
  val sf  = deriveFile(pr.file)
  assertEqualInt(sf.items.count, 2, "json-rec: 1 record + 1 synth (toJson)")
  assertTrue(parseDeriveAndFindFunc(src, "Point.toJson"), "json-rec: Point.toJson synthesised")
}

// Regression for #992: the synthesised `toJson` for a record with a
// `String` field must dispatch through the five-step `replace` escape
// chain in `derives.l::jsonFieldExpr` (`\\`, `"`, `\n`, `\r`, `\t`).
// A regression that strips any link in that chain reduces the count and
// trips the assertion below; relying on the bare Int-field test
// (`testGenerateJsonRecord` above) would not catch it.
func testGenerateJsonRecordStringEscape(): Unit {
  val src = "package P\n@generate(Json)\nrecord Msg { text: String }\n"
  val pr  = parse(src)
  val sf  = deriveFile(pr.file)
  assertTrue(parseDeriveAndFindFunc(src, "Msg.toJson"),
    "json-string: Msg.toJson synthesised")
  match findFuncBody(sf, "Msg.toJson") {
    case Some(body) -> {
      val replaceCount = countMethodCalls(body, "replace")
      assertEqualInt(replaceCount, 5,
        "json-string: Msg.toJson contains five chained .replace() calls (escape chain)")
    }
    case None -> assertTrue(false, "json-string: Msg.toJson body not found")
  }
}

func testMultipleDerives(): Unit {
  val src = "package P\n@derive(Equals)\n@derive(Hash)\n@derive(Show)\nrecord Point { x: Int; y: Int }\n"
  val pr  = parse(src)
  val sf  = deriveFile(pr.file)
  val cnt = sf.items.count
  assertEqualInt(cnt, 4, "multi-derive: 1 record + 3 synths")
  assertTrue(parseDeriveAndFindFunc(src, "Point.equals"), "multi-derive: equals present")
  assertTrue(parseDeriveAndFindFunc(src, "Point.hash"),   "multi-derive: hash present")
  assertTrue(parseDeriveAndFindFunc(src, "Point.show"),   "multi-derive: show present")
}

func testDeriveEqualsDistinctType(): Unit {
  val src = "package P\ntype UserId = Int derives Equals\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.equals"),
    "equals-distinct: UserId.equals synthesised")
}

func testDeriveHashDistinctType(): Unit {
  val src = "package P\ntype UserId = Int derives Hash\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.hash"),
    "hash-distinct: UserId.hash synthesised")
}

func testDeriveShowDistinctType(): Unit {
  val src = "package P\ntype UserId = Int derives Show\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.show"),
    "show-distinct: UserId.show synthesised")
}

func testDeriveEqualsEmptyRecord(): Unit {
  val src = "package P\n@derive(Equals)\nrecord Empty {}\n"
  assertTrue(parseDeriveAndFindFunc(src, "Empty.equals"),
    "equals-empty: Empty.equals synthesised (empty record)")
}

func testDeriveShowEmptyRecord(): Unit {
  val src = "package P\n@derive(Show)\nrecord Empty {}\n"
  assertTrue(parseDeriveAndFindFunc(src, "Empty.show"),
    "show-empty: Empty.show synthesised (empty record)")
}

func testExposedRecordDerive(): Unit {
  val src = "package P\n@derive(Equals)\npub exposed record Row { id: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Row.equals"),
    "exposed-rec: Row.equals synthesised from exposed record")
}

func testNoDerivesInListDoesNotSynth(): Unit {
  // A distinct type with an empty derives list should produce no synths.
  val src = "package P\ntype Foo = Int\n"
  val cnt = parseDeriveAndCount(src)
  assertEqualInt(cnt, 1, "no-derives: no synths for plain distinct type")
}

func testIdempotent(): Unit {
  // deriveFile applied twice should not add duplicates if the synthesised
  // funcs don't carry @derive annotations themselves.
  val src  = "package P\n@derive(Equals)\nrecord Point { x: Int; y: Int }\n"
  val pr   = parse(src)
  val sf1  = deriveFile(pr.file)
  val sf2  = deriveFile(sf1)
  // sf2 should have 1 record + 1 equals from sf1; deriving on the IFunc items
  // produces nothing so sf2.items.count == sf1.items.count == 2.
  assertEqualInt(sf2.items.count, sf1.items.count,
    "idempotent: second deriveFile adds nothing")
}

// Projection of a distinct type whose underlying is `Bool` must call
// `.toBool()` — without the Bool arm in `projectionMethod` this would
// fall through to the non-existent `.toValue()` and the synthesised
// helpers wouldn't compile.  We exercise the path via `derives Equals`
// on `type Flag = Bool`; the synthesiser is hit and the result builds
// without error.
func testDeriveEqualsDistinctBool(): Unit {
  val src = "package P\ntype Flag = Bool derives Equals\n"
  assertTrue(parseDeriveAndFindFunc(src, "Flag.equals"),
    "equals-distinct-bool: Flag.equals synthesised (projectionMethod Bool arm)")
}

func testDeriveShowDistinctBool(): Unit {
  val src = "package P\ntype Flag = Bool derives Show\n"
  assertTrue(parseDeriveAndFindFunc(src, "Flag.show"),
    "show-distinct-bool: Flag.show synthesised (projectionMethod Bool arm)")
}

// A type carrying BOTH a `derives X` clause and a `@derive(X)`
// annotation must not produce a duplicate helper.  `addIfNew`
// consults both `existingItems` and the in-progress `synths`
// accumulator to suppress the second synthesis.  Without that guard
// the file would type-check fail on the duplicate `.equals` definition.
func testDeriveAndAnnotationDontDuplicate(): Unit {
  val src =
    "package P\n" +
    "@derive(Equals)\n" +
    "record Foo derives Equals { x: Int }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  // Count Foo.equals occurrences — exactly one expected.
  var count = 0
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(fn) -> if fn.name == "Foo.equals" { count = count + 1 }
      case _ -> ()
    }
    i = i + 1
  }
  assertEqualInt(count, 1,
    "derives-and-annotation: Foo.equals synthesised exactly once (not duplicated)")
}

func main(): Unit {
  testNoAnnotationNoSynth()
  testDeriveEqualsRecord()
  testDeriveHashRecord()
  testDeriveShowRecord()
  testGenerateJsonRecord()
  testGenerateJsonRecordStringEscape()
  testMultipleDerives()
  testDeriveEqualsDistinctType()
  testDeriveHashDistinctType()
  testDeriveShowDistinctType()
  testDeriveEqualsEmptyRecord()
  testDeriveShowEmptyRecord()
  testDeriveEqualsDistinctBool()
  testDeriveShowDistinctBool()
  testDeriveAndAnnotationDontDuplicate()
  testExposedRecordDerive()
  testNoDerivesInListDoesNotSynth()
  testIdempotent()
  println("derives self-test: ok")
}
