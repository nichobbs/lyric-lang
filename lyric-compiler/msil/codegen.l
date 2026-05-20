// msil/codegen.l — Msil.Codegen
//
// Bootstrap-grade AST-to-MSIL-IR lowering for the Lyric self-hosted compiler.
// Walks a parsed `SourceFile` (from Lyric.Parser) and produces an `MPackage`
// (from Msil.Lowering) suitable for further lowering to PE bytes by
// `Msil.Lowering.lowerMPackageWithCtx`.
//
// Supported in this bootstrap pass:
//   • Simple functions — arithmetic, locals, if/else, while
//   • Hello-world programs (main with println)
//   • Record types with fields
//   • Union types (lowered to sealed-union IR)
//   • Basic builtin calls: println, print, panic, toString, assert, newList,
//     newMap, mapGet, default, format1..format3, intToLong, longToInt, charToInt
//   • Interpolated strings via String.Concat chains
//   • Match expressions with literal and binding patterns
//   • Constructor calls and field access
//
// Unsupported forms panic at codegen time so failures are visible rather than
// silently wrong.
//
// MSIL vs JVM differences captured here:
//   • MLdloc/MStloc for locals (slot 0-based within locals list).
//   • MLdarg for parameters (slot 0-based within params list).
//   • MRet for all return types.
//   • MLdStr(token) where token = 0x70000000 | US heap offset.
//   • MCeq/MClt/MCgt + XOR for comparison results.
//   • MNewobj(ctorToken) for construction; MBox(typeToken) for boxing.

package Msil.Codegen

import Std.Core
import Std.Collections
import Std.String
import Lyric.Parser
import Msil.Lowering
import Msil.Ffi

// ─────────────────────────────────────────────────────────────────────────────
// §1. CodegenCtx — package-level context with pre-registered external tokens.
// ─────────────────────────────────────────────────────────────────────────────

// CodegenCtx holds a LoweringCtx pre-seeded with all external TypeRef and
// MemberRef rows needed by the code generator.  Tokens are stable integer
// constants computed once in `newCodegenCtx` so that every instruction
// site can embed them directly without re-scanning the table.
pub record CodegenCtx {
  lctx:               LoweringCtx
  // TypeRef row indices (1-based)
  trConsole:          Int   // System.Console
  trString:           Int   // System.String
  trInt32:            Int   // System.Int32
  trInt64:            Int   // System.Int64
  trDouble:           Int   // System.Double
  trBoolean:          Int   // System.Boolean
  trException:        Int   // System.Exception
  // MemberRef tokens (0x0A000000 | 1-based row)
  tokWriteLineStr:    Int   // Console.WriteLine(string)
  tokWriteLineInt:    Int   // Console.WriteLine(int32)
  tokWriteLineLong:   Int   // Console.WriteLine(int64)
  tokWriteLineDbl:    Int   // Console.WriteLine(double)
  tokWriteLineBool:   Int   // Console.WriteLine(bool)
  tokWriteStr:        Int   // Console.Write(string)
  tokConcat2:         Int   // String.Concat(string,string)
  tokConcat3:         Int   // String.Concat(string,string,string)
  tokExceptionCtor:   Int   // Exception..ctor(string)
  tokStringFormat1:   Int   // String.Format(string,object)
  tokStringFormat2:   Int   // String.Format(string,object,object)
  tokStringFormat3:   Int   // String.Format(string,object,object,object)
  tokObjToString:     Int   // Object.ToString() instance HASTHIS
  // List<object> via TypeSpec (for newList() and list operations)
  tokListObjCtor:     Int   // List<object>::.ctor()  newobj
  tokListObjAdd:      Int   // List<object>::Add(object): void  callvirt
  tokListObjGetItem:  Int   // List<object>::get_Item(int32): object  callvirt
  tokListObjGetCount: Int   // List<object>::get_Count(): int32  callvirt
  // Dictionary<object,object> via TypeSpec (for newMap() and map operations)
  tokDictObjCtor:     Int   // Dictionary<object,object>::.ctor()  newobj
  tokDictObjAdd:      Int   // Dictionary<object,object>::Add(object,object): void  callvirt
  tokDictObjGetItem:  Int   // Dictionary<object,object>::get_Item(object): object  callvirt
  tokDictObjGetCount: Int   // Dictionary<object,object>::get_Count(): int32  callvirt
  tokDictObjContainsKey: Int  // Dictionary<object,object>::ContainsKey(object): bool  callvirt
  tokDictObjTryGetValue: Int  // Dictionary<object,object>::TryGetValue(object, object): bool
  // Intra-package pre-computed tokens
  recordCtorTokens:   Map[String, Int]   // className → MethodDef token
  fieldTokens:        Map[String, Int]   // "ClassName/fieldName" → FieldDef token
  funcTokens:         Map[String, Int]   // funcName → MethodDef token
  funcRetTypes:       Map[String, MsilType]   // funcName → MsilType of declared return
  // FFI caches (#370 + Phase R6).  Populated lazily by
  // emitExternTargetBody as `@externTarget` declarations are walked.
  ffiAsmRefs:         Map[String, Int]   // assembly simple name → AssemblyRef row index
  ffiTypeRefs:        Map[String, Int]   // "asm/ns.name" key → TypeRef row index
}

// Build and return a fresh CodegenCtx for the named package.
// Registers all external AssemblyRef/TypeRef/MemberRef rows in a stable order
// so that every instruction token is a predictable constant.
pub func newCodegenCtx(packageName: in String): CodegenCtx {
  val lctx = newLoweringCtx(packageName)
  // After newLoweringCtx:
  //   arRuntime  = 1  (System.Runtime AssemblyRef)
  //   trObject   = 1  (System.Object TypeRef)

  // AssemblyRef[2]: System.Console
  val arConsole = ctxAddAssemblyRef(lctx, "System.Console", 10, 0)

  // TypeRef rows 2..8
  val trConsole  = ctxAddTypeRef(lctx, "System", "Console",   arConsole)
  val trString   = ctxAddTypeRef(lctx, "System", "String",    lctx.arRuntime)
  val trInt32    = ctxAddTypeRef(lctx, "System", "Int32",     lctx.arRuntime)
  val trInt64    = ctxAddTypeRef(lctx, "System", "Int64",     lctx.arRuntime)
  val trDouble   = ctxAddTypeRef(lctx, "System", "Double",    lctx.arRuntime)
  val trBoolean  = ctxAddTypeRef(lctx, "System", "Boolean",   lctx.arRuntime)
  val trException = ctxAddTypeRef(lctx, "System", "Exception", lctx.arRuntime)

  // Build MemberRef signatures.
  // 1. Console.WriteLine(string): void  → MemberRef[1] → token 0x0A000001
  val wlStrPs: List[MsilType] = newList()
  wlStrPs.add(MString)
  val tokWLStr = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_str", buildStaticMethodSig(wlStrPs, MVoid))

  // 2. Console.WriteLine(int32): void  → 0x0A000002
  val wlIntPs: List[MsilType] = newList()
  wlIntPs.add(MInt)
  val tokWLInt = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_int", buildStaticMethodSig(wlIntPs, MVoid))

  // 3. Console.WriteLine(int64): void  → 0x0A000003
  val wlLongPs: List[MsilType] = newList()
  wlLongPs.add(MLong)
  val tokWLLong = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_long", buildStaticMethodSig(wlLongPs, MVoid))

  // 4. Console.WriteLine(double): void  → 0x0A000004
  val wlDblPs: List[MsilType] = newList()
  wlDblPs.add(MDouble)
  val tokWLDbl = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_dbl", buildStaticMethodSig(wlDblPs, MVoid))

  // 5. Console.WriteLine(bool): void  → 0x0A000005
  val wlBoolPs: List[MsilType] = newList()
  wlBoolPs.add(MBool)
  val tokWLBool = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "WriteLine",
    "wl_bool", buildStaticMethodSig(wlBoolPs, MVoid))

  // 6. Console.Write(string): void  → 0x0A000006
  val wStrPs: List[MsilType] = newList()
  wStrPs.add(MString)
  val tokWStr = 0x0A000000 + ctxAddMemberRef(
    lctx, trConsole, "Write",
    "w_str", buildStaticMethodSig(wStrPs, MVoid))

  // 7. String.Concat(string,string): string  → 0x0A000007
  val concat2Ps: List[MsilType] = newList()
  concat2Ps.add(MString)
  concat2Ps.add(MString)
  val tokConcat2 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Concat",
    "concat2", buildStaticMethodSig(concat2Ps, MString))

  // 8. String.Concat(string,string,string): string  → 0x0A000008
  val concat3Ps: List[MsilType] = newList()
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  concat3Ps.add(MString)
  val tokConcat3 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Concat",
    "concat3", buildStaticMethodSig(concat3Ps, MString))

  // 9. Exception..ctor(string): void  instance HASTHIS  → 0x0A000009
  val excCtorPs: List[MsilType] = newList()
  excCtorPs.add(MString)
  val tokExcCtor = 0x0A000000 + ctxAddMemberRef(
    lctx, trException, ".ctor",
    "exc_ctor", buildInstanceMethodSig(excCtorPs, MVoid))

  // 10. String.Format(string,object): string  → 0x0A00000A
  val fmt1Ps: List[MsilType] = newList()
  fmt1Ps.add(MString)
  fmt1Ps.add(MObject)
  val tokFmt1 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt1", buildStaticMethodSig(fmt1Ps, MString))

  // 11. String.Format(string,object,object): string  → 0x0A00000B
  val fmt2Ps: List[MsilType] = newList()
  fmt2Ps.add(MString)
  fmt2Ps.add(MObject)
  fmt2Ps.add(MObject)
  val tokFmt2 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt2", buildStaticMethodSig(fmt2Ps, MString))

  // 12. String.Format(string,object,object,object): string  → 0x0A00000C
  val fmt3Ps: List[MsilType] = newList()
  fmt3Ps.add(MString)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  fmt3Ps.add(MObject)
  val tokFmt3 = 0x0A000000 + ctxAddMemberRef(
    lctx, trString, "Format",
    "fmt3", buildStaticMethodSig(fmt3Ps, MString))

  // 13. Object.ToString(): string  instance HASTHIS  → 0x0A00000D
  val toStrPs: List[MsilType] = newList()
  val tokObjToStr = 0x0A000000 + ctxAddMemberRef(
    lctx, lctx.trObject, "ToString",
    "obj_tostring", buildInstanceMethodSig(toStrPs, MString))

  // ── List<object> via TypeSpec ──────────────────────────────────────────────
  // AssemblyRef for System.Collections (houses List`1 contract in .NET 10)
  val arCollections = ctxAddAssemblyRef(lctx, "System.Collections", 10, 0)

  // TypeRef for System.Collections.Generic.List`1 (open generic definition)
  val trList1 = ctxAddTypeRef(lctx, "System.Collections.Generic", "List`1", arCollections)

  // TypeSpec: GENERICINST List`1<object>
  val listArgTypes: List[MsilType] = newList()
  listArgTypes.add(MObject)
  val listObjBlob = buildGenericInstBlob(tdrTypeRef(trList1), listArgTypes)
  val tsListObj = ctxAddTypeSpec(lctx, "ts_list_obj", listObjBlob)

  // 14. List<object>::.ctor(): void  instance HASTHIS
  val listCtorPs: List[MsilType] = newList()
  val tokListObjCtor = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, ".ctor", "list_obj_ctor", buildInstanceMethodSig(listCtorPs, MVoid))

  // 15. List<object>::Add(!0): void  — MemberRef on TypeSpec must use ELEMENT_TYPE_VAR
  val listAddPs: List[MsilType] = newList()
  listAddPs.add(MTypeVar(0))
  val tokListObjAdd = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "Add", "list_obj_add", buildInstanceMethodSig(listAddPs, MVoid))

  // 16. List<object>::get_Item(int32): !0  — return type is the generic type param
  val listGetPs: List[MsilType] = newList()
  listGetPs.add(MInt)
  val tokListObjGetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "get_Item", "list_obj_getitem", buildInstanceMethodSig(listGetPs, MTypeVar(0)))

  // 17. List<object>::get_Count(): int32  instance HASTHIS
  val listCntPs: List[MsilType] = newList()
  val tokListObjGetCount = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsListObj, "get_Count", "list_obj_count", buildInstanceMethodSig(listCntPs, MInt))

  // ── Dictionary<object,object> via TypeSpec ────────────────────────────────
  val trDict2 = ctxAddTypeRef(lctx, "System.Collections.Generic", "Dictionary`2", arCollections)

  // TypeSpec: GENERICINST Dictionary`2<object,object>
  val dictArgTypes: List[MsilType] = newList()
  dictArgTypes.add(MObject)
  dictArgTypes.add(MObject)
  val dictObjBlob = buildGenericInstBlob(tdrTypeRef(trDict2), dictArgTypes)
  val tsDictObj = ctxAddTypeSpec(lctx, "ts_dict_obj", dictObjBlob)

  // 18. Dictionary<object,object>::.ctor(): void  instance HASTHIS
  val dictCtorPs: List[MsilType] = newList()
  val tokDictObjCtor = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, ".ctor", "dict_obj_ctor", buildInstanceMethodSig(dictCtorPs, MVoid))

  // 19. Dictionary<object,object>::Add(!0, !1): void  — MemberRef on TypeSpec uses type vars
  val dictAddPs: List[MsilType] = newList()
  dictAddPs.add(MTypeVar(0))
  dictAddPs.add(MTypeVar(1))
  val tokDictObjAdd = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "Add", "dict_obj_add", buildInstanceMethodSig(dictAddPs, MVoid))

  // 20. Dictionary<object,object>::get_Item(!0): !1  — key param !0, value return !1
  val dictGetPs: List[MsilType] = newList()
  dictGetPs.add(MTypeVar(0))
  val tokDictObjGetItem = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "get_Item", "dict_obj_getitem", buildInstanceMethodSig(dictGetPs, MTypeVar(1)))

  // 21. Dictionary<object,object>::get_Count(): int32  instance HASTHIS
  val dictCntPs: List[MsilType] = newList()
  val tokDictObjGetCount = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "get_Count", "dict_obj_count", buildInstanceMethodSig(dictCntPs, MInt))

  // 22. Dictionary<object,object>::ContainsKey(!0): bool  — key param is type var !0
  val dictCkPs: List[MsilType] = newList()
  dictCkPs.add(MTypeVar(0))
  val tokDictObjContainsKey = 0x0A000000 + ctxAddMemberRefForTypeSpec(
    lctx, tsDictObj, "ContainsKey", "dict_obj_ck", buildInstanceMethodSig(dictCkPs, MBool))

  // 23. Dictionary<object,object>::TryGetValue(object, out object): bool  HASTHIS
  // Signature: HASTHIS, 2 params, bool return, object key, byref-object value
  // For bootstrap we use get_Item instead; register as a stub pointing to get_Item sig.
  val tokDictObjTryGetValue = tokDictObjGetItem  // bootstrap: alias to get_Item

  val recCtorToks: Map[String, Int] = newMap()
  val fieldToks:   Map[String, Int] = newMap()
  val funcToks:    Map[String, Int] = newMap()

  CodegenCtx(
    lctx                 = lctx,
    trConsole            = trConsole,
    trString             = trString,
    trInt32              = trInt32,
    trInt64              = trInt64,
    trDouble             = trDouble,
    trBoolean            = trBoolean,
    trException          = trException,
    tokWriteLineStr      = tokWLStr,
    tokWriteLineInt      = tokWLInt,
    tokWriteLineLong     = tokWLLong,
    tokWriteLineDbl      = tokWLDbl,
    tokWriteLineBool     = tokWLBool,
    tokWriteStr          = tokWStr,
    tokConcat2           = tokConcat2,
    tokConcat3           = tokConcat3,
    tokExceptionCtor     = tokExcCtor,
    tokStringFormat1     = tokFmt1,
    tokStringFormat2     = tokFmt2,
    tokStringFormat3     = tokFmt3,
    tokObjToString       = tokObjToStr,
    tokListObjCtor       = tokListObjCtor,
    tokListObjAdd        = tokListObjAdd,
    tokListObjGetItem    = tokListObjGetItem,
    tokListObjGetCount   = tokListObjGetCount,
    tokDictObjCtor       = tokDictObjCtor,
    tokDictObjAdd        = tokDictObjAdd,
    tokDictObjGetItem    = tokDictObjGetItem,
    tokDictObjGetCount   = tokDictObjGetCount,
    tokDictObjContainsKey = tokDictObjContainsKey,
    tokDictObjTryGetValue = tokDictObjTryGetValue,
    recordCtorTokens     = recCtorToks,
    fieldTokens          = fieldToks,
    funcTokens           = funcToks,
    funcRetTypes         = newMap(),
    ffiAsmRefs           = newMap(),
    ffiTypeRefs          = newMap())
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Token pre-scan — addPackageTokens.
// ─────────────────────────────────────────────────────────────────────────────

// Pre-scan the AST and assign MethodDef/FieldDef row numbers for every
// record, function, and union case in the package.  This must be called
// before any `lowerFuncMsil` invocations so that intra-package call and
// field-access tokens are available.
//
// Row numbering convention (matches lowerMRecord / lowerMFuncsToHostClass /
// lowerMUnion in Msil.Lowering):
//   1. IRecord / IExposedRec items (in order): fields then .ctor.
//   2. IFunc items (in order): one MethodDef each.
//   3. IUnion items (in order): each case gets fields then .ctor.
pub func addPackageTokens(cctx: in CodegenCtx, file: in SourceFile,
                          pkgName: in String): Unit {
  var methodDefRow = 1
  var fieldDefRow  = 1

  // Pass 1: records and exposed records.
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        val className = pkgName + "." + decl.name
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              cctx.fieldTokens.add(className + "/" + f.name,
                                   0x04000000 + fieldDefRow)
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
      }
      case IExposedRec(decl) -> {
        val className = pkgName + "." + decl.name
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case RMField(f) -> {
              cctx.fieldTokens.add(className + "/" + f.name,
                                   0x04000000 + fieldDefRow)
              fieldDefRow = fieldDefRow + 1
            }
            case _ -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
      }
      case _ -> {}
    }
    i = i + 1
  }

  // Pass 2: functions.
  var j = 0
  while j < file.items.count {
    match file.items[j].kind {
      case IFunc(decl) -> {
        cctx.funcTokens.add(decl.name, 0x06000000 + methodDefRow)
        // Record the function's declared return type as an element-
        // type byte so call sites can pick the right `WriteLine`
        // overload etc.  Block/expr bodies are resolved through
        // typeExprToMsil at codegen time; if no return annotation,
        // default to Void.
        val retTy = match decl.ret {
          case Some(te) -> typeExprToMsil(te, pkgName)
          case None     -> MVoid
        }
        cctx.funcRetTypes.add(decl.name, retTy)
        methodDefRow = methodDefRow + 1
      }
      case _ -> {}
    }
    j = j + 1
  }

  // Pass 3: union cases.
  var k = 0
  while k < file.items.count {
    match file.items[k].kind {
      case IUnion(decl) -> {
        var ci = 0
        while ci < decl.cases.count {
          val c = decl.cases[ci]
          val caseName = pkgName + "." + decl.name + "$" + c.name
          var fi = 0
          while fi < c.fields.count {
            match c.fields[fi] {
              case UFNamed(name, _, _) -> {
                cctx.fieldTokens.add(caseName + "/" + name,
                                     0x04000000 + fieldDefRow)
                fieldDefRow = fieldDefRow + 1
              }
              case UFPos(_, _) -> {
                cctx.fieldTokens.add(caseName + "/field" + toString(fi),
                                     0x04000000 + fieldDefRow)
                fieldDefRow = fieldDefRow + 1
              }
            }
            fi = fi + 1
          }
          cctx.recordCtorTokens.add(caseName, 0x06000000 + methodDefRow)
          methodDefRow = methodDefRow + 1
          ci = ci + 1
        }
      }
      case _ -> {}
    }
    k = k + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Per-function codegen context.
// ─────────────────────────────────────────────────────────────────────────────

// FuncCtx threads mutable state through expression and statement lowering.
// Parameters and locals share the `slots` map but use different namespaces:
//   • params: slots 0..paramCount-1, accessed via MLdarg(slot)
//   • locals: slots paramCount.., accessed via MLdloc(slot - paramCount)
// `locals` records MsilType entries in order for MFunc.locals.
// `slotTicker` and `labelTicker` are singleton lists whose `.count` is the
// current next-slot / next-label integer.
pub record FuncCtx {
  pkgName:     String
  className:   String
  slots:       Map[String, Int]
  types:       Map[String, MsilType]
  locals:      List[MsilType]       // ordered local variable types for MFunc.locals
  slotTicker:  List[Int]            // length = next slot index (params + locals combined)
  labelTicker: List[Int]            // length = next label index
  paramCount:  Int                  // number of parameters (fixed at creation)
  loopBreak:   List[Int]            // stack: top = innermost loop's exit label
  loopCont:    List[Int]            // stack: top = innermost loop's back-edge label
}

// Allocate a fresh label ID (0, 1, 2, …) for use with MLabel/MBr* instructions.
pub func freshLabelMsil(fctx: in FuncCtx): Int {
  val n = fctx.labelTicker.count
  fctx.labelTicker.add(0)
  n
}

// Assign the next combined slot to `name` with MSIL type `ty`.
// Locals (slot >= paramCount) are appended to `fctx.locals`.
// Returns the combined slot index (used as the key in the slots map).
//
// If `name` is already registered (same variable name declared in a
// different branch of the same function), the existing slot is reused.
// MSIL locals are function-wide, not block-scoped; disjoint branches
// sharing the same binding name can safely reuse the same slot.
pub func allocSlotMsil(fctx: in FuncCtx, name: in String, ty: in MsilType): Int {
  match mapGet(fctx.slots, name) {
    case Some(existing) ->
      // Invariant: same name implies same type (enforced by the type checker).
      existing
    case None -> {
      val slot = fctx.slotTicker.count
      fctx.slots.add(name, slot)
      fctx.types.add(name, ty)
      fctx.slotTicker.add(0)
      // Only add to locals if this is a local (not a param).
      if slot >= fctx.paramCount {
        fctx.locals.add(ty)
      }
      slot
    }
  }
}

// Emit the appropriate load instruction for a slot, distinguishing params
// (MLdarg) from locals (MLdloc with 0-based local index).
func emitLoadSlot(insns: in List[MInsn], slot: in Int, paramCount: in Int): Unit {
  if slot < paramCount {
    insns.add(MLdarg(slot = slot))
  } else {
    insns.add(MLdloc(slot = slot - paramCount))
  }
}

// Emit the appropriate store instruction for a slot.
func emitStoreSlot(insns: in List[MInsn], slot: in Int, paramCount: in Int): Unit {
  if slot < paramCount {
    insns.add(MStarg(slot = slot))
  } else {
    insns.add(MStloc(slot = slot - paramCount))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Type mapping.
// ─────────────────────────────────────────────────────────────────────────────

// Return the last segment of a ModulePath.
func lastSegmentMsil(path: in ModulePath): String {
  val n = path.segments.count
  if n == 0 {
    return ""
  }
  path.segments[n - 1]
}

// Join path segments with a separator.
func joinSegsMsil(segs: in List[String], sep: in String): String {
  var result = ""
  var i = 0
  while i < segs.count {
    if i > 0 {
      result = result + sep
    }
    result = result + segs[i]
    i = i + 1
  }
  result
}

// Map a Lyric TypeExpr to an MsilType.
pub func typeExprToMsil(te: in TypeExpr, pkgName: in String): MsilType {
  match te.kind {
    case TUnit    -> MVoid
    case TNever   -> MVoid
    case TRef(path) -> {
      val seg = lastSegmentMsil(path)
      if seg == "Int" {
        MInt
      } else if seg == "Long" {
        MLong
      } else if seg == "Double" {
        MDouble
      } else if seg == "Float" {
        MDouble
      } else if seg == "Bool" {
        MBool
      } else if seg == "String" {
        MString
      } else if seg == "Char" {
        MChar
      } else if seg == "Byte" {
        MInt
      } else if seg == "Unit" {
        MVoid
      } else {
        MClass(className = pkgName + "." + seg)
      }
    }
    case TSlice(_)          -> MObject
    case TGenericApp(_, _)  -> MObject
    case TNullable(_)       -> MObject
    case TTuple(_)          -> MObject
    case TFunction(_, _)    -> MObject
    case TArray(_, _)       -> MObject
    case TRefined(_, _)     -> MInt
    case TParen(inner)      -> typeExprToMsil(inner, pkgName)
    case TSelf              -> MObject
    case TError             -> MObject
  }
}

// Return true if an MsilType is a value type that must be boxed before
// calling virtual/interface methods.
func isValueType(ty: in MsilType): Bool {
  match ty {
    case MInt     -> true
    case MLong    -> true
    case MDouble  -> true
    case MBool    -> true
    case MChar    -> true
    case _        -> false
  }
}

// Return the TypeRef row for boxing the given value type.
func boxTypeRef(cctx: in CodegenCtx, ty: in MsilType): Int {
  match ty {
    case MInt    -> cctx.trInt32
    case MLong   -> cctx.trInt64
    case MDouble -> cctx.trDouble
    case MBool   -> cctx.trBoolean
    case MChar   -> cctx.trInt32   // Char boxes as Int32 for Object.ToString()
    case _       -> cctx.lctx.trObject
  }
}

// Box a value type on the stack.  Does nothing for reference types.
func boxIfNeededMsil(cctx: in CodegenCtx, insns: in List[MInsn], ty: in MsilType): Unit {
  if isValueType(ty) {
    insns.add(MBox(typeToken = 0x01000000 + boxTypeRef(cctx, ty)))
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Lower a single expression.  Pushes exactly one value onto the operand stack
// (or nothing for MVoid).  Returns the MsilType of the pushed value.
pub func lowerExprMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                       insns: in List[MInsn], expr: in Expr): MsilType {
  match expr.kind {

    // ── Literals ─────────────────────────────────────────────────────────────
    case ELiteral(lit) -> {
      match lit {
        case LInt(v, _) -> {
          // Use MLdcI4 for values that fit in Int; MLdcI8 for Long suffix.
          val asInt = longToInt(v)
          if intToLong(asInt) == v {
            insns.add(MLdcI4(v = asInt))
            MInt
          } else {
            insns.add(MLdcI8(v = v))
            MLong
          }
        }
        case LFloat(v, _) -> {
          insns.add(MLdcR8(v = v))
          MDouble
        }
        case LString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LTripleString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LRawString(s) -> {
          val token = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = token))
          MString
        }
        case LBool(value) -> {
          if value {
            insns.add(MLdcI4(v = 1))
          } else {
            insns.add(MLdcI4(v = 0))
          }
          MBool
        }
        case LUnit -> {
          MVoid
        }
        case LChar(cp) -> {
          insns.add(MLdcI4(v = cp))
          MChar
        }
      }
    }

    // ── Parenthesised expression ──────────────────────────────────────────────
    case EParen(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Path (variable or function reference) ─────────────────────────────────
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, name) {
              case Some(t) -> t
              case None    -> MObject
            }
          emitLoadSlot(insns, slot, fctx.paramCount)
          ty
        }
        case None -> {
          // Unknown name — emit null as a safe fallback.
          insns.add(MLdNull)
          MObject
        }
      }
    }

    // ── Arithmetic / logic binary ops ────────────────────────────────────────
    case EBinop(op, lhs, rhs) -> {
      lowerBinopMsil(cctx, fctx, insns, op, lhs, rhs)
    }

    // ── Prefix ops ────────────────────────────────────────────────────────────
    case EPrefix(op, operand) -> {
      match op {
        case PreNeg -> {
          val ty = lowerExprMsil(cctx, fctx, insns, operand)
          insns.add(MNeg)
          ty
        }
        case PreNot -> {
          lowerExprMsil(cctx, fctx, insns, operand)
          insns.add(MLdcI4(v = 1))
          insns.add(MXor)
          MBool
        }
        case PreRef -> {
          lowerExprMsil(cctx, fctx, insns, operand)
        }
      }
    }

    // ── Function calls ─────────────────────────────────────────────────────────
    case ECall(fn, args) -> {
      lowerCallMsil(cctx, fctx, insns, fn, args)
    }

    // ── Member access ──────────────────────────────────────────────────────────
    case EMember(recv, memberName) -> {
      val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
      match recvTy {
        case MClass(cls) -> {
          val key = cls + "/" + memberName
          match mapGet(cctx.fieldTokens, key) {
            case Some(tok) -> {
              insns.add(MLdfld(fieldToken = tok))
              MObject
            }
            case None -> {
              if memberName == "count" {
                insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
                MInt
              } else {
                insns.add(MPop)
                MObject
              }
            }
          }
        }
        case _ -> {
          // For MObject receivers (List, Dict, etc.) handle known BCL properties.
          if memberName == "count" {
            insns.add(MCallvirt(methodToken = cctx.tokListObjGetCount))
            MInt
          } else {
            MObject
          }
        }
      }
    }

    // ── If / else ──────────────────────────────────────────────────────────────
    case EIf(cond, thenBranch, elseBranchOpt, _) -> {
      lowerIfExprMsil(cctx, fctx, insns, cond, thenBranch, elseBranchOpt)
    }

    // ── Block expression ───────────────────────────────────────────────────────
    case EBlock(block) -> {
      lowerBlockExprMsil(cctx, fctx, insns, block)
    }

    // ── Unsafe block (same as block for MSIL) ─────────────────────────────────
    case EUnsafe(block) -> {
      lowerBlockExprMsil(cctx, fctx, insns, block)
    }

    // ── Assignment expression ──────────────────────────────────────────────────
    case EAssign(target, op, value) -> {
      lowerAssignExprMsil(cctx, fctx, insns, target, op, value)
    }

    // ── Tuple ──────────────────────────────────────────────────────────────────
    case ETuple(exprs) -> {
      if exprs.count > 0 {
        lowerExprMsil(cctx, fctx, insns, exprs[0])
      } else {
        MVoid
      }
    }

    // ── List literal ───────────────────────────────────────────────────────────
    case EList(exprs) -> {
      // newobj List<object>(); then add each element.
      insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
      var eli = 0
      while eli < exprs.count {
        insns.add(MDup)
        val eTy = lowerExprMsil(cctx, fctx, insns, exprs[eli])
        boxIfNeededMsil(cctx, insns, eTy)
        insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
        eli = eli + 1
      }
      MObject
    }

    // ── Await / spawn (bootstrap: synchronous lowering) ───────────────────────
    case EAwait(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Yield: async generators deferred to self-hosted MSIL R6 ──────────────
    case EYield(_) -> {
      panic("Msil.Codegen: async generators (yield) not supported in self-hosted MSIL R5 — use F# bootstrap (--target dotnet)")
    }

    case ESpawn(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Propagate (?) — bootstrap: just lower inner ───────────────────────────
    case ETry(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    case EPropagate(inner) -> {
      lowerExprMsil(cctx, fctx, insns, inner)
    }

    // ── Match expression ───────────────────────────────────────────────────────
    case EMatch(scrutinee, arms) -> {
      lowerMatchExprMsil(cctx, fctx, insns, scrutinee, arms)
    }

    // ── Interpolated string ────────────────────────────────────────────────────
    case EInterpolated(segments) -> {
      lowerInterpolatedMsil(cctx, fctx, insns, segments)
    }

    // ── Type application — ignore type args and lower the callee ──────────────
    case ETypeApp(fn, _) -> {
      lowerExprMsil(cctx, fctx, insns, fn)
    }

    // ── Index access ───────────────────────────────────────────────────────────
    case EIndex(recv, indices) -> {
      lowerExprMsil(cctx, fctx, insns, recv)
      if indices.count > 0 {
        val idxTy = lowerExprMsil(cctx, fctx, insns, indices[0])
        // If the index is not Int32, convert (e.g. an object key for dict).
        match idxTy {
          case MInt -> {}
          case _    -> {}
        }
      }
      insns.add(MCallvirt(methodToken = cctx.tokListObjGetItem))
      MObject
    }

    // ── Unsupported forms ──────────────────────────────────────────────────────
    case EForall(_, _, _) -> {
      panic("Msil.Codegen: EForall not supported in bootstrap — use --target dotnet-legacy")
    }
    case EExists(_, _, _) -> {
      panic("Msil.Codegen: EExists not supported in bootstrap — use --target dotnet-legacy")
    }
    case EOld(_) -> {
      panic("Msil.Codegen: EOld not supported in bootstrap — use --target dotnet-legacy")
    }
    case ESelf -> {
      insns.add(MLdarg(slot = 0))
      MObject
    }
    case EResult -> {
      panic("Msil.Codegen: EResult outside contract context")
    }
    case ELambda(_, _) -> {
      panic("Msil.Codegen: ELambda not yet supported in bootstrap — use --target dotnet-legacy")
    }
    case ERange(_) -> {
      panic("Msil.Codegen: ERange not supported in bootstrap — use --target dotnet-legacy")
    }
    case EError -> {
      insns.add(MLdNull)
      MObject
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5a. Binary operation lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerBinopMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  op:    in BinOp,
  lhs:   in Expr,
  rhs:   in Expr
): MsilType {
  match op {
    // Boolean short-circuit AND.
    case BAnd -> {
      val falseL = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrFalse(label = falseL))
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBrFalse(label = falseL))
      insns.add(MLdcI4(v = 1))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =falseL))
      insns.add(MLdcI4(v = 0))
      insns.add(MLabel(id =afterL))
      MBool
    }
    // Boolean short-circuit OR.
    case BOr -> {
      val trueL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrTrue(label = trueL))
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBrTrue(label = trueL))
      insns.add(MLdcI4(v = 0))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id =afterL))
      MBool
    }
    // Comparison operators — produce 0 or 1.
    case BEq -> {
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MCeq)
      MBool
    }
    case BNeq -> {
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MCeq)
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    case BLt -> {
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MClt)
      MBool
    }
    case BGt -> {
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MCgt)
      MBool
    }
    case BLte -> {
      // a <= b  ≡  !(a > b)
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MCgt)
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    case BGte -> {
      // a >= b  ≡  !(a < b)
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MClt)
      insns.add(MLdcI4(v = 1))
      insns.add(MXor)
      MBool
    }
    // Arithmetic.
    case BAdd -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      match lhsTy {
        case MString -> {
          // String concatenation via String.Concat(string,string).
          // Store lhs temporarily, lower rhs, then call Concat2.
          val lhsSlot = allocSlotMsil(fctx,
            "__sadd_" + toString(fctx.slotTicker.count), MString)
          insns.add(MStloc(slot = lhsSlot - fctx.paramCount))
          lowerExprMsil(cctx, fctx, insns, rhs)
          val rhsSlot = allocSlotMsil(fctx,
            "__sadd_r_" + toString(fctx.slotTicker.count), MString)
          insns.add(MStloc(slot = rhsSlot - fctx.paramCount))
          insns.add(MLdloc(slot = lhsSlot - fctx.paramCount))
          insns.add(MLdloc(slot = rhsSlot - fctx.paramCount))
          insns.add(MCall(methodToken = cctx.tokConcat2))
          MString
        }
        case MLong -> {
          lowerExprMsil(cctx, fctx, insns, rhs)
          insns.add(MAdd)
          MLong
        }
        case MDouble -> {
          lowerExprMsil(cctx, fctx, insns, rhs)
          insns.add(MAdd)
          MDouble
        }
        case _ -> {
          lowerExprMsil(cctx, fctx, insns, rhs)
          insns.add(MAdd)
          MInt
        }
      }
    }
    case BSub -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      match lhsTy {
        case MLong   -> { insns.add(MSub); MLong }
        case MDouble -> { insns.add(MSub); MDouble }
        case _       -> { insns.add(MSub); MInt }
      }
    }
    case BMul -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      match lhsTy {
        case MLong   -> { insns.add(MMul); MLong }
        case MDouble -> { insns.add(MMul); MDouble }
        case _       -> { insns.add(MMul); MInt }
      }
    }
    case BDiv -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      match lhsTy {
        case MLong   -> { insns.add(MDiv); MLong }
        case MDouble -> { insns.add(MDiv); MDouble }
        case _       -> { insns.add(MDiv); MInt }
      }
    }
    case BMod -> {
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      match lhsTy {
        case MLong -> { insns.add(MRem); MLong }
        case _     -> { insns.add(MRem); MInt }
      }
    }
    case BXor -> {
      lowerExprMsil(cctx, fctx, insns, lhs)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MXor)
      MInt
    }
    case BCoalesce -> {
      // Null-coalescing: if lhs is non-null use it, else use rhs.
      val lhsTy = lowerExprMsil(cctx, fctx, insns, lhs)
      val nullL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MDup)
      insns.add(MBrFalse(label = nullL))
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =nullL))
      insns.add(MPop)
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MLabel(id =afterL))
      lhsTy
    }
    case BImplies -> {
      // p => q  ≡  !p || q
      val trueL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      lowerExprMsil(cctx, fctx, insns, lhs)
      insns.add(MBrFalse(label = trueL))   // if lhs false, result is true
      lowerExprMsil(cctx, fctx, insns, rhs)
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =trueL))
      insns.add(MLdcI4(v = 1))
      insns.add(MLabel(id =afterL))
      MBool
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5b. If expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerExprOrBlockMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  eob:   in ExprOrBlock
): MsilType {
  match eob {
    case EOBExpr(e)    -> lowerExprMsil(cctx, fctx, insns, e)
    case EOBBlock(blk) -> lowerBlockExprMsil(cctx, fctx, insns, blk)
  }
}

func lowerIfExprMsil(
  cctx:          in CodegenCtx,
  fctx:          in FuncCtx,
  insns:         in List[MInsn],
  cond:          in Expr,
  thenBranch:    in ExprOrBlock,
  elseBranchOpt: in Option[ExprOrBlock]
): MsilType {
  val elseL  = freshLabelMsil(fctx)
  val afterL = freshLabelMsil(fctx)

  lowerExprMsil(cctx, fctx, insns, cond)
  insns.add(MBrFalse(label = elseL))

  val thenTy = lowerExprOrBlockMsil(cctx, fctx, insns, thenBranch)

  match elseBranchOpt {
    case Some(elseBranch) -> {
      insns.add(MBr(label = afterL))
      insns.add(MLabel(id =elseL))
      lowerExprOrBlockMsil(cctx, fctx, insns, elseBranch)
      insns.add(MLabel(id =afterL))
      thenTy
    }
    case None -> {
      insns.add(MLabel(id =elseL))
      thenTy
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5c. Block expression lowering.
//      Returns the MsilType of the trailing value (last SExpr), or MVoid.
// ─────────────────────────────────────────────────────────────────────────────

func lowerBlockExprMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  block: in Block
): MsilType {
  val n = block.statements.count
  if n == 0 {
    return MVoid
  }
  var i = 0
  while i < n - 1 {
    lowerStmtMsil(cctx, fctx, insns, block.statements[i])
    i = i + 1
  }
  // Last statement: if SExpr its value is the block value.
  val last = block.statements[n - 1]
  match last.kind {
    case SExpr(e) -> {
      lowerExprMsil(cctx, fctx, insns, e)
    }
    case _ -> {
      lowerStmtMsil(cctx, fctx, insns, last)
      MVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5d. Assignment expression lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerAssignExprMsil(
  cctx:   in CodegenCtx,
  fctx:   in FuncCtx,
  insns:  in List[MInsn],
  target: in Expr,
  op:     in AssignOp,
  value:  in Expr
): MsilType {
  match target.kind {
    case EPath(path) -> {
      val name = lastSegmentMsil(path)
      match mapGet(fctx.slots, name) {
        case Some(slot) -> {
          val ty =
            match mapGet(fctx.types, name) {
              case Some(t) -> t
              case None    -> MObject
            }
          match op {
            case AssEq -> {
              lowerExprMsil(cctx, fctx, insns, value)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case AssPlus -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              lowerExprMsil(cctx, fctx, insns, value)
              match ty {
                case MLong   -> insns.add(MAdd)
                case MDouble -> insns.add(MAdd)
                case _       -> insns.add(MAdd)
              }
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case AssMinus -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              lowerExprMsil(cctx, fctx, insns, value)
              insns.add(MSub)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case AssStar -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              lowerExprMsil(cctx, fctx, insns, value)
              insns.add(MMul)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case AssSlash -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              lowerExprMsil(cctx, fctx, insns, value)
              insns.add(MDiv)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case AssPercent -> {
              emitLoadSlot(insns, slot, fctx.paramCount)
              lowerExprMsil(cctx, fctx, insns, value)
              insns.add(MRem)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
          }
          MVoid
        }
        case None -> {
          lowerExprMsil(cctx, fctx, insns, value)
          insns.add(MPop)
          MVoid
        }
      }
    }
    case EMember(recv, memberName) -> {
      // Field assignment: recv.field = value
      val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
      val valTy  = lowerExprMsil(cctx, fctx, insns, value)
      match recvTy {
        case MClass(cls) -> {
          val key = cls + "/" + memberName
          match mapGet(cctx.fieldTokens, key) {
            case Some(tok) -> {
              insns.add(MStfld(fieldToken = tok))
            }
            case None -> {
              insns.add(MPop)
              insns.add(MPop)
            }
          }
        }
        case _ -> {
          insns.add(MPop)
          insns.add(MPop)
        }
      }
      MVoid
    }
    case _ -> {
      lowerExprMsil(cctx, fctx, insns, value)
      insns.add(MPop)
      MVoid
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5e. Match expression lowering.
//      Bootstrap-grade: literal, binding, constructor, and wildcard patterns.
// ─────────────────────────────────────────────────────────────────────────────

func lowerMatchExprMsil(
  cctx:      in CodegenCtx,
  fctx:      in FuncCtx,
  insns:     in List[MInsn],
  scrutinee: in Expr,
  arms:      in List[MatchArm]
): MsilType {
  val scrutTy   = lowerExprMsil(cctx, fctx, insns, scrutinee)
  val scrutSlot = allocSlotMsil(fctx,
    "__scrut_" + toString(fctx.slotTicker.count), scrutTy)
  emitStoreSlot(insns, scrutSlot, fctx.paramCount)

  val afterL   = freshLabelMsil(fctx)
  var resultTy: MsilType = MVoid

  var i = 0
  while i < arms.count {
    val arm       = arms[i]
    val nextArmL  = freshLabelMsil(fctx)
    lowerPatternTestMsil(cctx, fctx, insns, arm.pattern, scrutSlot, scrutTy, nextArmL)
    lowerPatternBindMsil(cctx, fctx, insns, arm.pattern, scrutSlot, scrutTy)
    match arm.guard {
      case Some(g) -> {
        lowerExprMsil(cctx, fctx, insns, g)
        insns.add(MBrFalse(label = nextArmL))
      }
      case None -> {}
    }
    val armTy = lowerExprOrBlockMsil(cctx, fctx, insns, arm.body)
    if i == 0 {
      resultTy = armTy
    }
    insns.add(MBr(label = afterL))
    insns.add(MLabel(id =nextArmL))
    i = i + 1
  }

  // If no arm matched: panic.
  val msgTok = ctxInternUs(cctx.lctx, "Msil.Codegen: match not exhaustive")
  insns.add(MLdStr(token = msgTok))
  insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
  insns.add(MThrow)

  insns.add(MLabel(id =afterL))
  resultTy
}

// Emit a runtime test for a pattern.  Jumps to `failLabel` if the test fails.
func lowerPatternTestMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  pat:        in Pattern,
  scrutSlot:  in Int,
  scrutTy:    in MsilType,
  failLabel:  in Int
): Unit {
  match pat.kind {
    case PWildcard -> {}
    case PBinding(_, innerOpt) -> {
      match innerOpt {
        case Some(inner) -> lowerPatternTestMsil(cctx, fctx, insns, inner,
                                                  scrutSlot, scrutTy, failLabel)
        case None        -> {}
      }
    }
    case PLiteral(lit) -> {
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      match lit {
        case LInt(v, _) -> {
          val asInt = longToInt(v)
          insns.add(MLdcI4(v = asInt))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LBool(value) -> {
          if value {
            insns.add(MLdcI4(v = 1))
          } else {
            insns.add(MLdcI4(v = 0))
          }
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LString(s) -> {
          val sTok = ctxInternUs(cctx.lctx, s)
          insns.add(MLdStr(token = sTok))
          insns.add(MCeq)
          insns.add(MBrFalse(label = failLabel))
        }
        case LUnit -> {
          insns.add(MPop)
        }
        case _ -> {
          insns.add(MPop)
        }
      }
    }
    case PConstructor(head, _) -> {
      // Use isinst to check the case type; branch to failLabel if null.
      val caseName = lastSegmentMsil(head)
      match scrutTy {
        case MClass(baseCls) -> {
          val caseClass = baseCls + "$" + caseName
          emitLoadSlot(insns, scrutSlot, fctx.paramCount)
          insns.add(MIsinst(typeToken = 0x01000000 + boxTypeRef(cctx, MClass(className = caseClass))))
          insns.add(MBrFalse(label = failLabel))
        }
        case _ -> {}
      }
    }
    case POr(patterns) -> {
      val succeedL = freshLabelMsil(fctx)
      var ai = 0
      while ai < patterns.count {
        val nextAltL = freshLabelMsil(fctx)
        lowerPatternTestMsil(cctx, fctx, insns, patterns[ai],
                             scrutSlot, scrutTy, nextAltL)
        insns.add(MBr(label = succeedL))
        insns.add(MLabel(id =nextAltL))
        ai = ai + 1
      }
      insns.add(MBr(label = failLabel))
      insns.add(MLabel(id =succeedL))
    }
    case PError -> {}
  }
}

// Bind pattern variables after a successful match.
func lowerPatternBindMsil(
  cctx:      in CodegenCtx,
  fctx:      in FuncCtx,
  insns:     in List[MInsn],
  pat:       in Pattern,
  scrutSlot: in Int,
  scrutTy:   in MsilType
): Unit {
  match pat.kind {
    case PWildcard -> {}
    case PBinding(name, innerOpt) -> {
      emitLoadSlot(insns, scrutSlot, fctx.paramCount)
      val bindSlot = allocSlotMsil(fctx, name, scrutTy)
      emitStoreSlot(insns, bindSlot, fctx.paramCount)
      match innerOpt {
        case Some(inner) -> lowerPatternBindMsil(cctx, fctx, insns, inner,
                                                   bindSlot, scrutTy)
        case None -> {}
      }
    }
    case PLiteral(_) -> {}
    case PConstructor(head, fields) -> {
      val caseName = lastSegmentMsil(head)
      match scrutTy {
        case MClass(baseCls) -> {
          val caseClass = baseCls + "$" + caseName
          val castTy    = MClass(className = caseClass)
          // We need a TypeRef for the case class.  For intra-package types
          // we use the TypeDef token computed from the pre-scan table.
          // Bootstrap: load scrutinee, castclass, store to a cast-typed slot.
          emitLoadSlot(insns, scrutSlot, fctx.paramCount)
          // We skip castclass here since isinst already verified the type;
          // re-read as the base type and let field reads work by token.
          val castSlot = allocSlotMsil(fctx,
            "__cast_" + caseName + "_" + toString(fctx.slotTicker.count), castTy)
          emitStoreSlot(insns, castSlot, fctx.paramCount)
          // Bind each named field by reading the pre-computed field token.
          var fi = 0
          while fi < fields.count {
            match fields[fi].kind {
              case PBinding(fname, _) -> {
                val fKey = caseClass + "/" + fname
                match mapGet(cctx.fieldTokens, fKey) {
                  case Some(fTok) -> {
                    emitLoadSlot(insns, castSlot, fctx.paramCount)
                    insns.add(MLdfld(fieldToken = fTok))
                    val fSlot = allocSlotMsil(fctx, fname, MObject)
                    emitStoreSlot(insns, fSlot, fctx.paramCount)
                  }
                  case None -> {}
                }
              }
              case _ -> {}
            }
            fi = fi + 1
          }
        }
        case _ -> {}
      }
    }
    case POr(_) -> {}
    case PError -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5f. Interpolated string lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerInterpolatedMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  segments: in List[InterpolatedSegment]
): MsilType {
  if segments.count == 0 {
    val emptyTok = ctxInternUs(cctx.lctx, "")
    insns.add(MLdStr(token = emptyTok))
    return MString
  }

  // Lower each segment to a string, then fold left via String.Concat.
  // We track an accumulator on the stack by chaining Concat2 calls.
  var i = 0
  var hasFirst = false
  while i < segments.count {
    match segments[i] {
      case ISText(text, _) -> {
        val tok = ctxInternUs(cctx.lctx, text)
        insns.add(MLdStr(token = tok))
      }
      case ISExpr(e) -> {
        val eTy = lowerExprMsil(cctx, fctx, insns, e)
        // Convert to string.
        if isValueType(eTy) {
          boxIfNeededMsil(cctx, insns, eTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
        } else {
          match eTy {
            case MString -> {}
            case MVoid   -> {
              val emptyTok2 = ctxInternUs(cctx.lctx, "")
              insns.add(MLdStr(token = emptyTok2))
            }
            case _ -> {
              insns.add(MCallvirt(methodToken = cctx.tokObjToString))
            }
          }
        }
      }
    }
    // If we have an accumulator from a previous segment, concat.
    if hasFirst {
      insns.add(MCall(methodToken = cctx.tokConcat2))
    } else {
      hasFirst = true
    }
    i = i + 1
  }
  MString
}

// ─────────────────────────────────────────────────────────────────────────────
// §5g. Emit a panic from a string already on the stack.
// ─────────────────────────────────────────────────────────────────────────────

func emitMsilPanicFromStack(cctx: in CodegenCtx, insns: in List[MInsn]): Unit {
  insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
  insns.add(MThrow)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5h. Call lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Lower a single call argument (positional or named).
func lowerCallArgMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                      insns: in List[MInsn], arg: in CallArg): MsilType {
  match arg {
    case CAPositional(e)    -> lowerExprMsil(cctx, fctx, insns, e)
    case CANamed(_, e, _)   -> lowerExprMsil(cctx, fctx, insns, e)
  }
}

// Lower a function call expression.
pub func lowerCallMsil(
  cctx:  in CodegenCtx,
  fctx:  in FuncCtx,
  insns: in List[MInsn],
  fn:    in Expr,
  args:  in List[CallArg]
): MsilType {
  match fn.kind {
    case EPath(path) -> {
      val funcName = lastSegmentMsil(path)
      lowerBuiltinOrStaticCallMsil(cctx, fctx, insns, funcName, path, args)
    }
    case ETypeApp(innerFn, _) -> {
      lowerCallMsil(cctx, fctx, insns, innerFn, args)
    }
    case EMember(recv, memberName) -> {
      lowerMethodCallMsil(cctx, fctx, insns, recv, memberName, args)
    }
    case _ -> {
      var i = 0
      while i < args.count {
        lowerCallArgMsil(cctx, fctx, insns, args[i])
        i = i + 1
      }
      MObject
    }
  }
}

// Lower a builtin or intra-package static call.
func lowerBuiltinOrStaticCallMsil(
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  funcName: in String,
  path:     in ModulePath,
  args:     in List[CallArg]
): MsilType {
  if funcName == "println" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MInt    -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MLong   -> insns.add(MCall(methodToken = cctx.tokWriteLineLong))
        case MDouble -> insns.add(MCall(methodToken = cctx.tokWriteLineDbl))
        case MBool   -> insns.add(MCall(methodToken = cctx.tokWriteLineBool))
        case MChar   -> insns.add(MCall(methodToken = cctx.tokWriteLineInt))
        case MVoid   -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
          insns.add(MCall(methodToken = cctx.tokWriteLineStr))
        }
        case _ -> insns.add(MCall(methodToken = cctx.tokWriteLineStr))
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
      insns.add(MCall(methodToken = cctx.tokWriteLineStr))
    }
    MVoid
  } else if funcName == "print" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MString -> insns.add(MCall(methodToken = cctx.tokWriteStr))
        case MVoid -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
          insns.add(MCall(methodToken = cctx.tokWriteStr))
        }
        case _ -> {
          // Box value type and call ToString, then Write(string).
          boxIfNeededMsil(cctx, insns, argTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
          insns.add(MCall(methodToken = cctx.tokWriteStr))
        }
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
      insns.add(MCall(methodToken = cctx.tokWriteStr))
    }
    MVoid
  } else if funcName == "panic" {
    if args.count > 0 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val panicTok = ctxInternUs(cctx.lctx, "panic")
      insns.add(MLdStr(token = panicTok))
    }
    emitMsilPanicFromStack(cctx, insns)
    MVoid
  } else if funcName == "assert" {
    if args.count > 0 {
      val skipL = freshLabelMsil(fctx)
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      insns.add(MBrTrue(label = skipL))
      if args.count > 1 {
        val _ = lowerCallArgMsil(cctx, fctx, insns, args[1])
      } else {
        val failTok = ctxInternUs(cctx.lctx, "assertion failed")
        insns.add(MLdStr(token = failTok))
      }
      emitMsilPanicFromStack(cctx, insns)
      insns.add(MLabel(id =skipL))
    }
    MVoid
  } else if funcName == "toString" {
    if args.count > 0 {
      val argTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      match argTy {
        case MString -> {}
        case MVoid -> {
          val emptyTok = ctxInternUs(cctx.lctx, "")
          insns.add(MLdStr(token = emptyTok))
        }
        case _ -> {
          boxIfNeededMsil(cctx, insns, argTy)
          insns.add(MCallvirt(methodToken = cctx.tokObjToString))
        }
      }
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "intToLong" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvI8)
    MLong
  } else if funcName == "longToInt" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvI4)
    MInt
  } else if funcName == "charToInt" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    // Char is I4 in MSIL; no conversion needed.
    MInt
  } else if funcName == "intToDouble" {
    if args.count > 0 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
    }
    insns.add(MConvR8)
    MDouble
  } else if funcName == "default" {
    insns.add(MLdNull)
    MObject
  } else if funcName == "newList" {
    // Emit: newobj instance void class List`1<object>::.ctor()
    insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
    MObject
  } else if funcName == "newMap" {
    // Emit: newobj instance void class Dictionary`2<object,object>::.ctor()
    insns.add(MNewobj(ctorToken = cctx.tokDictObjCtor))
    MObject
  } else if funcName == "mapGet" {
    // Bootstrap: use Dictionary.get_Item (returns null if missing); wrap in object.
    // Full Option[V] wrapping deferred — bootstrap returns null for None.
    if args.count >= 2 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      lowerCallArgMsil(cctx, fctx, insns, args[1])
      insns.add(MCallvirt(methodToken = cctx.tokDictObjGetItem))
    } else {
      insns.add(MLdNull)
    }
    MObject
  } else if funcName == "format1" {
    if args.count >= 2 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty)
      insns.add(MCall(methodToken = cctx.tokStringFormat1))
    } else if args.count == 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "format2" {
    if args.count >= 3 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty2 = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty2)
      val a2Ty2 = lowerCallArgMsil(cctx, fctx, insns, args[2])
      boxIfNeededMsil(cctx, insns, a2Ty2)
      insns.add(MCall(methodToken = cctx.tokStringFormat2))
    } else if args.count >= 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else if funcName == "format3" {
    if args.count >= 4 {
      lowerCallArgMsil(cctx, fctx, insns, args[0])
      val a1Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[1])
      boxIfNeededMsil(cctx, insns, a1Ty3)
      val a2Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[2])
      boxIfNeededMsil(cctx, insns, a2Ty3)
      val a3Ty3 = lowerCallArgMsil(cctx, fctx, insns, args[3])
      boxIfNeededMsil(cctx, insns, a3Ty3)
      insns.add(MCall(methodToken = cctx.tokStringFormat3))
    } else if args.count >= 1 {
      val _ = lowerCallArgMsil(cctx, fctx, insns, args[0])
    } else {
      val emptyTok = ctxInternUs(cctx.lctx, "")
      insns.add(MLdStr(token = emptyTok))
    }
    MString
  } else {
    // Intra-package static call.
    match mapGet(cctx.funcTokens, funcName) {
      case Some(tok) -> {
        var i = 0
        while i < args.count {
          lowerCallArgMsil(cctx, fctx, insns, args[i])
          i = i + 1
        }
        insns.add(MCall(methodToken = tok))
        // Return the function's declared return type so call sites
        // can dispatch builtins (println etc.) on the actual value
        // type instead of falling through to the `WriteLine(string)`
        // default.
        match mapGet(cctx.funcRetTypes, funcName) {
          case Some(rt) -> rt
          case None     -> MObject
        }
      }
      case None -> {
        // Could be a cross-package call via qualified path.
        // Lower args and emit a placeholder — bootstrap limitation.
        var i = 0
        while i < args.count {
          lowerCallArgMsil(cctx, fctx, insns, args[i])
          i = i + 1
        }
        MObject
      }
    }
  }
}

// Lower a method call on a receiver: recv.memberName(args…).
// Dispatches by name to known BCL tokens for List<object> and
// Dictionary<object,object>; falls back to a safe stub for unknowns.
func lowerMethodCallMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  recv:       in Expr,
  memberName: in String,
  args:       in List[CallArg]
): MsilType {
  lowerExprMsil(cctx, fctx, insns, recv)
  if memberName == "add" {
    // List<object>::Add(object): void  OR  Dict::Add(key,value): void
    var i = 0
    while i < args.count {
      val aTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
      boxIfNeededMsil(cctx, insns, aTy)
      i = i + 1
    }
    if args.count >= 2 {
      insns.add(MCallvirt(methodToken = cctx.tokDictObjAdd))
    } else {
      insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
    }
    MVoid
  } else if memberName == "containsKey" {
    // Dictionary::ContainsKey(object): bool
    if args.count > 0 {
      val aTy = lowerCallArgMsil(cctx, fctx, insns, args[0])
      boxIfNeededMsil(cctx, insns, aTy)
    }
    insns.add(MCallvirt(methodToken = cctx.tokDictObjContainsKey))
    MBool
  } else if memberName == "contains" {
    // List::Contains(object): bool  — bootstrap: always false stub
    var i = 0
    while i < args.count {
      lowerCallArgMsil(cctx, fctx, insns, args[i])
      insns.add(MPop)
      i = i + 1
    }
    insns.add(MPop)
    insns.add(MLdcI4(v = 0))
    MBool
  } else if memberName == "remove" {
    // Dictionary::Remove(object): bool — bootstrap stub: pop key, pop recv, return false
    var i = 0
    while i < args.count {
      lowerCallArgMsil(cctx, fctx, insns, args[i])
      insns.add(MPop)
      i = i + 1
    }
    insns.add(MPop)
    insns.add(MLdcI4(v = 0))
    MBool
  } else if memberName == "removeAt" {
    // List::RemoveAt(int): void — bootstrap stub: pop index, pop recv
    var i = 0
    while i < args.count {
      lowerCallArgMsil(cctx, fctx, insns, args[i])
      insns.add(MPop)
      i = i + 1
    }
    insns.add(MPop)
    MVoid
  } else if memberName == "toArray" {
    // List::ToArray(): object[] — bootstrap stub: pop recv, return null
    insns.add(MPop)
    insns.add(MLdNull)
    MObject
  } else if memberName == "toString" {
    insns.add(MCallvirt(methodToken = cctx.tokObjToString))
    MString
  } else {
    // Unknown method — pop receiver and args, return null (bootstrap stub).
    var i = 0
    while i < args.count {
      lowerCallArgMsil(cctx, fctx, insns, args[i])
      insns.add(MPop)
      i = i + 1
    }
    insns.add(MPop)
    insns.add(MLdNull)
    MObject
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Statement lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerStmtMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                       insns: in List[MInsn], stmt: in Statement): Unit {
  match stmt.kind {

    // ── Local bindings ────────────────────────────────────────────────────────
    case SLocal(binding) -> {
      match binding {
        case LBVal(pat, tyOpt, init) -> {
          val initTy = lowerExprMsil(cctx, fctx, insns, init)
          lowerLocalPatBindMsil(cctx, fctx, insns, pat, initTy, tyOpt)
        }
        case LBLet(name, tyOpt, init) -> {
          val initTy = lowerExprMsil(cctx, fctx, insns, init)
          val ty =
            match tyOpt {
              case Some(te) -> typeExprToMsil(te, fctx.pkgName)
              case None     -> initTy
            }
          val slot = allocSlotMsil(fctx, name, ty)
          emitStoreSlot(insns, slot, fctx.paramCount)
        }
        case LBVar(name, tyOpt, initOpt) -> {
          val ty =
            match tyOpt {
              case Some(te) -> typeExprToMsil(te, fctx.pkgName)
              case None     -> MInt
            }
          match initOpt {
            case Some(init) -> {
              lowerExprMsil(cctx, fctx, insns, init)
              val slot = allocSlotMsil(fctx, name, ty)
              emitStoreSlot(insns, slot, fctx.paramCount)
            }
            case None -> {
              val slot = allocSlotMsil(fctx, name, ty)
              match ty {
                case MLong   -> { insns.add(MLdcI8(v = intToLong(0))); emitStoreSlot(insns, slot, fctx.paramCount) }
                case MDouble -> { insns.add(MLdcR8(v = 0.0)); emitStoreSlot(insns, slot, fctx.paramCount) }
                case MVoid   -> {}
                case _       -> { insns.add(MLdcI4(v = 0)); emitStoreSlot(insns, slot, fctx.paramCount) }
              }
            }
          }
        }
      }
    }

    // ── Return ─────────────────────────────────────────────────────────────────
    case SReturn(valOpt) -> {
      match valOpt {
        case Some(e) -> {
          lowerExprMsil(cctx, fctx, insns, e)
          insns.add(MRet)
        }
        case None -> {
          insns.add(MRet)
        }
      }
    }

    // ── Expression statement ───────────────────────────────────────────────────
    case SExpr(e) -> {
      val ty = lowerExprMsil(cctx, fctx, insns, e)
      match ty {
        case MVoid -> {}
        case _     -> insns.add(MPop)
      }
    }

    // ── While loop ────────────────────────────────────────────────────────────
    case SWhile(_, cond, body) -> {
      val loopL  = freshLabelMsil(fctx)
      val afterL = freshLabelMsil(fctx)
      insns.add(MLabel(id =loopL))
      lowerExprMsil(cctx, fctx, insns, cond)
      insns.add(MBrFalse(label = afterL))
      fctx.loopBreak.add(afterL)
      fctx.loopCont.add(loopL)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)
      insns.add(MBr(label = loopL))
      insns.add(MLabel(id =afterL))
    }

    // ── For loop (bootstrap: stub) ────────────────────────────────────────────
    case SFor(_, pat, iter, body) -> {
      panic("Msil.Codegen: SFor not supported in bootstrap — use --target dotnet-legacy")
    }

    // ── Loop (unconditional) ──────────────────────────────────────────────────
    case SLoop(_, body) -> {
      val loopL2  = freshLabelMsil(fctx)
      val afterL2 = freshLabelMsil(fctx)
      insns.add(MLabel(id =loopL2))
      fctx.loopBreak.add(afterL2)
      fctx.loopCont.add(loopL2)
      lowerBlockMsil(cctx, fctx, insns, body)
      fctx.loopBreak.removeAt(fctx.loopBreak.count - 1)
      fctx.loopCont.removeAt(fctx.loopCont.count - 1)
      insns.add(MBr(label = loopL2))
      insns.add(MLabel(id =afterL2))
    }

    // ── Assignment statement ───────────────────────────────────────────────────
    case SAssign(target, op, value) -> {
      val _ = lowerAssignExprMsil(cctx, fctx, insns, target, op, value)
    }

    // ── Throw ─────────────────────────────────────────────────────────────────
    case SThrow(e) -> {
      lowerExprMsil(cctx, fctx, insns, e)
      insns.add(MThrow)
    }

    // ── Break / continue ─────────────────────────────────────────────────────
    case SBreak(_) -> {
      insns.add(MBr(label = fctx.loopBreak[fctx.loopBreak.count - 1]))
    }
    case SContinue(_) -> {
      insns.add(MBr(label = fctx.loopCont[fctx.loopCont.count - 1]))
    }

    // ── Scope block ───────────────────────────────────────────────────────────
    case SScope(_, body) -> {
      lowerBlockMsil(cctx, fctx, insns, body)
    }

    // ── Defer (bootstrap: inline) ────────────────────────────────────────────
    case SDefer(body) -> {
      lowerBlockMsil(cctx, fctx, insns, body)
    }

    // ── Try/catch ─────────────────────────────────────────────────────────────
    case STry(body, catches) -> {
      lowerTryCatchMsil(cctx, fctx, insns, body, catches)
    }

    // ── Invariant annotation (runtime: skip) ──────────────────────────────────
    case SInvariant(_) -> {}

    // ── Inline item declaration (skip in bootstrap) ────────────────────────────
    case SItem(_) -> {}

    // ── Rule statement (skip) ─────────────────────────────────────────────────
    case SRule(_, _) -> {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6a. Local pattern binding.
// ─────────────────────────────────────────────────────────────────────────────

func lowerLocalPatBindMsil(
  cctx:   in CodegenCtx,
  fctx:   in FuncCtx,
  insns:  in List[MInsn],
  pat:    in Pattern,
  initTy: in MsilType,
  tyOpt:  in Option[TypeExpr]
): Unit {
  match pat.kind {
    case PBinding(name, _) -> {
      val ty =
        match tyOpt {
          case Some(te) -> typeExprToMsil(te, fctx.pkgName)
          case None     -> initTy
        }
      val slot = allocSlotMsil(fctx, name, ty)
      emitStoreSlot(insns, slot, fctx.paramCount)
    }
    case PWildcard -> {
      match initTy {
        case MVoid -> {}
        case _     -> insns.add(MPop)
      }
    }
    case _ -> {
      val tmpSlot = allocSlotMsil(fctx,
        "__tmp_" + toString(fctx.slotTicker.count), initTy)
      emitStoreSlot(insns, tmpSlot, fctx.paramCount)
      lowerPatternBindMsil(cctx, fctx, insns, pat, tmpSlot, initTy)
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6b. Try/catch lowering.
// ─────────────────────────────────────────────────────────────────────────────

func lowerTryCatchMsil(
  cctx:    in CodegenCtx,
  fctx:    in FuncCtx,
  insns:   in List[MInsn],
  body:    in Block,
  catches: in List[CatchClause]
): Unit {
  // Bootstrap: inline the try body; catch clauses are emitted but exception
  // table registration is deferred (MethodBody exception table in Phase R6).
  lowerBlockMsil(cctx, fctx, insns, body)
  // Emit catch handlers (reachable if jumped to by CLR exception dispatch).
  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerL = freshLabelMsil(fctx)
    insns.add(MLabel(id =handlerL))
    match c.bindName {
      case Some(bname) -> {
        val exSlot = allocSlotMsil(fctx, bname, MObject)
        emitStoreSlot(insns, exSlot, fctx.paramCount)
      }
      case None -> {
        insns.add(MPop)
      }
    }
    lowerBlockMsil(cctx, fctx, insns, c.body)
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §7. Block lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerBlockMsil(cctx: in CodegenCtx, fctx: in FuncCtx,
                        insns: in List[MInsn], block: in Block): Unit {
  var i = 0
  while i < block.statements.count {
    lowerStmtMsil(cctx, fctx, insns, block.statements[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §8. Function lowering.
// ─────────────────────────────────────────────────────────────────────────────

// Create a fresh FuncCtx.  Parameters are added to `slots` and `types` but
// NOT to `locals` (they are accessed via MLdarg, not MLdloc).
func makeFuncCtxMsil(pkgName: in String, className: in String,
                     paramCount: in Int): FuncCtx {
  val slots:       Map[String, Int]       = newMap()
  val types:       Map[String, MsilType]  = newMap()
  val locals:      List[MsilType]         = newList()
  val slotTicker:  List[Int]              = newList()
  val labelTicker: List[Int]              = newList()
  val loopBreak:   List[Int]              = newList()
  val loopCont:    List[Int]              = newList()
  FuncCtx(
    pkgName     = pkgName,
    className   = className,
    slots       = slots,
    types       = types,
    locals      = locals,
    slotTicker  = slotTicker,
    labelTicker = labelTicker,
    paramCount  = paramCount,
    loopBreak   = loopBreak,
    loopCont    = loopCont)
}

// Check whether the last meaningful instruction in a list is a return or throw.
func endsWithReturnMsil(insns: in List[MInsn]): Bool {
  var i = insns.count - 1
  while i >= 0 {
    match insns[i] {
      case MRet      -> { return true }
      case MThrow    -> { return true }
      case MNop      -> { i = i - 1 }
      // A label may be a branch target from code above (e.g. the after-label
      // of a match expression), so we cannot treat instructions before it as
      // the effective end of the method.  Stop scanning and report "no terminal".
      case MLabel(_) -> { return false }
      case _         -> { return false }
    }
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §8b. FFI emission for `@externTarget` (#370 + Phase R6).
// ─────────────────────────────────────────────────────────────────────────────

// True iff the annotation list contains `@externTarget("...")`.
func hasExternTargetMsil(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" { return true }
    i = i + 1
  }
  false
}

// Pull the `"Type.Member"` string out of `@externTarget("...")`.
// Returns "" when the annotation is malformed.
func externTargetStringMsil(anns: in List[Annotation]): String {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 and segs[0] == "externTarget" {
      var j = 0
      while j < anns[i].args.count {
        match anns[i].args[j] {
          case ALiteral(v, _) -> match v {
            case AVString(s, _) -> { return s }
            case _              -> ()
          }
          case AAName(_, v, _) -> match v {
            case AVString(s, _) -> { return s }
            case _              -> ()
          }
          case _ -> ()
        }
        j = j + 1
      }
    }
    i = i + 1
  }
  ""
}

// Look up (or add) the AssemblyRef row index for an external
// assembly name.  System.Runtime / mscorlib reuse the pre-seeded
// `lctx.arRuntime` row so we don't write a duplicate.
func internFfiAssemblyRef(cctx: in CodegenCtx, asmName: in String): Int {
  match mapGet(cctx.ffiAsmRefs, asmName) {
    case Some(r) -> r
    case None    -> {
      val row = if asmName == "System.Runtime"
                  or asmName == "System.Private.CoreLib"
                  or asmName == "mscorlib" {
        cctx.lctx.arRuntime
      } else {
        ctxAddAssemblyRef(cctx.lctx, asmName, 10, 0)
      }
      cctx.ffiAsmRefs.add(asmName, row)
      row
    }
  }
}

// Look up (or add) the TypeRef row for a CLR type identified by
// (assembly, namespace, simple name).
func internFfiTypeRef(cctx: in CodegenCtx, asmName: in String,
                      ns: in String, typeName: in String): Int {
  val key = asmName + "/" + ns + "." + typeName
  match mapGet(cctx.ffiTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val arRow = internFfiAssemblyRef(cctx, asmName)
      val tRow  = ctxAddTypeRef(cctx.lctx, ns, typeName, arRow)
      cctx.ffiTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// Build the MSIL body for a `@externTarget`-bearing function.
// Returns true when emission succeeded (caller skips the default
// body lowering); false when the target could not be resolved.
//
// Coverage today:
//   * Static method with primitive / String parameter and return types.
//   * Instance method (receiver = Lyric arg 0) with primitive/string args.
//   * Constructor (..ctor) with primitive/string args.
//
// Deferred: extern types as parameters (need TypeRef-typed signatures),
// generic types, with-defaults trailing arguments, property getters,
// static field reads.  Programs depending on those forms still need
// `--target dotnet-legacy` (F# bootstrap emitter).
func emitExternTargetBody(
  cctx:    in CodegenCtx,
  fctx:    in FuncCtx,
  insns:   in List[MInsn],
  decl:    in FunctionDecl,
  pkgName: in String
): Bool {
  val target = externTargetStringMsil(decl.annotations)
  if target == "" { return false }

  // F0002 (also emitted by the type checker for proof/lint paths,
  // but Msil.Bridge skips type checking — panic here so the user
  // build sees the diagnostic, #790).
  if hasConflictingHints(decl.annotations) {
    panic("Msil.Codegen: function '" + decl.name + "' has both "
      + "@externStatic and @externInstance — pick one (the FFI "
      + "resolver cannot honour both).")
  }

  val hint = hintFromAnnotations(decl.annotations)
  match resolveExternTarget(target, hint) {
    case None -> {
      // #811: malformed @externTarget strings (e.g. "NoDots") leave
      // the caller emitting bare `MRet` with nothing on the stack —
      // a runtime VerificationException with no build-time signal.
      // Mirror the class-typed-params throw-stub below so the build
      // succeeds (the program may not call this function) but any
      // call site receives a clear runtime error.
      val msg = "FFI '" + target + "' on '" + decl.name
        + "' has a malformed @externTarget — expected "
        + "'Namespace.Type.Member' or '..ctor' but the resolver "
        + "could not parse it; verify the @externTarget literal."
      val msgTok = ctxInternUs(cctx.lctx, msg)
      insns.add(MLdStr(token = msgTok))
      insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
      insns.add(MThrow)
      return true
    }
    case Some(r) -> {
      // Map every Lyric param + return type to MSIL.
      val paramTypes: List[MsilType] = newList()
      var pi = 0
      while pi < decl.params.count {
        paramTypes.add(typeExprToMsil(decl.params[pi].ty, pkgName))
        pi = pi + 1
      }
      val retTy = match decl.ret {
        case Some(te) -> typeExprToMsil(te, pkgName)
        case None     -> MVoid
      }

      // The bootstrap-grade FFI resolver hasn't wired up TypeRef-
      // encoded MemberRef signatures yet, so externs whose Lyric
      // signature mentions a non-primitive class type can't emit a
      // direct call yet.  Earlier the codegen returned `false` and
      // the default lowering emitted bare `MRet` — invalid MSIL for
      // non-void returns and a runtime VerificationException with no
      // build-time signal (#791).  Now we emit a *runtime stub* that
      // unconditionally throws a System.Exception carrying the
      // diagnostic message.  The build succeeds (so examples that
      // declare these externs but never call them at runtime — the
      // smoke-test case — still build cleanly), and any call site
      // gets a clear runtime error directing the user to
      // `--target dotnet-legacy`.
      if mentionsMClass(paramTypes) or mentionsMClassRet(retTy) {
        val msg = "FFI '" + target + "' on '" + decl.name
          + "' uses class-typed params or return that the self-hosted "
          + "MSIL emitter does not yet support; rebuild with "
          + "--target dotnet-legacy or wrap the call in a primitive-"
          + "typed shim."
        val msgTok = ctxInternUs(cctx.lctx, msg)
        insns.add(MLdStr(token = msgTok))
        insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
        insns.add(MThrow)
        return true
      }

      val tRefRow = internFfiTypeRef(
        cctx, r.assemblyName, r.namespaceStr, r.typeName)

      // Build the method signature blob.
      val sig =
        if r.isStatic and not r.isCtor {
          buildStaticMethodSig(paramTypes, retTy)
        } else if r.isCtor {
          // .ctor: HASTHIS, void return, all params explicit.
          buildInstanceMethodSig(paramTypes, MVoid)
        } else {
          // Instance method: skip the first Lyric param (it's the
          // receiver — already on the stack as `this`).
          val instArgs: List[MsilType] = newList()
          var ii = 1
          while ii < paramTypes.count {
            instArgs.add(paramTypes[ii])
            ii = ii + 1
          }
          buildInstanceMethodSig(instArgs, retTy)
        }
      val mrRow = ctxAddMemberRef(
        cctx.lctx, tRefRow, r.memberName,
        "ffi_" + target, sig)
      val tok = 0x0A000000 + mrRow

      // Load every Lyric param in order.  For instance calls the
      // receiver is param 0 and lands on the stack first; for static
      // calls every param is explicit.
      var li = 0
      while li < decl.params.count {
        insns.add(MLdarg(slot = li))
        li = li + 1
      }
      if r.isCtor {
        insns.add(MNewobj(ctorToken = tok))
      } else if r.isStatic {
        insns.add(MCall(methodToken = tok))
      } else {
        insns.add(MCallvirt(methodToken = tok))
      }
      insns.add(MRet)
      true
    }
  }
}

// Return true if the list contains an MClass — those need TypeRef-
// encoded class tokens in the signature blob, which the bootstrap-
// grade FFI cascade does not yet synthesise.
func mentionsMClass(types: in List[MsilType]): Bool {
  var i = 0
  while i < types.count {
    match types[i] {
      case MClass(_) -> { return true }
      case MObject   -> { return true }
      case _         -> ()
    }
    i = i + 1
  }
  false
}

func mentionsMClassRet(ty: in MsilType): Bool {
  match ty {
    case MClass(_) -> true
    case MObject   -> true
    case _         -> false
  }
}

pub func lowerFuncMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                       pkgName: in String): MFunc {
  val retTy =
    match decl.ret {
      case Some(te) -> typeExprToMsil(te, pkgName)
      case None     -> MVoid
    }

  val className = pkgName
  val fctx = makeFuncCtxMsil(pkgName, className, decl.params.count)
  val insns: List[MInsn] = newList()

  // Allocate slots for parameters.  These occupy slots 0..N-1 in the
  // combined slot space but are NOT added to fctx.locals.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToMsil(p.ty, pkgName)
    val slot = fctx.slotTicker.count
    fctx.slots.add(p.name, slot)
    fctx.types.add(p.name, paramTy)
    fctx.slotTicker.add(0)
    pi = pi + 1
  }

  // FFI: a function carrying `@externTarget("Type.Member")` synthesises
  // its body from the BCL target (#370 / Phase R6).  Falls through to
  // the normal body lowering when the annotation is absent or the
  // resolver returns None (e.g. extern types in the signature).
  val externEmitted =
    if hasExternTargetMsil(decl.annotations) {
      emitExternTargetBody(cctx, fctx, insns, decl, pkgName)
    } else { false }

  if not externEmitted {
    // Lower the body.
    match decl.body {
      case Some(body) -> {
        match body {
          case FBBlock(block) -> {
            lowerBlockMsil(cctx, fctx, insns, block)
            if not endsWithReturnMsil(insns) {
              insns.add(MRet)
            }
          }
          case FBExpr(e) -> {
            lowerExprMsil(cctx, fctx, insns, e)
            insns.add(MRet)
          }
        }
      }
      case None -> {
        insns.add(MRet)
      }
    }
  }

  // Build parameter type list for MFunc.
  val paramTypes: List[MsilType] = newList()
  var pi2 = 0
  while pi2 < decl.params.count {
    paramTypes.add(typeExprToMsil(decl.params[pi2].ty, pkgName))
    pi2 = pi2 + 1
  }

  MFunc(
    flags    = 0x0016,   // Public | Static | HideBySig
    name     = decl.name,
    params   = paramTypes,
    ret      = retTy,
    insns    = insns,
    maxStack = 16,
    locals   = fctx.locals)
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Record lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerRecordMsil(decl: in RecordDecl, pkgName: in String): MRecord {
  val className = pkgName + "." + decl.name

  val fields: List[MField] = newList()
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case RMField(f) -> {
        fields.add(MField(
          flags     = 0x0001,   // FDA_PUBLIC
          name      = f.name,
          fieldType = typeExprToMsil(f.ty, pkgName)))
      }
      case _ -> {}
    }
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MRecord(
    className = className,
    namespace = pkgName,
    baseClass = "System.Object",
    fields    = fields,
    methods   = methods)
}

// ─────────────────────────────────────────────────────────────────────────────
// §10. Union lowering.
// ─────────────────────────────────────────────────────────────────────────────

pub func lowerUnionMsil(decl: in UnionDecl, pkgName: in String): MUnion {
  val baseName = pkgName + "." + decl.name

  val cases: List[MUnionCase] = newList()
  var i = 0
  while i < decl.cases.count {
    val c = decl.cases[i]
    val caseName = baseName + "$" + c.name
    val caseFields: List[MField] = newList()
    var fi = 0
    while fi < c.fields.count {
      match c.fields[fi] {
        case UFNamed(name, ty, _) -> {
          caseFields.add(MField(
            flags     = 0x0001,
            name      = name,
            fieldType = typeExprToMsil(ty, pkgName)))
        }
        case UFPos(ty, _) -> {
          caseFields.add(MField(
            flags     = 0x0001,
            name      = "field" + toString(fi),
            fieldType = typeExprToMsil(ty, pkgName)))
        }
      }
      fi = fi + 1
    }
    cases.add(MUnionCase(name = caseName, fields = caseFields))
    i = i + 1
  }

  val methods: List[MFunc] = newList()
  MUnion(
    baseName  = baseName,
    namespace = pkgName,
    cases     = cases,
    methods   = methods)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11. Package codegen — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

// Determine whether a function is the program entry point.
func isMainFuncMsil(decl: in FunctionDecl): Bool {
  decl.name == "main" and decl.params.count == 0
}

// Produce an `MPackage` from a parsed source file.
// The caller must subsequently call `lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)`
// to emit the PE bytes.
pub func codegenMPackage(file: in SourceFile, cctx: in CodegenCtx): MPackage {
  val pkgSegs = file.packageDecl.path.segments
  val pkgName = joinSegsMsil(pkgSegs, ".")

  val fns:   List[MFunc]        = newList()
  val items: List[MPackageItem] = newList()
  var hasMain = false

  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IRecord(decl) -> {
        items.add(MPRecord(rec = lowerRecordMsil(decl, pkgName)))
      }
      case IExposedRec(decl) -> {
        items.add(MPRecord(rec = lowerRecordMsil(decl, pkgName)))
      }
      case IFunc(decl) -> {
        fns.add(lowerFuncMsil(cctx, decl, pkgName))
        if isMainFuncMsil(decl) {
          hasMain = true
        }
      }
      case IUnion(decl) -> {
        items.add(MPUnion(u = lowerUnionMsil(decl, pkgName)))
      }
      case IDistinctType(decl) -> {
        val inner = typeExprToMsil(decl.underlying, pkgName)
        items.add(MPDistinctType(d = MDistinctType(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          inner     = inner)))
      }
      case IConst(_)        -> {}
      case IVal(_)          -> {}
      case ITypeAlias(_)    -> {}
      case IEnum(_)         -> {}
      case IOpaque(_)       -> {}
      case IProtected(_)    -> {}
      case IInterface(_)    -> {}
      case IImpl(_)         -> {}
      case IWire(_)         -> {}
      case IScopeKind(_)    -> {}
      case IExtern(_)       -> {}
      case IExternType(_)   -> {}
      case ITest(_)         -> {}
      case IProperty(_)     -> {}
      case IFixture(_)      -> {}
      case IConfig(_)       -> {}
      case IAspect(_)       -> {}
      case IError           -> {}
    }
    i = i + 1
  }

  // If there are functions, emit them as a single host class.
  if fns.count > 0 {
    items.add(MPFuncs(hostClass = pkgName, funcs = fns))
  }

  MPackage(packageName = pkgName, items = items)
}
