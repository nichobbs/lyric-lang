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

// ─────────────────────────────────────────────────────────────────────────────
// Union derive tests (#1507).
// ─────────────────────────────────────────────────────────────────────────────
test "derive equals union" {
  val src = "package P\n@derive(Equals)\nunion Shape { case Circle(r: Float); case Rect(w: Float, h: Float); case Dot }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertTrue(parseDeriveAndFindFunc(src, "Shape.equals"), "union-eq: Shape.equals synthesised")
}

test "derive hash union" {
  val src = "package P\n@derive(Hash)\nunion Shape { case Circle(r: Float); case Dot }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Shape.hash"), "union-hash: Shape.hash synthesised")
}

test "derive show union" {
  val src = "package P\n@derive(Show)\nunion Shape { case Circle(r: Float); case Dot }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Shape.show"), "union-show: Shape.show synthesised")
}

test "derive ord union" {
  val src = "package P\n@derive(Ord)\nunion Priority { case Low; case Medium; case High }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Priority.compare"), "union-ord: Priority.compare synthesised")
}

test "derive all union" {
  val src = "package P\n@derive(Equals)\n@derive(Hash)\n@derive(Show)\nunion Expr { case Num(n: Int); case Add(l: Int, r: Int) }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertEqualInt(sf.items.count, 4, "union-all: 1 union + 3 synths")
  assertTrue(parseDeriveAndFindFunc(src, "Expr.equals"), "union-all: equals present")
  assertTrue(parseDeriveAndFindFunc(src, "Expr.hash"), "union-all: hash present")
  assertTrue(parseDeriveAndFindFunc(src, "Expr.show"), "union-all: show present")
}

test "derive equals nullary union" {
  // Union where all cases are nullary — equals should still produce correct structure.
  val src = "package P\n@derive(Equals)\nunion Direction { case North; case South; case East; case West }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Direction.equals"), "union-eq-null: Direction.equals synthesised")
}

// ─────────────────────────────────────────────────────────────────────────────
// Enum derive tests (#1507).
// ─────────────────────────────────────────────────────────────────────────────
test "derive equals enum" {
  val src = "package P\n@derive(Equals)\nenum Color { case Red; case Green; case Blue }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Color.equals"), "enum-eq: Color.equals synthesised")
}

test "derive hash enum" {
  val src = "package P\n@derive(Hash)\nenum Color { case Red; case Green; case Blue }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Color.hash"), "enum-hash: Color.hash synthesised")
}

test "derive show enum" {
  val src = "package P\n@derive(Show)\nenum Color { case Red; case Green; case Blue }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Color.show"), "enum-show: Color.show synthesised")
}

test "derive ord enum" {
  val src = "package P\n@derive(Ord)\nenum Priority { case Low; case Medium; case High }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Priority.compare"), "enum-ord: Priority.compare synthesised")
}

test "derive all enum" {
  val src = "package P\n@derive(Equals)\n@derive(Hash)\n@derive(Show)\nenum Day { case Mon; case Tue; case Wed }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertEqualInt(sf.items.count, 4, "enum-all: 1 enum + 3 synths")
}

// ─────────────────────────────────────────────────────────────────────────────
// @derive(Ord) for records and distinct types (#1507).
// ─────────────────────────────────────────────────────────────────────────────
test "derive ord record" {
  val src = "package P\n@derive(Ord)\nrecord Version { major: Int; minor: Int; patch: Int }\n"
  assertTrue(parseDeriveAndFindFunc(src, "Version.compare"), "ord-rec: Version.compare synthesised")
}

test "derive ord record empty" {
  val src = "package P\n@derive(Ord)\nrecord Unit {}\n"
  assertTrue(parseDeriveAndFindFunc(src, "Unit.compare"), "ord-rec-empty: Unit.compare synthesised (always 0)")
}

test "derive ord distinct" {
  val src = "package P\ntype Score = Int derives Ord\n"
  assertTrue(parseDeriveAndFindFunc(src, "Score.compare"), "ord-distinct: Score.compare synthesised")
}

test "derive ord distinct annotation" {
  val src = "package P\n@derive(Ord)\ntype Score = Int\n"
  assertTrue(parseDeriveAndFindFunc(src, "Score.compare"), "ord-distinct-ann: Score.compare synthesised via @derive")
}

// ─────────────────────────────────────────────────────────────────────────────
// @derive(Ord) fields of distinct type over an Ord primitive (#3186).
// ─────────────────────────────────────────────────────────────────────────────
// Count `EMember(_, name)` accesses anywhere in `e` (plain member reads, not
// method calls — countMethodCalls only sees ECall heads).
func countMemberNamed(e: in Expr, name: in String): Int {
  var n = 0
  match e.kind {
    case EMember(receiver, m) -> {
      if m == name {
        n = n + 1
      }
      n = n + countMemberNamed(receiver, name)
    }
    case EBinop(_, lhs, rhs) -> {
      n = n + countMemberNamed(lhs, name)
      n = n + countMemberNamed(rhs, name)
    }
    case EPrefix(_, operand) -> {
      n = n + countMemberNamed(operand, name)
    }
    case EParen(inner) -> {
      n = n + countMemberNamed(inner, name)
    }
    case ECall(f, args) -> {
      n = n + countMemberNamed(f, name)
      var i = 0
      while i < args.count {
        val v = match args[i] { case CAPositional(v) -> v; case CANamed(_, v, _) -> v }
        n = n + countMemberNamed(v, name)
        i = i + 1
      }
    }
    case EIf(cond, t, _, _) -> {
      // Else-branch omitted: cross-package match on Option[ExprOrBlock] miscompiles (#3273).
      n = n + countMemberNamed(cond, name)
      n = n + countMemberNamedEob(t, name)
    }
    // Union Ord bodies dispatch through nested match; arm guard Option[Expr] also
    // omitted for the same cross-package-Option miscompile reason (#3273).
    case EMatch(scrut, arms) -> {
      n = n + countMemberNamed(scrut, name)
      var i = 0
      while i < arms.count {
        n = n + countMemberNamedEob(arms[i].body, name)
        i = i + 1
      }
    }
    case EBlock(blk) -> {
      n = n + countMemberNamedBlock(blk, name)
    }
    case _ -> ()
  }
  n
}

func countMemberNamedEob(eob: in ExprOrBlock, name: in String): Int {
  match eob {
    case EOBExpr(e) -> countMemberNamed(e, name)
    case EOBBlock(b) -> countMemberNamedBlock(b, name)
  }
}

func countMemberNamedBlock(blk: in Block, name: in String): Int {
  var n = 0
  var si = 0
  while si < blk.statements.count {
    match blk.statements[si].kind {
      case SExpr(e) -> {
        n = n + countMemberNamed(e, name)
      }
      case SReturn(o) -> {
        match o {
          case Some(e) -> {
            n = n + countMemberNamed(e, name)
          }
          case None -> ()
        }
      }
      case SLocal(b) -> {
        match b {
          case LBVal(_, _, init) -> {
            n = n + countMemberNamed(init, name)
          }
          case LBLet(_, _, init) -> {
            n = n + countMemberNamed(init, name)
          }
          case LBVar(_, _, init) -> {
            match init {
              case Some(e) -> {
                n = n + countMemberNamed(e, name)
              }
              case None -> ()
            }
          }
        }
      }
      case SAssign(t, _, v) -> {
        n = n + countMemberNamed(t, name)
        n = n + countMemberNamed(v, name)
      }
      case _ -> ()
    }
    si = si + 1
  }
  n
}

// Sum `countMemberNamed` over the named synthesised function's block body.  The
// record Ord body is a sequence of `if (lt/gt) return` statement-expressions;
// the union Ord body wraps the per-case comparisons in a `return match` (an
// `SReturn(EMatch(...))`), so the walk descends through both forms (#3365).
func countMemberNamedInFunc(sf: in SourceFile, funcName: in String, member: in String): Int {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == funcName {
          match decl.body {
            case Some(fb) -> {
              match fb {
                case FBBlock(blk) -> {
                  return countMemberNamedBlock(blk, member)
                }
                case _ -> {
                  return 0
                }
              }
            }
            case None -> {
              return 0
            }
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  0
}

test "ord record distinct field projects through .value (#3186)" {
  // `age: Age` over `type Age = Int` must compare `self.age.value`, not the
  // wrapper references; the two age-ifs carry one `.value` per operand.
  val src = "package P\ntype Age = Int\n@derive(Ord)\nrecord Person { age: Age; name: String }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertTrue(parseDeriveAndFindFunc(src, "Person.compare"), "ord-distinct-field: Person.compare synthesised")
  assertEqualInt(
    countMemberNamedInFunc(sf, "Person.compare", "value"),
    4,
    "ord-distinct-field: 2 age-ifs x 2 operands project through .value"
  )
}

test "ord record chained distinct field projects through .value.value (#3186)" {
  val src = "package P\ntype Inner = Int\ntype Outer = Inner\n@derive(Ord)\nrecord W { o: Outer }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertEqualInt(
    countMemberNamedInFunc(sf, "W.compare", "value"),
    8,
    "ord-chained-distinct: 2 ifs x 2 operands x 2 hops project through .value.value"
  )
}

test "ord union distinct case field projects through .value (#3186)" {
  val src = "package P\ntype Age = Int\n@derive(Ord)\nunion U { case Person(age: Age); case Anon }\n"
  assertTrue(parseDeriveAndFindFunc(src, "U.compare"), "ord-union-distinct: U.compare synthesised")
}

test "ord record non-ordered field still synthesises without projection (D0001 path)" {
  // A record-typed field is not ordering-capable: D0001 fires (stdout) and the
  // comparison falls back to the unprojected field (hops 0).
  val src = "package P\nrecord Inner { v: Int }\n@derive(Ord)\nrecord Holder { inner: Inner }\n"
  val pr = parse(src)
  val sf = deriveFile(pr.file)
  assertTrue(parseDeriveAndFindFunc(src, "Holder.compare"), "ord-nonord: Holder.compare still synthesised")
  assertEqualInt(countMemberNamedInFunc(sf, "Holder.compare", "value"), 0, "ord-nonord: no .value projection")
}

// ─────────────────────────────────────────────────────────────────────────────
// @derive(Ord) fields of a distinct type imported from another package (#3287).
// ─────────────────────────────────────────────────────────────────────────────
// Parse an "imported package" source and return its items, mirroring how the
// bridges flatten `ImportedPackage.items` before calling `deriveFileWithImports`.
func importedItemsOf(src: in String): List[Item] {
  parse(src).file.items
}

test "ord record cross-package distinct field projects through .value (#3287)" {
  // `Age` is declared in another package; the consumer's @derive(Ord) record
  // must still compare `self.age.value`, not the wrapper references.  Without
  // the imported-distincts map the field tripped a false D0001 and miscompiled
  // to a reference comparison.
  val pkg = "package Pkg\ntype Age = Int\n"
  val app = "package App\nimport Pkg\n@derive(Ord)\nrecord Person { age: Age; name: String }\n"
  val sf = deriveFileWithImports(parse(app).file, importedItemsOf(pkg))
  assertTrue(findFuncInFile(sf, "Person.compare"), "xpkg-ord: Person.compare synthesised")
  assertEqualInt(
    countMemberNamedInFunc(sf, "Person.compare", "value"),
    4,
    "xpkg-ord: 2 age-ifs x 2 operands project through .value"
  )
}

test "ord union cross-package distinct case field projects through .value (#3287)" {
  val pkg = "package Pkg\ntype Age = Int\n"
  val app = "package App\nimport Pkg\n@derive(Ord)\nunion U { case Person(age: Age); case Anon }\n"
  val sf = deriveFileWithImports(parse(app).file, importedItemsOf(pkg))
  assertTrue(findFuncInFile(sf, "U.compare"), "xpkg-union-ord: U.compare synthesised")
  // The same-case `Person` arm compares the one `age: Age` field, projecting it
  // through `.value`: a non-zero count proves the cross-package distinct fix
  // reaches the union's inner-match arm body (a broken path emits 0) — #3287.
  assertEqualInt(
    countMemberNamedInFunc(sf, "U.compare", "value"),
    4,
    "xpkg-union-ord: 2 age-ifs x 2 operands project through .value in the inner match arm"
  )
}

test "ord record same-file distinct still works through deriveFileWithImports (#3287)" {
  // Regression guard: same-file distincts must keep resolving when the imported
  // list is non-empty (the consumer file is folded into the map first).
  val pkg = "package Pkg\ntype Other = Int\n"
  val app = "package App\nimport Pkg\ntype Age = Int\n@derive(Ord)\nrecord Person { age: Age }\n"
  val sf = deriveFileWithImports(parse(app).file, importedItemsOf(pkg))
  assertEqualInt(
    countMemberNamedInFunc(sf, "Person.compare", "value"),
    4,
    "xpkg-samefile: same-file Age projects through .value alongside imports"
  )
}

test "deriveFile single-file entry still derives same-file distinct (#3287)" {
  // The no-imports wrapper must be unchanged behaviour: same-file distinct works.
  val src = "package P\ntype Age = Int\n@derive(Ord)\nrecord Person { age: Age }\n"
  val sf = deriveFile(parse(src).file)
  assertEqualInt(
    countMemberNamedInFunc(sf, "Person.compare", "value"),
    4,
    "deriveFile-wrapper: same-file Age still projects through .value"
  )
}

// Runtime coverage (#3186): this module itself is compiled through the
// self-hosted pipeline, so the derived compare below exercises the projection
// at runtime.  Allocation order deliberately opposes value order — a regression
// back to reference comparison flips the expected signs.
type TestAge = Int

@derive(Ord)
record OrdPerson {
  age: TestAge
  name: String
}

test "ord record distinct field compares by value at runtime (#3186)" {
  val p1 = OrdPerson(age = TestAge(40), name = "amy")
  val p2 = OrdPerson(age = TestAge(30), name = "zed")
  assertEqualInt(p1.compare(p2), 1, "runtime-ord: 40 > 30 despite allocation order")
  assertEqualInt(p2.compare(p1), -1, "runtime-ord: 30 < 40 despite allocation order")
  val q1 = OrdPerson(age = TestAge(25), name = "amy")
  val q2 = OrdPerson(age = TestAge(25), name = "amy")
  assertEqualInt(q1.compare(q2), 0, "runtime-ord: equal values in distinct wrappers compare 0")
  val r2 = OrdPerson(age = TestAge(25), name = "bob")
  assertEqualInt(q1.compare(r2), -1, "runtime-ord: equal ages fall through to name")
  assertEqualInt(r2.compare(q1), 1, "runtime-ord: name comparison reversed")
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
