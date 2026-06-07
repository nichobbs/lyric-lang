//! derives_self_test.l — exercises the self-hosted Lyric.Derives library.
//! Run in CI via native `lyric test` (no F# runner shim).
//!
@test_module
package Lyric.DerivesSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Derives
import Lyric.Mono

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func parseDeriveAndCount(src: in String): Int {
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  sf.items.count
}

func parseDeriveAndFindFunc(src: in String, name: in String): Bool {
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          return true
        }
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
          if name == methodName {
            n = n + 1
          }
          n = n + countMethodCalls(receiver, methodName)
        }
        case _ -> {
          n = n + countMethodCalls(fn, methodName)
        }
      }
      var i = 0
      while i < args.count {
        match args[i] {
          case CAPositional(expr) -> {
            n = n + countMethodCalls(expr, methodName)
          }
          case CANamed(_, value, _) -> {
            n = n + countMethodCalls(value, methodName)
          }
        }
        i = i + 1
      }
    }
    case EMember(receiver, _) -> {
      n = n + countMethodCalls(receiver, methodName)
    }
    case EBinop(_, lhs, rhs) -> {
      n = n + countMethodCalls(lhs, methodName)
      n = n + countMethodCalls(rhs, methodName)
    }
    case EBlock(body) -> {
      var i = 0
      while i < body.statements.count {
        match body.statements[i].kind {
          case SExpr(expr) -> {
            n = n + countMethodCalls(expr, methodName)
          }
          case SReturn(opt) -> {
            match opt {
              case Some(expr) -> {
                n = n + countMethodCalls(expr, methodName)
              }
              case None -> ()
            }
          }
          case _ -> ()
        }
        i = i + 1
      }
    }
    case EParen(inner) -> {
      n = n + countMethodCalls(inner, methodName)
    }
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
                case FBExpr(expr) -> {
                  return Some(value = expr)
                }
                case FBBlock(blk) -> {
                  if blk.statements.count > 0 {
                    match blk.statements[0].kind {
                      case SReturn(opt) -> {
                        return opt
                      }
                      case SExpr(e) -> {
                        return Some(value = e)
                      }
                      case _ -> {
                        return None
                      }
                    }
                  }
                  return None
                }
              }
            }
            case None -> {
              return None
            }
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
test "no annotation no synth" {
  val src = "package P\nrecord Point { x: Int; y: Int }\n"
  val cnt = parseDeriveAndCount(src)
  assertEqualInt(cnt, 1, "no-annot: no synthesis")
}

test "derive equals record" {
  val src = "package P\n@derive(Equals)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.equals"), "equals-rec: Point.equals synthesised")
}

test "derive hash record" {
  val src = "package P\n@derive(Hash)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.hash"), "hash-rec: Point.hash synthesised")
}

test "derive show record" {
  val src = "package P\n@derive(Show)\nrecord Point { x: Int; y: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Point.show"), "show-rec: Point.show synthesised")
}

test "generate json record" {
  val src = "package P\n@generate(Json)\nrecord Point { x: Int; y: Int }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertEqualInt(sf.items.count, 2, "json-rec: 1 record + 1 synth (toJson)")
  assertTrue(parseDeriveAndFindFunc(src, "Point.toJson"), "json-rec: Point.toJson synthesised")
}

// Regression for #992: the synthesised `toJson` for a record with a
// `String` field must dispatch through the five-step `replace` escape
// chain in `derives.l::jsonFieldExpr` (`\\`, `"`, `\n`, `\r`, `\t`).
// A regression that strips any link in that chain reduces the count and
// trips the assertion below; relying on the bare Int-field test
// (`testGenerateJsonRecord` above) would not catch it.
test "generate json record string escape" {
  val src = "package P\n@generate(Json)\nrecord Msg { text: String }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertTrue(parseDeriveAndFindFunc(src, "Msg.toJson"), "json-string: Msg.toJson synthesised")
  match findFuncBody(sf, "Msg.toJson") {
    case Some(body) -> {
      val replaceCount = countMethodCalls(body, "replace")
      assertEqualInt(replaceCount, 5, "json-string: Msg.toJson contains five chained .replace() calls (escape chain)")
    }
    case None -> assertTrue(false, "json-string: Msg.toJson body not found")
  }
}

test "multiple derives" {
  val src = "package P\n@derive(Equals)\n@derive(Hash)\n@derive(Show)\nrecord Point { x: Int; y: Int }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  val cnt = sf.items.count
  assertEqualInt(cnt, 4, "multi-derive: 1 record + 3 synths")
  assertTrue(parseDeriveAndFindFunc(src, "Point.equals"), "multi-derive: equals present")
  assertTrue(parseDeriveAndFindFunc(src, "Point.hash"), "multi-derive: hash present")
  assertTrue(parseDeriveAndFindFunc(src, "Point.show"), "multi-derive: show present")
}

test "derive equals distinct type" {
  val src = "package P\ntype UserId = Int derives Equals\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.equals"), "equals-distinct: UserId.equals synthesised")
}

test "derive hash distinct type" {
  val src = "package P\ntype UserId = Int derives Hash\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.hash"), "hash-distinct: UserId.hash synthesised")
}

test "derive show distinct type" {
  val src = "package P\ntype UserId = Int derives Show\n"
  assertTrue(parseDeriveAndFindFunc(src, "UserId.show"), "show-distinct: UserId.show synthesised")
}

test "derive equals empty record" {
  val src = "package P\n@derive(Equals)\nrecord Empty {}\n"
  assertTrue(parseDeriveAndFindFunc(src, "Empty.equals"), "equals-empty: Empty.equals synthesised (empty record)")
}

test "derive show empty record" {
  val src = "package P\n@derive(Show)\nrecord Empty {}\n"
  assertTrue(parseDeriveAndFindFunc(src, "Empty.show"), "show-empty: Empty.show synthesised (empty record)")
}

// Regression for #939: synthesised UFCS helpers must inherit the parent
// item's visibility.  Without it, `pub @derive(Equals) record Point` would
// produce a package-private `Point.equals`, and cross-package callers
// would fail visibility checks.
test "derive visibility pub" {
  val src = "package P\npub @derive(Equals)\nrecord Point { x: Int; y: Int }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  var i = 0
  var found = false
  while i < sf.items.count {
    val it = sf.items[i]
    match it.kind {
      case IFunc(decl) -> {
        if decl.name == "Point.equals" {
          found = true
          match it.visibility {
            case Some(v) -> {
              match v {
                case VisPub(_) -> ()
                // expected
                case VisInternal(_) -> {
                  assertTrue(false, "visibility-pub: Point.equals should be VisPub, got VisInternal")
                }
              }
              match decl.visibility {
                case Some(VisPub(_)) -> ()
                // expected
                case _ -> assertTrue(false, "visibility-pub: Point.equals FunctionDecl should also carry VisPub")
              }
            }
            case None -> assertTrue(false, "visibility-pub: Point.equals should have VisPub but visibility was None")
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  assertTrue(found, "visibility-pub: Point.equals must be synthesised")
}

// Regression for #939: package-private parent → package-private helper.
test "derive visibility package private" {
  val src = "package P\n@derive(Hash)\nrecord Counter { n: Int }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  var i = 0
  var found = false
  while i < sf.items.count {
    val it = sf.items[i]
    match it.kind {
      case IFunc(decl) -> {
        if decl.name == "Counter.hash" {
          found = true
          match it.visibility {
            case None -> ()
            // expected — parent has no `pub` so helper stays package-private
            case Some(_) -> assertTrue(false, "visibility-pkg: Counter.hash should inherit None (package-private), got Some(_)")
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  assertTrue(found, "visibility-pkg: Counter.hash must be synthesised")
}

test "exposed record derive" {
  val src = "package P\n@derive(Equals)\npub exposed record Row { id: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Row.equals"), "exposed-rec: Row.equals synthesised from exposed record")
}

test "no derives in list does not synth" {
  // A distinct type with an empty derives list should produce no synths.
  val src = "package P\ntype Foo = Int\n"
  val cnt = parseDeriveAndCount(src)
  assertEqualInt(cnt, 1, "no-derives: no synths for plain distinct type")
}

test "idempotent" {
  // deriveFile applied twice should not add duplicates if the synthesised
  // funcs don't carry @derive annotations themselves.
  val src = "package P\n@derive(Equals)\nrecord Point { x: Int; y: Int }\n"
  val pr = parse(src)
  val sf1 = deriveFile(pr.file)
  val sf2 = deriveFile(sf1)
  // sf2 should have 1 record + 1 equals from sf1; deriving on the IFunc items
  // produces nothing so sf2.items.count == sf1.items.count == 2.
  assertEqualInt(sf2.items.count, sf1.items.count, "idempotent: second deriveFile adds nothing")
}

// Projection of a distinct type whose underlying is `Bool` must call
// `.toBool()` — without the Bool arm in `projectionMethod` this would
// fall through to the non-existent `.toValue()` and the synthesised
// helpers wouldn't compile.  We exercise the path via `derives Equals`
// on `type Flag = Bool`; the synthesiser is hit and the result builds
// without error.
test "derive equals distinct bool" {
  val src = "package P\ntype Flag = Bool derives Equals\n"
  assertTrue(
    parseDeriveAndFindFunc(src, "Flag.equals"),
    "equals-distinct-bool: Flag.equals synthesised (projectionMethod Bool arm)"
  )
}

test "derive show distinct bool" {
  val src = "package P\ntype Flag = Bool derives Show\n"
  assertTrue(
    parseDeriveAndFindFunc(src, "Flag.show"),
    "show-distinct-bool: Flag.show synthesised (projectionMethod Bool arm)"
  )
}

// A type carrying BOTH a `derives X` clause and a `@derive(X)`
// annotation must not produce a duplicate helper.  `addIfNew`
// consults both `existingItems` and the in-progress `synths`
// accumulator to suppress the second synthesis.  Without that guard
// the file would type-check fail on the duplicate `.equals` definition.
test "derive and annotation dont duplicate" {
  val src = "package P\n" + "@derive(Equals)\n" + "record Foo derives Equals { x: Int }\n"
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
  assertEqualInt(count, 1, "derives-and-annotation: Foo.equals synthesised exactly once (not duplicated)")
}

// #1796 regression: the monomorphizer must RETAIN the non-generic
// `@derive`-synthesised helper functions.  Before the fix, the synthesised
// `FunctionDecl.generics = None` lowered to a bare null that the Phase-2
// `match decl.generics { Some -> drop; None -> keep }` matched as *neither*
// arm (the `Option_None` `isinst` test misses null), so the helper silently
// fell through and was dropped before codegen — `@derive(Equals/Hash/Show)` /
// `@generate(Json)` were dead on the self-hosted path.  We force mono into its
// Phase-2 path with a generic `gid[T]` in the source, then assert the derived
// `Point.equals` survives `monoFile`.
func findFuncInFile(sf: in SourceFile, name: in String): Bool {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == name {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

test "mono retains derived helpers" {
  val src = "package P\n" + "@derive(Equals)\n@derive(Hash)\n@derive(Show)\n" + "record Point { x: Int; y: Int }\n" +
    "func gid[T](v: in T): T { v }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  // Sanity: deriveFile produced the helpers.
  assertTrue(findFuncInFile(sf, "Point.equals"), "mono-retain: deriveFile added Point.equals")
  // The fix: monoFile must keep the non-generic helpers.
  val mr = monoFile(sf)
  assertTrue(findFuncInFile(mr.file, "Point.equals"), "mono-retain: monoFile keeps Point.equals (#1796)")
  assertTrue(findFuncInFile(mr.file, "Point.hash"), "mono-retain: monoFile keeps Point.hash (#1796)")
  assertTrue(findFuncInFile(mr.file, "Point.show"), "mono-retain: monoFile keeps Point.show (#1796)")
}
