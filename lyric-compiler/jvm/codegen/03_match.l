//! jvm/codegen/03_match.l — Jvm.Codegen: match-expression lowering.
//!
//! Part of the Jvm.Codegen package (split from codegen.l; see docs/44 J0).
//! Match lowering plus pattern test/bind helpers.
package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi

// ─────────────────────────────────────────────────────────────────────────────
// §5e. Match expression lowering.
//      Bootstrap-grade: handles literal and binding patterns only.
// ─────────────────────────────────────────────────────────────────────────────
func lowerMatchExpr(ctx: in FuncCtx, insns: in List[LInsn], scrutinee: in Expr, arms: in List[MatchArm]): JvmType {
  val scrutTy = lowerExpr(ctx, insns, scrutinee)
  val scrutSlot = allocSlot(ctx, "__scrut_" + toString(ctx.slotTicker.count), scrutTy)
  emitStore(insns, scrutSlot, scrutTy)

  val afterL = freshLabel(ctx)
  var resultTy: JvmType = JVoid
  // Value-producing match arms route their value through a result local so the
  // operand stack is empty at the `afterL` join (the StackMapTable declares an
  // empty stack at branch targets — see lowerIfExpr).  Allocated lazily once the
  // first arm reveals the value type; `-1` until then / for Unit-typed matches.
  val rslotName = "__match_r_" + afterL
  var rslot = -1
  // Whether ANY arm can fall through to the `afterL` join.  When every arm
  // terminates (each ends in `return` / `throw`), no `goto afterL` is emitted,
  // the join is unreachable, and landing the `afterL` label would leave an
  // unreachable branch target at the past-end bytecode offset whose
  // StackMapTable frame points past the method body (VerifyError, #2870).
  var anyArmFellThrough = false
  // Whether the FIRST non-terminating arm has fixed `resultTy`.  Statement-
  // position matches legally mix void and value arms (`case Some(v) ->
  // xs.add(v); case None -> ()` — `add` returns boolean); once the first
  // fall-through arm fixes the type, later arms reconcile to it instead of
  // flipping it: a value arm under a void match discards its value, and a
  // void arm under a value match stores a dummy default so the result slot
  // is written on every path (an unwritten slot merges to TOP and the
  // `iload` at the join fails verification).
  var resultTyFixed = false

  var i = 0
  while i < arms.count {
    val arm = arms[i]
    val nextArmL = freshLabel(ctx)
    // Emit pattern test.
    lowerPatternTest(ctx, insns, arm.pattern, scrutSlot, scrutTy, nextArmL)
    // Bind pattern variables.
    lowerPatternBind(ctx, insns, arm.pattern, scrutSlot, scrutTy)
    // Emit guard if present.
    match arm.guard {
      case Some(g) -> {
        lowerExpr(ctx, insns, g)
        insns.add(LIfeq(label = nextArmL))
      }
      case None -> {
        insns.add(LNop)
      }
    }
    // Emit arm body.  The first value-producing arm fixes the result-slot type;
    // every later arm coerces its value to that type before the store.  A
    // generic-payload arm (`case Ok(v) -> v`) is erased to `Object`, so a sibling
    // primitive-literal arm (`case Err(_) -> -1`) is boxed to `Object` by
    // `coerceArgTo` rather than stored raw — storing an `int` into a
    // reference-typed result local would otherwise fail verification.
    val armTy = lowerExprOrBlock(ctx, insns, arm.body)
    // An arm whose body already terminated control flow (e.g. the `?`-propagation
    // `case Err(e) -> return Err(e)`) left nothing on the stack and must not run
    // the result-store / fall-through `goto`: doing so would pop an empty stack
    // (VerifyError) and emit dead, unreachable bytecode after the `areturn`.
    val armTerminated = endsWithReturn(insns)
    // Fix the result-slot type from the first non-terminating arm, so a
    // leading `return`-only arm does not force the whole match to Unit and a
    // later arm cannot flip an already-fixed type (see `resultTyFixed`).
    if not armTerminated and not resultTyFixed {
      resultTy = armTy
      resultTyFixed = true
    }
    if not armTerminated {
      match resultTy {
        case JVoid -> {
          // Void match: a value-producing arm's result is discarded (the
          // statement-position `case Some(v) -> xs.add(v)` shape — `add`
          // returns boolean).
          discardValue(insns, armTy)
        }
        case _ -> {
          if rslot < 0 {
            rslot = allocSlot(ctx, rslotName, resultTy)
          }
          match armTy {
            case JVoid -> {
              // This arm produced no value but the match is value-typed:
              // store a dummy default so the result slot is written on
              // every path reaching the join.
              pushDefaultValue(insns, resultTy)
            }
            case _ -> coerceArgTo(insns, armTy, resultTy)
          }
          emitStore(insns, rslot, resultTy)
        }
      }
      insns.add(LGoto(label = afterL))
      anyArmFellThrough = true
    }
    insns.add(LLabel(name = nextArmL))
    i = i + 1
  }

  // If no arm matched: panic.
  insns.add(LPushString(s = "Jvm.Codegen: match not exhaustive"))
  emitPanicFromStack(ctx, insns)

  // Land the join only when some arm can reach it.  When every arm terminated,
  // the match is itself terminating: emitting `afterL` here would create the
  // past-end unreachable frame described above (#2870).
  if anyArmFellThrough {
    insns.add(LLabel(name = afterL))
    match resultTy {
      case JVoid -> ()
      case _ -> {
        if rslot >= 0 {
          emitResultLoad(insns, rslot, resultTy)
        }
      }
    }
  }
  resultTy
}

// Resolve the JVM case-class name for a `PConstructor` / nullary-binding
// pattern.  Normally the scrutinee's static type names the union interface
// (`Pkg/Shape`), so the case class is `<iface>$<case>`.  When the scrutinee is
// erased to `Object` / `ArrayList` (e.g. a tuple element), fall back to the
// constructor registry (keyed by the case's short name).  Returns "" when
// unresolvable.
// Simple name of a JVM internal class path (`Std/Yaml/YamlError` ->
// `YamlError`).
func jvmSimpleName(cls: in String): String {
  match lastIndexOf(cls, "/") {
    // 3-arg substring: the stage-0 F# mint's checker resolves only one
    // overload per name and rejects the 2-arg convenience form (T0042).
    case Some(i) -> substring(cls, i + 1, cls.length - i - 1)
    case None -> cls
  }
}

func resolveCaseClassJvm(ctx: in FuncCtx, head: in ModulePath, scrutTy: in JvmType): String {
  val caseName = lastSegment(head)
  match scrutTy {
    case JRef(baseCls) -> {
      if not (baseCls == "java/lang/Object") and not (baseCls == "java/util/ArrayList") {
        // The scrutinee's static class may be the in-package GUESS for an
        // imported union (a record field typed by another package's union
        // maps to `<ownPkg>/<Union>` — e.g. `Std/JsonHost/YamlValue` for
        // Std.Yaml's `YamlValue`).  Deriving `<guess>$<case>` then names a
        // class that does not exist (VerifyError / NoClassDefFoundError at
        // load).  The derived name is trusted only when it is a registered
        // case class; otherwise the ctor registry — built from the actual
        // union declarations across the whole bundle — is authoritative.
        val derived = baseCls + "$" + caseName
        if ctx.caseFields.containsKey(derived) {
          derived
        } else {
          // The guess carries the right UNION name with the wrong package
          // (`Std/JsonHost/YamlError` for Std.Yaml's `YamlError`): search
          // the registered case classes for `…/<Union>$<case>` so a match
          // on an imported union resolves to its declaring package even
          // when ANOTHER package registered a same-named case first
          // (`InvalidDocument` exists in both XmlError and YamlError).
          val unionName = jvmSimpleName(baseCls)
          val wantSuffix = "/" + unionName + "$" + caseName
          var found = ""
          for k in mapKeys(ctx.caseFields) {
            if found == "" and endsWith(k, wantSuffix) {
              found = k
            }
          }
          if found != "" {
            found
          } else {
            match ctorClassFor(ctx, caseName) {
              case Some(cls) -> cls
              case None -> derived
            }
          }
        }
      } else {
        match ctorClassFor(ctx, caseName) {
          case Some(cls) -> cls
          case None -> ""
        }
      }
    }
    case _ -> match ctorClassFor(ctx, caseName) { case Some(cls) -> cls; case None -> "" }
  }
}

// Read tuple element `idx` from the `ArrayList` tuple in `tupSlot` into a fresh
// `Object` local and return its slot.  Used by `PTuple` test and bind.
func extractTupleElem(ctx: in FuncCtx, insns: in List[LInsn], tupSlot: in Int, tupTy: in JvmType, idx: in Int): Int {
  emitLoad(insns, tupSlot, tupTy)
  insns.add(LCheckcast(className = "java/util/ArrayList"))
  insns.add(LIconst(v = idx))
  val getPs: List[JvmType] = newList()
  getPs.add(JInt)
  insns.add(
    LInvokevirtual(
      owner = "java/util/ArrayList",
      name = "get",
      params = getPs,
      ret = JRef(className = "java/lang/Object")
    )
  )
  val elemSlot = allocSlot(
    ctx,
    "__tupelem_" + toString(idx) + "_" + toString(ctx.slotTicker.count),
    JRef(className = "java/lang/Object")
  )
  emitStore(insns, elemSlot, JRef(className = "java/lang/Object"))
  elemSlot
}

// True when `ty` is a (possibly boxed) reference rather than a stack primitive.
func isRefJvm(ty: in JvmType): Bool {
  match ty {
    case JRef(_) -> true
    case JArray(_) -> true
    case _ -> false
  }
}

// The numeric width an integer/float literal denotes — used to pick the
// comparison and (un)box width for a `PRange` whose scrutinee is erased.
func rangeBoundTypeJvm(e: in Expr): JvmType {
  match e.kind {
    case ELiteral(lit) -> {
      match lit {
        case LInt(_, suffix, _) -> match suffix { case I64 -> JLong; case U64 -> JLong; case _ -> JInt }
        case LFloat(_, _, _) -> JDouble
        case _ -> JInt
      }
    }
    case _ -> JInt
  }
}

// The numeric type a `PRange` test should compare at: the scrutinee's own width
// when it is a stack primitive, else (an erased/boxed tuple element) the width
// the range bounds denote — never a hard-coded `int`.
func rangeNumericTypeJvm(scrutTy: in JvmType, lo: in Expr): JvmType {
  match scrutTy {
    case JLong -> JLong
    case JDouble -> JDouble
    case JFloat -> JDouble
    case JInt -> JInt
    case JByte -> JInt
    case JChar -> JInt
    case JShort -> JInt
    case _ -> rangeBoundTypeJvm(lo)
  }
}

// Read field `fieldName` (declared type `fty`) of record/case class `cls` from
// the value in `scrutSlot` into a fresh local and return its slot.  Used to
// recurse pattern tests/binds into a record field.
func extractClassField(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  scrutSlot: in Int,
  scrutTy: in JvmType,
  cls: in String,
  fieldName: in String,
  fty: in JvmType,
): Int {
  emitLoad(insns, scrutSlot, scrutTy)
  insns.add(LCheckcast(className = cls))
  insns.add(LGetfield(owner = cls, name = fieldName, t = fty))
  val fSlot = allocSlot(ctx, "__rfld_" + fieldName + "_" + toString(ctx.slotTicker.count), fty)
  emitStore(insns, fSlot, fty)
  fSlot
}

// Compare the scrutinee in `scrutSlot` against a String literal pattern's
// payload via String.equals; jumps to `failLabel` on mismatch.  Shared by the
// LString / LTripleString / LRawString arms — all three carry a plain String.
func emitStringLiteralTest(
  insns: in List[LInsn],
  s: in String,
  scrutSlot: in Int,
  scrutTy: in JvmType,
  failLabel: in String,
): Unit {
  emitLoad(insns, scrutSlot, scrutTy)
  // The receiver of String.equals must be statically a String.  Narrow
  // unconditionally: a plain astore erases an object local to
  // java/lang/Object in the StackMapTable frames (see emitResultLoad), so
  // even a String-typed scrutinee slot reads back as Object at every arm
  // after the first branch target — skipping the checkcast for a
  // JRef("java/lang/String") scrutTy fails verification there.  The cast is
  // a no-op at runtime for a real String.
  insns.add(LCheckcast(className = "java/lang/String"))
  insns.add(LPushString(s = s))
  val eqPs: List[JvmType] = newList()
  eqPs.add(JRef(className = "java/lang/Object"))
  insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
  insns.add(LIfeq(label = failLabel))
}

// Emit a runtime test for a pattern.  Jumps to `failLabel` if the test
// fails.  The scrutinee is in local slot `scrutSlot` with type `scrutTy`.
func lowerPatternTest(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  pat: in Pattern,
  scrutSlot: in Int,
  scrutTy: in JvmType,
  failLabel: in String,
): Unit {
  match pat.kind {
    case PWildcard -> insns.add(LNop)
    case PBinding(name, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> lowerPatternTest(ctx, insns, inner, scrutSlot, scrutTy, failLabel)
        case None -> {
          // `case null ->` on a nullable scrutinee (`String?`) parses as a
          // binding named "null" ("null" is not a keyword); the spec intent —
          // and the stdlib's usage in Std.Console.readLine / Std.Environment
          // — is a refutable null TEST.  Without this the arm bound anything
          // and hijacked every later arm (Std.Console.readLine returned
          // EndOfInput for real lines).
          if name == "null" {
            emitLoad(insns, scrutSlot, scrutTy)
            insns.add(LIfnonnull(label = failLabel))
            return
          }
          // A single-segment `case Foo ->` parses as a binding; if `Foo` names a
          // known union case, emit the isinst test that `PConstructor` would, so
          // it does not behave as an unconditional catch-all and hijack later
          // arms.  Otherwise it is a genuine variable bind — always matches.
          match ctorClassFor(ctx, name) {
            case Some(cls) -> {
              if jvmClassIsUnionCase(cls) {
                emitLoad(insns, scrutSlot, scrutTy)
                insns.add(LInstanceof(className = cls))
                insns.add(LIfeq(label = failLabel))
              }
            }
            case None -> ()
          }
        }
      }
    }
    case PLiteral(lit) -> {
      val scrutIsRef = isRefJvm(scrutTy)
      match lit {
        case LInt(v, suffix, _) -> {
          // Match the scrutinee width: an `i64`/`u64`-suffixed pattern literal
          // (or one outside Int32 range) compares as a long (lcmp), else as an
          // int (if_icmpne).  A boxed scrutinee (e.g. a tuple element) is
          // checkcast to its wrapper and unboxed first.
          val useLong = match suffix { case I64 -> true; case U64 -> true; case _ -> (v < -2147483648i64 or v > 2147483647i64) }
          emitLoad(insns, scrutSlot, scrutTy)
          if useLong {
            if scrutIsRef {
              insns.add(LCheckcast(className = "java/lang/Long"))
              insns.add(LUnboxLong)
            }
            insns.add(LLconst(v = v))
            insns.add(LLcmp)
            insns.add(LIfne(label = failLabel))
          } else {
            if scrutIsRef {
              insns.add(LCheckcast(className = "java/lang/Integer"))
              insns.add(LUnboxInt)
            }
            insns.add(LIconst(v = longToInt(v)))
            insns.add(LIfIcmpne(label = failLabel))
          }
        }
        case LBool(value) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          if scrutIsRef {
            insns.add(LCheckcast(className = "java/lang/Boolean"))
            insns.add(LUnboxBool)
          }
          if value {
            insns.add(LIconst(v = 1))
          } else {
            insns.add(LIconst(v = 0))
          }
          insns.add(LIfIcmpne(label = failLabel))
        }
        case LChar(cp) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          if scrutIsRef {
            insns.add(LCheckcast(className = "java/lang/Character"))
            insns.add(LUnboxChar)
          }
          insns.add(LIconst(v = cp))
          insns.add(LIfIcmpne(label = failLabel))
        }
        case LFloat(fv, _, _) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          if scrutIsRef {
            insns.add(LCheckcast(className = "java/lang/Double"))
            insns.add(LUnboxDouble)
          }
          insns.add(LDconst(v = fv))
          insns.add(LDcmpl)
          insns.add(LIfne(label = failLabel))
        }
        case LString(s) -> {
          emitStringLiteralTest(insns, s, scrutSlot, scrutTy, failLabel)
        }
        case LTripleString(s) -> {
          // Triple-quoted and raw string literals carry a plain String payload,
          // so they compare exactly like LString (#1792).
          emitStringLiteralTest(insns, s, scrutSlot, scrutTy, failLabel)
        }
        case LRawString(s) -> {
          emitStringLiteralTest(insns, s, scrutSlot, scrutTy, failLabel)
        }
        case LUnit -> {
          // Unit always matches.
          insns.add(LNop)
        }
      }
    }
    case PRange(lo, inclusive, hi) -> {
      // Numeric range test: fail unless `lo <= scrut (<|<=) hi`.  The comparison
      // width is the scrutinee's own (int / long / double); for an erased
      // (boxed) scrutinee — e.g. a tuple element — it is taken from the range
      // bounds so a Long/Double range is not silently truncated to int.
      val numTy = rangeNumericTypeJvm(scrutTy, lo)
      match numTy {
        case JLong -> {
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JLong)
          val loTy = lowerExpr(ctx, insns, lo)
          coerceArgTo(insns, loTy, JLong)
          insns.add(LLcmp)
          insns.add(LIflt(label = failLabel))   // scrut < lo
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JLong)
          val hiTy = lowerExpr(ctx, insns, hi)
          coerceArgTo(insns, hiTy, JLong)
          insns.add(LLcmp)
          if inclusive {
            insns.add(LIfgt(label = failLabel))
          } else {
            insns.add(LIfge(label = failLabel))
          }
        }
        case JDouble -> {
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JDouble)
          val loTy = lowerExpr(ctx, insns, lo)
          coerceArgTo(insns, loTy, JDouble)
          insns.add(LDcmpl)
          insns.add(LIflt(label = failLabel))
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JDouble)
          val hiTy = lowerExpr(ctx, insns, hi)
          coerceArgTo(insns, hiTy, JDouble)
          insns.add(LDcmpl)
          if inclusive {
            insns.add(LIfgt(label = failLabel))
          } else {
            insns.add(LIfge(label = failLabel))
          }
        }
        case _ -> {
          // Int (and narrower int-on-stack) scrutinee.
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JInt)
          val loTy = lowerExpr(ctx, insns, lo)
          coerceArgTo(insns, loTy, JInt)
          insns.add(LIfIcmplt(label = failLabel))   // scrut < lo
          emitLoad(insns, scrutSlot, scrutTy)
          coerceArgTo(insns, scrutTy, JInt)
          val hiTy = lowerExpr(ctx, insns, hi)
          coerceArgTo(insns, hiTy, JInt)
          if inclusive {
            insns.add(LIfIcmpgt(label = failLabel))
          } else {
            insns.add(LIfIcmpge(label = failLabel))
          }
        }
      }
    }
    case PConstructor(head, _) -> {
      // isinst test against the case class; fail if the scrutinee is not that
      // case.  (Unlike a checkcast this never throws on a non-matching arm.)
      val caseClass = resolveCaseClassJvm(ctx, head, scrutTy)
      if caseClass.length > 0 {
        emitLoad(insns, scrutSlot, scrutTy)
        insns.add(LInstanceof(className = caseClass))
        insns.add(LIfeq(label = failLabel))
      } else {
        insns.add(LNop)
      }
    }
    case PRecord(head, fields, _) -> {
      // Records have a single shape: an isinst against the record class (from
      // the head via the constructor registry), then recurse each named field's
      // sub-pattern test so refutable field patterns (`Point{x = 0}`) are
      // honoured rather than silently always-matching.
      match ctorClassFor(ctx, lastSegment(head)) {
        case Some(recClass) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LInstanceof(className = recClass))
          insns.add(LIfeq(label = failLabel))
          var fi = 0
          while fi < fields.count {
            match fields[fi] {
              case RPFNamed(fieldName, subPat, _) -> {
                val fty = match recordFieldType(ctx, recClass, fieldName) {
                  case Some(t) -> t
                  case None -> JRef(className = "java/lang/Object")
                }
                val fSlot = extractClassField(ctx, insns, scrutSlot, scrutTy, recClass, fieldName, fty)
                lowerPatternTest(ctx, insns, subPat, fSlot, fty, failLabel)
              }
              case RPFShort(_, _) -> ()
            }
            fi = fi + 1
          }
        }
        case None -> insns.add(LNop)
      }
    }
    case PTuple(patterns) -> {
      // A tuple structurally matches; recurse the test into each element so
      // refutable sub-patterns (literals, ranges, nested cases) are honoured.
      var pti = 0
      while pti < patterns.count {
        val elemSlot = extractTupleElem(ctx, insns, scrutSlot, scrutTy, pti)
        lowerPatternTest(ctx, insns, patterns[pti], elemSlot, JRef(className = "java/lang/Object"), failLabel)
        pti = pti + 1
      }
    }
    case PParen(inner) -> lowerPatternTest(ctx, insns, inner, scrutSlot, scrutTy, failLabel)
    case PTypeTest(_, ty) -> {
      // `case x: T ->` — isinst against T.  Primitive T is a degenerate test
      // (a value of that static type always matches), so emit no test.
      val testTy = typeExprToJvmExtern(ty, ctx.pkgName, ctx.externTypes)
      match testTy {
        case JRef(cls) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LInstanceof(className = cls))
          insns.add(LIfeq(label = failLabel))
        }
        case _ -> insns.add(LNop)
      }
    }
    case POr(patterns) -> {
      // Or-pattern: succeed if any alternative matches.
      val succeedL = freshLabel(ctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabel(ctx)
        lowerPatternTest(ctx, insns, patterns[ai], scrutSlot, scrutTy, nextAltL)
        insns.add(LGoto(label = succeedL))
        insns.add(LLabel(name = nextAltL))
        ai = ai + 1
      }
      insns.add(LGoto(label = failLabel))
      insns.add(LLabel(name = succeedL))
    }
    case PConstRef(constName) -> {
      match mapGet(ctx.moduleVals, constName) {
        case Some(vty) -> {
          val scrutIsRef = isRefJvm(scrutTy)
          match vty {
            case JLong -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Long"))
                insns.add(LUnboxLong)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LLcmp)
              insns.add(LIfne(label = failLabel))
            }
            case JDouble -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Double"))
                insns.add(LUnboxDouble)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LDcmpl)
              insns.add(LIfne(label = failLabel))
            }
            case JFloat -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Float"))
                insns.add(LUnboxFloat)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LFcmpl)
              insns.add(LIfne(label = failLabel))
            }
            case JRef(refClassName) -> {
              emitLoad(insns, scrutSlot, scrutTy)
              insns.add(LCheckcast(className = refClassName))
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              val eqPs: List[JvmType] = newList()
              eqPs.add(JRef(className = "java/lang/Object"))
              insns.add(LInvokevirtual(owner = refClassName, name = "equals", params = eqPs, ret = JBoolean))
              insns.add(LIfeq(label = failLabel))
            }
            case JBoolean -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Boolean"))
                insns.add(LUnboxBool)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LIfIcmpne(label = failLabel))
            }
            case JChar -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Character"))
                insns.add(LUnboxChar)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LIfIcmpne(label = failLabel))
            }
            case _ -> {
              emitLoad(insns, scrutSlot, scrutTy)
              if scrutIsRef {
                insns.add(LCheckcast(className = "java/lang/Integer"))
                insns.add(LUnboxInt)
              }
              insns.add(LGetstatic(owner = ctx.pkgName, name = constName, t = vty))
              insns.add(LIfIcmpne(label = failLabel))
            }
          }
        }
        case None -> panic("lowerPatternTest (JVM): PConstRef name not found in moduleVals (type checker should have validated)")
      }
    }
    case PError -> insns.add(LNop)
  }
}

// Bind one positional/named sub-pattern of a constructor/record: read the field
// into a precisely-typed local, then recurse for nested patterns.
func bindCaseField(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  castSlot: in Int,
  caseClass: in String,
  realName: in String,
  fty: in JvmType,
  subPat: in Pattern,
): Unit {
  match subPat.kind {
    case PBinding(fname, innerOpt) -> {
      emitLoad(insns, castSlot, JRef(className = caseClass))
      insns.add(LGetfield(owner = caseClass, name = realName, t = fty))
      val fSlot = allocSlot(ctx, fname, fty)
      emitStore(insns, fSlot, fty)
      match innerOpt {
        case Some(inner) -> lowerPatternBind(ctx, insns, inner, fSlot, fty)
        case None -> ()
      }
    }
    case PWildcard -> ()
    case PLiteral(_) -> ()
    case _ -> {
      // Nested destructuring (tuple / record / constructor) in field position:
      // read the field into a temp local and recurse.
      emitLoad(insns, castSlot, JRef(className = caseClass))
      insns.add(LGetfield(owner = caseClass, name = realName, t = fty))
      val tSlot = allocSlot(ctx, "__fld_" + realName + "_" + toString(ctx.slotTicker.count), fty)
      emitStore(insns, tSlot, fty)
      lowerPatternBind(ctx, insns, subPat, tSlot, fty)
    }
  }
}

// Bind pattern variables after a successful match.
func lowerPatternBind(
  ctx: in FuncCtx, insns: in List[LInsn], pat: in Pattern, scrutSlot: in Int, scrutTy: in JvmType
): Unit {
  match pat.kind {
    case PWildcard -> insns.add(LNop)
    case PBinding(name, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          val bindSlot = allocSlot(ctx, name, scrutTy)
          emitStore(insns, bindSlot, scrutTy)
          lowerPatternBind(ctx, insns, inner, bindSlot, scrutTy)
        }
        case None -> {
          // A single-segment `case Foo ->` that names a known union case binds
          // nothing (mirrors the test side); otherwise it is a variable bind.
          val isCase = match ctorClassFor(ctx, name) { case Some(cls) -> jvmClassIsUnionCase(cls); case None -> false }
          if not isCase {
            emitLoad(insns, scrutSlot, scrutTy)
            val bindSlot = allocSlot(ctx, name, scrutTy)
            emitStore(insns, bindSlot, scrutTy)
          }
        }
      }
    }
    case PLiteral(_) -> insns.add(LNop)
    case PConstRef(_) -> insns.add(LNop)
    case PRange(_, _, _) -> insns.add(LNop)
    case PParen(inner) -> lowerPatternBind(ctx, insns, inner, scrutSlot, scrutTy)
    case PTypeTest(inner, ty) -> {
      // Narrow the scrutinee to the tested type, then bind the inner pattern at
      // that precise type.
      val testTy = typeExprToJvmExtern(ty, ctx.pkgName, ctx.externTypes)
      match testTy {
        case JRef(cls) -> {
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LCheckcast(className = cls))
          val nSlot = allocSlot(ctx, "__typetest_" + toString(ctx.slotTicker.count), testTy)
          emitStore(insns, nSlot, testTy)
          lowerPatternBind(ctx, insns, inner, nSlot, testTy)
        }
        case _ -> lowerPatternBind(ctx, insns, inner, scrutSlot, scrutTy)
      }
    }
    case PConstructor(head, fields) -> {
      val caseClass = resolveCaseClassJvm(ctx, head, scrutTy)
      if caseClass.length > 0 {
        val castSlot = allocSlot(
          ctx,
          "__cast_" + lastSegment(head) + "_" + toString(ctx.slotTicker.count),
          JRef(className = caseClass)
        )
        emitLoad(insns, scrutSlot, scrutTy)
        insns.add(LCheckcast(className = caseClass))
        emitStore(insns, castSlot, JRef(className = caseClass))
        // Bind each positional sub-pattern by reading the case class's i-th
        // field.  The field's *declared* name and type come from the registry
        // (ctx.caseFields) so the getfield resolves and the bound local carries
        // the right static type.  Falls back to (binding-name, Object) only when
        // the case is unavailable.
        val caseInfo: Option[List[JvmCaseField]] = mapGet(ctx.caseFields, caseClass)
        var fi = 0
        while fi < fields.count {
          var realName = match fields[fi].kind { case PBinding(fn, _) -> fn; case _ -> "field" + toString(fi) }
          var fty: JvmType = JRef(className = "java/lang/Object")
          match caseInfo {
            case Some(flds) -> {
              if fi < flds.count {
                realName = flds[fi].name
                fty = flds[fi].ty
              }
            }
            case None -> ()
          }
          bindCaseField(ctx, insns, castSlot, caseClass, realName, fty, fields[fi])
          fi = fi + 1
        }
        insns.add(LNop)
      } else {
        insns.add(LNop)
      }
    }
    case PRecord(head, fields, _) -> {
      match ctorClassFor(ctx, lastSegment(head)) {
        case Some(recClass) -> {
          val castSlot = allocSlot(ctx, "__reccast_" + toString(ctx.slotTicker.count), JRef(className = recClass))
          emitLoad(insns, scrutSlot, scrutTy)
          insns.add(LCheckcast(className = recClass))
          emitStore(insns, castSlot, JRef(className = recClass))
          var fi = 0
          while fi < fields.count {
            // A record pattern field binds by *field name* (`Point{x = a}` or the
            // short form `Point{x}`), not positionally.
            match fields[fi] {
              case RPFNamed(fieldName, subPat, _) -> {
                val fty = match recordFieldType(ctx, recClass, fieldName) {
                  case Some(t) -> t
                  case None -> JRef(className = "java/lang/Object")
                }
                bindCaseField(ctx, insns, castSlot, recClass, fieldName, fty, subPat)
              }
              case RPFShort(fieldName, _) -> {
                // `Point{x}` binds local `x` to field `x`.
                val fty = match recordFieldType(ctx, recClass, fieldName) {
                  case Some(t) -> t
                  case None -> JRef(className = "java/lang/Object")
                }
                emitLoad(insns, castSlot, JRef(className = recClass))
                insns.add(LGetfield(owner = recClass, name = fieldName, t = fty))
                val fSlot = allocSlot(ctx, fieldName, fty)
                emitStore(insns, fSlot, fty)
              }
            }
            fi = fi + 1
          }
          insns.add(LNop)
        }
        case None -> insns.add(LNop)
      }
    }
    case PTuple(patterns) -> {
      // Extract each element from the ArrayList tuple representation and bind it.
      var pti = 0
      while pti < patterns.count {
        val elemSlot = extractTupleElem(ctx, insns, scrutSlot, scrutTy, pti)
        lowerPatternBind(ctx, insns, patterns[pti], elemSlot, JRef(className = "java/lang/Object"))
        pti = pti + 1
      }
    }
    case POr(patterns) -> {
      // Or-pattern bind: the test side has already proven *some* alternative
      // matches, but not which one.  Re-test each alternative at runtime and
      // bind from the matching alternative only.  The type-checker guarantees
      // every alternative binds the same variable name(s) and type(s), so any
      // matching alternative populates the same locals the arm body reads.
      val doneL = freshLabel(ctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabel(ctx)
        lowerPatternTest(ctx, insns, patterns[ai], scrutSlot, scrutTy, nextAltL)
        lowerPatternBind(ctx, insns, patterns[ai], scrutSlot, scrutTy)
        insns.add(LGoto(label = doneL))
        insns.add(LLabel(name = nextAltL))
        ai = ai + 1
      }
      insns.add(LLabel(name = doneL))
    }
    case PError -> insns.add(LNop)
  }
}
