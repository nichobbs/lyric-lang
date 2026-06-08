//! jvm/codegen_3_match.l — Jvm.Codegen: match-expression lowering.
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
    // Fix the result-slot type from the first *value-producing* (non-terminating)
    // arm, so a leading `return`-only arm does not force the whole match to Unit.
    match resultTy {
      case JVoid -> {
        if not armTerminated {
          resultTy = armTy
        }
      }
      case _ -> ()
    }
    if not armTerminated {
      match resultTy {
        case JVoid -> ()
        case _ -> {
          if rslot < 0 {
            rslot = allocSlot(ctx, rslotName, resultTy)
          }
          coerceArgTo(insns, armTy, resultTy)
          emitStore(insns, rslot, resultTy)
        }
      }
      insns.add(LGoto(label = afterL))
    }
    insns.add(LLabel(name = nextArmL))
    i = i + 1
  }

  // If no arm matched: panic.
  insns.add(LPushString(s = "Jvm.Codegen: match not exhaustive"))
  emitPanicFromStack(ctx, insns)

  insns.add(LLabel(name = afterL))
  match resultTy {
    case JVoid -> ()
    case _ -> {
      if rslot >= 0 {
        emitResultLoad(insns, rslot, resultTy)
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
func resolveCaseClassJvm(ctx: in FuncCtx, head: in ModulePath, scrutTy: in JvmType): String {
  val caseName = lastSegment(head)
  match scrutTy {
    case JRef(baseCls) -> {
      if not (baseCls == "java/lang/Object") and not (baseCls == "java/util/ArrayList") {
        baseCls + "$" + caseName
      } else {
        match mapGet(ctx.ctors, caseName) {
          case Some(cls) -> cls
          case None -> ""
        }
      }
    }
    case _ -> match mapGet(ctx.ctors, caseName) { case Some(cls) -> cls; case None -> "" }
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
          // A single-segment `case Foo ->` parses as a binding; if `Foo` names a
          // known union case, emit the isinst test that `PConstructor` would, so
          // it does not behave as an unconditional catch-all and hijack later
          // arms.  Otherwise it is a genuine variable bind — always matches.
          match mapGet(ctx.ctors, name) {
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
          emitLoad(insns, scrutSlot, scrutTy)
          // The receiver of String.equals must be statically a String; narrow an
          // erased/boxed scrutinee (e.g. a tuple element) before the call.
          match scrutTy {
            case JRef(c) -> {
              if not (c == "java/lang/String") {
                insns.add(LCheckcast(className = "java/lang/String"))
              }
            }
            case _ -> ()
          }
          insns.add(LPushString(s = s))
          val eqPs: List[JvmType] = newList()
          eqPs.add(JRef(className = "java/lang/Object"))
          insns.add(LInvokevirtual(owner = "java/lang/String", name = "equals", params = eqPs, ret = JBoolean))
          insns.add(LIfeq(label = failLabel))
        }
        case LUnit -> {
          // Unit always matches.
          insns.add(LNop)
        }
        case _ -> {
          // Other literal forms (triple/raw strings) compare structurally as
          // strings via their text; handled by the LString arm in practice.
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
      match mapGet(ctx.ctors, lastSegment(head)) {
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
      val testTy = typeExprToJvm(ty, ctx.pkgName)
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
          val isCase = match mapGet(ctx.ctors, name) { case Some(cls) -> jvmClassIsUnionCase(cls); case None -> false }
          if not isCase {
            emitLoad(insns, scrutSlot, scrutTy)
            val bindSlot = allocSlot(ctx, name, scrutTy)
            emitStore(insns, bindSlot, scrutTy)
          }
        }
      }
    }
    case PLiteral(_) -> insns.add(LNop)
    case PRange(_, _, _) -> insns.add(LNop)
    case PParen(inner) -> lowerPatternBind(ctx, insns, inner, scrutSlot, scrutTy)
    case PTypeTest(inner, ty) -> {
      // Narrow the scrutinee to the tested type, then bind the inner pattern at
      // that precise type.
      val testTy = typeExprToJvm(ty, ctx.pkgName)
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
      match mapGet(ctx.ctors, lastSegment(head)) {
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
