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
  tokExcGetMessage:   Int   // Exception.get_Message(): string  instance HASTHIS
  tokObjGetType:      Int   // Object.GetType(): Type  instance HASTHIS
  tokTypeGetName:     Int   // Type.get_Name: string  instance HASTHIS
  // List<object> via TypeSpec (for newList() and list operations)
  tokListObjCtor:      Int   // List<object>::.ctor()  newobj
  tokListObjAdd:       Int   // List<object>::Add(object): void  callvirt
  tokListObjGetItem:   Int   // List<object>::get_Item(int32): object  callvirt
  tokListObjGetCount:  Int   // List<object>::get_Count(): int32  callvirt
  tokListObjTypeSpec:  Int   // TypeSpec token for List<object>  castclass
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
  // Compile-time const values: registered by IConst pre-scan so that EPath
  // references to const names inline ldc.i4 instead of ldsfld.
  constValues:        Map[String, Int]        // constName → inlined Int value
  // FFI caches (#370 + Phase R6).  Populated lazily by
  // emitExternTargetBody as `@externTarget` declarations are walked.
  ffiAsmRefs:         Map[String, Int]   // assembly simple name → AssemblyRef row index
  ffiTypeRefs:        Map[String, Int]   // "asm/ns.name" key → TypeRef row index
  // Lambda / yield / extern-type support (Band 2, R6).
  tokActionCtor:      Int                // System.Action::.ctor(object, native int)
  tokActionInvoke:    Int                // System.Action::Invoke(): void
  actionTypeRefs:     Map[String, Int]   // toString(nparams) → TypeRef row for System.Action`N
  externTypeNames:    Map[String, String]  // Lyric name → CLR FQN (from IExternType items)
  lambdaTicker:       List[Int]          // length = next __lambda_<i> index
  // Instance method MethodDef tokens, keyed by "FQClassName/methodName".  Populated
  // by `addPackageTokens` for record methods, interface methods (abstract slots),
  // and impl methods folded into the implementing record.  `lowerMethodCallMsil`
  // looks these up to emit `callvirt` for user-defined dispatch (#878).
  methodTokens:       Map[String, Int]
  // Pending interface implementations discovered by the IImpl pre-pass.  Each
  // entry maps an implementing record's FQ name to its impl block(s); used to
  // (a) inject impl methods into the target MRecord, and (b) emit MPImpl items
  // after all TypeDefs are lowered so InterfaceImpl / MethodImpl rows can be
  // resolved by name (#878).
  implEntries:        List[ImplEntryMsil]
  // Persistent row counters for multi-package compilation (#1183).
  // `.count` tracks the highest MethodDef / FieldDef row already allocated by
  // prior `addPackageTokens` calls, so the next call starts at `.count + 1`
  // (matching the row-budget pre-scan order in `lowerMPackageWithCtx`).
  // For single-package compile (`Msil.Bridge.compileToMsil`), these are
  // freshly empty and the counter starts at 1 — behaviour unchanged.
  nextMethodDefRow:   List[Int]
  nextFieldDefRow:    List[Int]
}

// One impl block (`impl Iface for Target { … }`) captured by the pre-pass.
// `methods` are produced by `lowerImplMethodMsil`, which reserves slot 0 for
// the implicit `this` so `self` and user parameters resolve correctly when
// the methods are emitted as virtual instance members of the target type.
pub record ImplEntryMsil {
  targetTypeName: String        // FQN, e.g. "Pkg.EnglishGreeter"
  ifaceTypeName:  String        // FQN, e.g. "Pkg.Greeter"
  methods:        List[MFunc]
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

  // System.Type TypeRef (needed for GetType / get_Name)
  val trType = ctxAddTypeRef(lctx, "System", "Type", lctx.arRuntime)

  // Exception.get_Message(): string  instance HASTHIS
  val excGetMsgPs: List[MsilType] = newList()
  val tokExcGetMessage = 0x0A000000 + ctxAddMemberRef(
    lctx, trException, "get_Message",
    "exc_get_message", buildInstanceMethodSig(excGetMsgPs, MString))

  // Object.GetType(): Type  instance HASTHIS
  val objGetTypePs: List[MsilType] = newList()
  val tokObjGetType = 0x0A000000 + ctxAddMemberRef(
    lctx, lctx.trObject, "GetType",
    "obj_gettype", buildInstanceMethodSig(objGetTypePs, MObject))

  // Type.get_Name: string  instance HASTHIS  (Type is reference type; return MString)
  val typeGetNamePs: List[MsilType] = newList()
  val tokTypeGetName = 0x0A000000 + ctxAddMemberRef(
    lctx, trType, "get_Name",
    "type_get_name", buildInstanceMethodSig(typeGetNamePs, MString))

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

  // 24. System.Action TypeRef  (System.Runtime assembly)
  val trAction = ctxAddTypeRef(lctx, "System", "Action", lctx.arRuntime)

  // 25. System.Action::.ctor(object, native int): void  HASTHIS
  // Per ECMA-335: delegate .ctor takes an object (target) and a native int (method ptr).
  val actionCtorPs: List[MsilType] = newList()
  actionCtorPs.add(MObject)
  actionCtorPs.add(MNativeInt)
  val tokActionCtor = 0x0A000000 + ctxAddMemberRef(
    lctx, trAction, ".ctor", "action_ctor", buildInstanceMethodSig(actionCtorPs, MVoid))

  // 26. System.Action::Invoke(): void  HASTHIS
  val actionInvokePs: List[MsilType] = newList()
  val tokActionInvoke = 0x0A000000 + ctxAddMemberRef(
    lctx, trAction, "Invoke", "action_invoke", buildInstanceMethodSig(actionInvokePs, MVoid))

  // System.Action`N TypeRefs are registered lazily on first use for each N
  // (see internActionTypeRef); no static entries here.

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
    tokExcGetMessage     = tokExcGetMessage,
    tokObjGetType        = tokObjGetType,
    tokTypeGetName       = tokTypeGetName,
    tokListObjCtor       = tokListObjCtor,
    tokListObjAdd        = tokListObjAdd,
    tokListObjGetItem    = tokListObjGetItem,
    tokListObjGetCount   = tokListObjGetCount,
    tokListObjTypeSpec   = 0x1B000000 + tsListObj,
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
    constValues          = newMap(),
    ffiAsmRefs           = newMap(),
    ffiTypeRefs          = newMap(),
    tokActionCtor        = tokActionCtor,
    tokActionInvoke      = tokActionInvoke,
    actionTypeRefs       = newMap(),
    externTypeNames      = newMap(),
    lambdaTicker         = newList(),
    methodTokens         = newMap(),
    implEntries          = newList(),
    nextMethodDefRow     = newList(),
    nextFieldDefRow      = newList())
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Token pre-scan — addPackageTokens.
// ─────────────────────────────────────────────────────────────────────────────

// Pre-scan the AST and assign MethodDef/FieldDef row numbers for every
// record, function, union case, interface method, opaque type, and protected
// type in the package.  Must be called before any `lowerFuncMsil` invocations
// so that intra-package call and field-access tokens are available.
//
// Row numbering follows codegenMPackage + lowerMPackageWithCtx emit order:
//   1. Non-IFunc items in source order (IRecord, IUnion, IInterface, IOpaque,
//      IProtected, etc.) — each contributes MethodDef rows in the same order
//      as its lowerM* counterpart.
//   2. MPFuncs (added last by codegenMPackage): optional .cctor row (when any
//      IVal has a non-literal initialiser), then one row per IFunc item.
pub func addPackageTokens(cctx: in CodegenCtx, file: in SourceFile,
                          pkgName: in String): Unit {
  // Collect IExternType names so auto-FFI call interception can resolve them.
  scanExternTypesMsil(cctx, file)

  // Resume row numbering from where the previous package's pre-scan left off
  // (#1183 — multi-package compilation).  For a single-package compile via
  // `Msil.Bridge.compileToMsil`, the cctx is fresh and both counters are
  // empty, so the starting rows are 1/1 — behaviour unchanged.
  var methodDefRow = cctx.nextMethodDefRow.count + 1
  var fieldDefRow  = cctx.nextFieldDefRow.count + 1

  // Pre-scan: does any IVal need a `.cctor` (non-literal init)?
  // After the literal-IVal inlining fix, only non-literal IVals produce
  // a non-empty initInsns list and therefore a .cctor MethodDef row.
  //
  // Threading a `constEnv` of `val` names seen so far lets us treat
  // `val b = a` (where `a` is itself literal) as literal too — without
  // this, every later val that references an earlier literal val forces
  // `hasValCctor = true`, allocating a phantom `.cctor` MethodDef and
  // shifting every subsequent IFunc token by one (silent miscompile).
  val constEnv: Map[String, Bool] = newMap()
  var hasValCctor = false
  var pi = 0
  while pi < file.items.count {
    match file.items[pi].kind {
      case IVal(decl) -> {
        val isLit = isLiteralI4ExprMsilWithEnv(decl.init, constEnv)
        if not isLit {
          hasValCctor = true
        }
        match decl.pattern.kind {
          case PBinding(valName, _) -> constEnv.add(valName, isLit)
          case _                    -> {}  // non-simple bindings can't appear in EPath
        }
      }
      case _ -> {}
    }
    pi = pi + 1
  }

  // Pass 1: source-order scan for non-IFunc items that emit MethodDef rows.
  // #878: collect impl-method (target, name) pairs in two parallel flat lists
  // so the per-record row budget includes the injected impl methods.  A flat
  // list avoids the Map[String,List[String]] + inner newList() pattern that the
  // F# bootstrap emitter does not support.
  val implImplTargets: List[String] = newList()
  val implImplNames:   List[String] = newList()
  var ipi = 0
  while ipi < file.items.count {
    match file.items[ipi].kind {
      case IImpl(idecl) -> {
        val targetName = implTargetNameMsil(idecl, pkgName)
        var imi = 0
        while imi < idecl.members.count {
          match idecl.members[imi] {
            case IMplFunc(fn) -> {
              implImplTargets.add(targetName)
              implImplNames.add(fn.name)
            }
            case IMplAssoc(_) -> {}
          }
          imi = imi + 1
        }
      }
      case _ -> {}
    }
    ipi = ipi + 1
  }

  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IRecord(decl) -> {
        // lowerMRecord: FieldDef per field; .ctor MethodDef; RMFunc MethodDefs;
        // followed by injected impl-method MethodDefs (#878).
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
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              cctx.methodTokens.add(className + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              methodDefRow = methodDefRow + 1
            }
            case _ -> {}
          }
          mi = mi + 1
        }
        // Register impl-method tokens for this record (#878).
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni],
                                  0x06000000 + methodDefRow)
            methodDefRow = methodDefRow + 1
          }
          ni = ni + 1
        }
      }
      case IExposedRec(decl) -> {
        // Same layout as IRecord.
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
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case RMFunc(fn) -> {
              cctx.methodTokens.add(className + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              methodDefRow = methodDefRow + 1
            }
            case _ -> {}
          }
          mi = mi + 1
        }
        var ni = 0
        while ni < implImplTargets.count {
          if implImplTargets[ni] == className {
            cctx.methodTokens.add(className + "/" + implImplNames[ni],
                                  0x06000000 + methodDefRow)
            methodDefRow = methodDefRow + 1
          }
          ni = ni + 1
        }
      }
      case IUnion(decl) -> {
        // lowerMUnion: base abstract methods (usually 0) + one lowerMRecord per case.
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
      case IInterface(decl) -> {
        // lowerMInterface: one abstract MethodDef per IMSig/IMFunc (rva=0, no body).
        // Register each abstract slot in `methodTokens` so callvirt against an
        // interface-typed receiver can dispatch through the interface vtable
        // (#878).
        val ifaceName = pkgName + "." + decl.name
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig)  -> {
              cctx.methodTokens.add(ifaceName + "/" + sig.name,
                                    0x06000000 + methodDefRow)
              methodDefRow = methodDefRow + 1
            }
            case IMFunc(fn)  -> {
              cctx.methodTokens.add(ifaceName + "/" + fn.name,
                                    0x06000000 + methodDefRow)
              methodDefRow = methodDefRow + 1
            }
            case IMAssoc(_) -> {}
          }
          mi = mi + 1
        }
      }
      case IOpaque(decl) -> {
        // lowerMOpaque: FieldDef per OMField; .ctor MethodDef; no explicit methods.
        if decl.hasBody {
          val className = pkgName + "." + decl.name
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(_)     -> { fieldDefRow = fieldDefRow + 1 }
              case OMInvariant(_) -> {}
            }
            fi = fi + 1
          }
          cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
          methodDefRow = methodDefRow + 1
        }
      }
      case IProtected(decl) -> {
        // lowerProtectedMsil emits an MPRecord:
        //   recFields from PMField; recMethods from PMEntry/PMFunc.
        // lowerMRecord then adds: FieldDef per field; .ctor; one MethodDef per method.
        val className = pkgName + "." + decl.name
        var fi = 0
        while fi < decl.members.count {
          match decl.members[fi] {
            case PMField(_) -> { fieldDefRow = fieldDefRow + 1 }
            case _          -> {}
          }
          fi = fi + 1
        }
        cctx.recordCtorTokens.add(className, 0x06000000 + methodDefRow)
        methodDefRow = methodDefRow + 1
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMEntry(_) -> { methodDefRow = methodDefRow + 1 }
            case PMFunc(_)  -> { methodDefRow = methodDefRow + 1 }
            case _          -> {}
          }
          mi = mi + 1
        }
      }
      // IDistinctType, IRangeType, IEnum, IImpl: 0 MethodDef rows in non-MPFuncs.
      // IConst, IVal, IFunc: handled below (go to MPFuncs, emitted last).
      case _ -> {}
    }
    i = i + 1
  }

  // Pass 2: MPFuncs — optional .cctor then IFunc items (in source order).
  if hasValCctor {
    methodDefRow = methodDefRow + 1
  }
  var j = 0
  while j < file.items.count {
    match file.items[j].kind {
      case IFunc(decl) -> {
        cctx.funcTokens.add(decl.name, 0x06000000 + methodDefRow)
        // Generator functions always return List<object> (MObject) regardless of
        // the source-level annotation.  Use the same isGenerator logic as
        // lowerFuncMsil so that call sites in funcRetTypes agree with the actual
        // emitted signature — avoids void-typed locals when callers store the result.
        val isGen = decl.isAsync and funcBodyContainsYieldMsil(decl)
        val retTy = if isGen {
          MObject
        } else if startsWith(decl.name, "__lambda_") {
          // For synthetic lambdas: the return type was set during lambda lifting based on
          // whether the body ends with an expression (implicit return) or not.
          // If ret is Some(...), use that; otherwise default to MVoid.
          match decl.ret {
            case Some(te) -> typeExprToMsil(te, pkgName)
            case None     -> MVoid
          }
        } else {
          match decl.ret {
            case Some(te) -> typeExprToMsil(te, pkgName)
            case None     -> MVoid
          }
        }
        cctx.funcRetTypes.add(decl.name, retTy)
        methodDefRow = methodDefRow + 1
      }
      case _ -> {}
    }
    j = j + 1
  }

  // Sync the persistent counters so a follow-up `addPackageTokens` call
  // (multi-package compile, #1183) starts where this one left off.  Pad the
  // counter list to length = (methodDefRow - 1) — the highest row this call
  // allocated — by appending zero-valued entries.  The list elements are
  // never read; only `.count` matters.
  while cctx.nextMethodDefRow.count < methodDefRow - 1 {
    cctx.nextMethodDefRow.add(0)
  }
  while cctx.nextFieldDefRow.count < fieldDefRow - 1 {
    cctx.nextFieldDefRow.add(0)
  }
}

// True when an IVal's init expression will produce a single MLdcI4 instruction
// (so no .cctor is needed after the literal-inlining fix).
func isLiteralI4ExprMsil(e: in Expr): Bool {
  val empty: Map[String, Bool] = newMap()
  isLiteralI4ExprMsilWithEnv(e, empty)
}

// Env-aware variant: consult `env` when the expression is a bare EPath whose
// segment matches a previously-seen `val` name.  Lets `val b = a` (with
// `val a = 7`) resolve to literal, so the pre-scan does not allocate a
// phantom `.cctor` (which would shift MethodDef tokens for all later IFuncs).
func isLiteralI4ExprMsilWithEnv(e: in Expr, env: in Map[String, Bool]): Bool {
  match e.kind {
    case ELiteral(lit) -> match lit {
      case LInt(v, _)  -> intToLong(longToInt(v)) == v  // fits in I4
      case LBool(_)    -> true
      case LChar(_)    -> true
      case LUnit       -> true  // 0 insns emitted; no .cctor needed
      case _           -> false
    }
    case EParen(inner) -> isLiteralI4ExprMsilWithEnv(inner, env)
    case EPath(path) -> {
      if path.segments.count == 1 and env.containsKey(path.segments[0]) {
        match mapGet(env, path.segments[0]) {
          case Some(b) -> b
          case None    -> false
        }
      } else {
        false
      }
    }
    case _             -> false
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
  // EYield support: slot of the List<object> yield collector when inside a generator.
  // Empty when the function is not a generator; singleton when it is.
  yieldSlots:  List[Int]
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
      } else if seg == "Object" {
        MObject
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
          // Check for a module-level compile-time const (inline ldc.i4).
          match mapGet(cctx.constValues, name) {
            case Some(v) -> {
              insns.add(MLdcI4(v = v))
              MInt
            }
            case None -> {
              // Unknown name — emit null as a safe fallback.
              insns.add(MLdNull)
              MObject
            }
          }
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
          // TyException built-in members: .message and .typeName.
          // Catch-clause exception bindings are stored as MObject; detect by member name.
          if memberName == "message" {
            insns.add(MCallvirt(methodToken = cctx.tokExcGetMessage))
            MString
          } else if memberName == "typeName" {
            insns.add(MCallvirt(methodToken = cctx.tokObjGetType))
            insns.add(MCallvirt(methodToken = cctx.tokTypeGetName))
            MString
          } else if memberName == "count" {
            // castclass makes the stack type explicit as List<object> so the JIT
            // can verify the callvirt when the receiver was produced by a call
            // returning Object (e.g. a generator function).
            insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
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

    // ── Yield: collect-all model (R6) ────────────────────────────────────────
    // Each `yield e` appends e to the per-function List<object> collector that
    // was allocated at function entry by lowerFuncMsil when it detected the
    // @async_generator annotation.  Returns MVoid so the statement wrapper pops
    // nothing (void instructions push nothing).
    case EYield(inner) -> {
      if fctx.yieldSlots.count > 0 {
        val collSlot = fctx.yieldSlots[0]
        insns.add(MLdloc(slot = collSlot - fctx.paramCount))
        // The collector local is typed `object` (MObject) but `List<object>::Add`
        // expects `this` to be `List<object>`.  Castclass narrows the stack type
        // so the JIT verifier accepts the callvirt.
        insns.add(MCastclass(typeToken = cctx.tokListObjTypeSpec))
        val eTy = lowerExprMsil(cctx, fctx, insns, inner)
        boxIfNeededMsil(cctx, insns, eTy)
        insns.add(MCallvirt(methodToken = cctx.tokListObjAdd))
      } else {
        panic("Msil.Codegen: yield outside async generator — front-end should have rejected this")
      }
      MVoid
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
    // ── Lambda: non-capturing, emitted as a lifted __lambda_<i> static method ──
    // Lambda-lifting pre-pass (liftLambdasMsil) has already extracted each
    // ELambda into a synthetic IFunc named __lambda_<i>.  Here we allocate
    // the next index from lambdaTicker and look up the pre-assigned MethodDef.
    // Delegate type selection based on param count:
    //   0 params → System.Action             (non-generic, tokActionCtor)
    //   N params → System.Action`N<object,…> (TypeSpec via buildActionNCtorTok)
    // All lifted lambdas have void return (Unit), so only Action variants are needed.
    case ELambda(lparams, _) -> {
      val idx = cctx.lambdaTicker.count
      cctx.lambdaTicker.add(0)
      val lname = "__lambda_" + toString(idx)
      val nparams = lparams.count
      match mapGet(cctx.funcTokens, lname) {
        case Some(tok) -> {
          // Determine delegate type based on lambda return type.
          // Lambdas that return void use System.Action; those with non-void returns use System.Func.
          val retType = mapGet(cctx.funcRetTypes, lname)
          val returnsVoid = match retType {
            case Some(MVoid) -> true
            case None        -> true
            case _           -> false
          }
          val ctorTok =
            if returnsVoid {
              if nparams == 0 { cctx.tokActionCtor }
              else            { buildActionNCtorTok(cctx, nparams) }
            } else {
              buildFuncNCtorTok(cctx, nparams)
            }
          insns.add(MLdNull)
          insns.add(MLdftn(methodToken = tok))
          insns.add(MNewobj(ctorToken = ctorTok))
          MObject
        }
        case None -> {
          panic("Msil.Codegen: lambda token missing for " + lname + " — liftLambdasMsil pre-pass was not run")
          MObject
        }
      }
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
    // Record constructor call: EnglishGreeter(field1, field2, ...) → newobj .ctor.
    // Check recordCtorTokens before funcTokens so that record names are handled
    // even when they shadow a same-named function (which is disallowed by the
    // type checker anyway).
    val ctorKey = fctx.pkgName + "." + funcName
    match mapGet(cctx.recordCtorTokens, ctorKey) {
      case Some(ctorTok) -> {
        var ci = 0
        while ci < args.count {
          lowerCallArgMsil(cctx, fctx, insns, args[ci])
          ci = ci + 1
        }
        insns.add(MNewobj(ctorToken = ctorTok))
        MClass(className = ctorKey)
      }
      case None -> {
        // Check if funcName is a local variable (e.g. a lambda stored as Action/Action`N).
        // Load the delegate, push args, then callvirt Invoke.  Select the correct
        // Invoke MemberRef based on argument count to match the delegate arity.
        match mapGet(fctx.slots, funcName) {
          case Some(slot) -> {
            insns.add(MLdloc(slot = slot - fctx.paramCount))
            var i = 0
            while i < args.count {
              val argTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
              // Action<object,...>.Invoke expects object for every param — box value types.
              boxIfNeededMsil(cctx, insns, argTy)
              i = i + 1
            }
            val invokeTok =
              if args.count == 0 { cctx.tokActionInvoke }
              else               { buildActionNInvokeTok(cctx, args.count) }
            insns.add(MCallvirt(methodToken = invokeTok))
            MVoid
          }
          case None -> {
            // Intra-package static call.
            match mapGet(cctx.funcTokens, funcName) {
              case Some(tok) -> {
                var i = 0
                while i < args.count {
                  lowerCallArgMsil(cctx, fctx, insns, args[i])
                  i = i + 1
                }
                insns.add(MCall(methodToken = tok))
                match mapGet(cctx.funcRetTypes, funcName) {
                  case Some(rt) -> rt
                  case None     -> MObject
                }
              }
              case None -> {
                // Cross-package call (record/union/opaque constructors in this
                // package were already handled by the outer recordCtorTokens
                // lookup above).  Push the args and fall through; the caller
                // is responsible for picking the right call site.
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
      }
    }
  }
}

// Lower a method call on a receiver: recv.memberName(args…).
// Dispatches by name to known BCL tokens for List<object> and
// Dictionary<object,object>; falls back to a safe stub for unknowns.
//
// #878: when the receiver is statically typed as a user-defined class (either
// a record or an interface), look up the corresponding instance MethodDef
// token in `cctx.methodTokens` and emit `callvirt` so virtual / interface
// dispatch happens at the call site.  Falls back to the BCL-name dispatch
// below for `MObject` receivers (e.g. List/Dict).
func lowerMethodCallMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  recv:       in Expr,
  memberName: in String,
  args:       in List[CallArg]
): MsilType {
  // Auto-FFI: if the receiver is an EPath whose name maps to an extern CLR type,
  // emit a direct callvirt to the CLR method rather than a stub.
  match recv.kind {
    case EPath(path) -> {
      val recvName = lastSegmentMsil(path)
      match mapGet(cctx.externTypeNames, recvName) {
        case Some(clrFqn) -> {
          return emitAutoFfiCallMsil(cctx, fctx, insns, recv, memberName, args, clrFqn)
        }
        case None -> {}
      }
    }
    case _ -> {}
  }
  val recvTy = lowerExprMsil(cctx, fctx, insns, recv)
  // User-defined instance / interface dispatch path (#878).
  match recvTy {
    case MClass(cls) -> {
      match mapGet(cctx.methodTokens, cls + "/" + memberName) {
        case Some(tok) -> {
          var i = 0
          while i < args.count {
            val aTy = lowerCallArgMsil(cctx, fctx, insns, args[i])
            boxIfNeededMsil(cctx, insns, aTy)
            i = i + 1
          }
          insns.add(MCallvirt(methodToken = tok))
          return MObject
        }
        case None -> {}   // fall through to BCL-name dispatch
      }
    }
    case _ -> {}
  }
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
    case STry(body, catches, finally_) -> {
      lowerTryCatchMsil(cctx, fctx, insns, body, catches, finally_)
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
  cctx:     in CodegenCtx,
  fctx:     in FuncCtx,
  insns:    in List[MInsn],
  body:     in Block,
  catches:  in List[CatchClause],
  finally_: in Option[Block]
): Unit {
  val hasCatch   = catches.count > 0
  val hasFinally = match finally_ { case Some(_) -> true case None -> false }
  val tryStartL  = freshLabelMsil(fctx)
  val afterL     = freshLabelMsil(fctx)

  insns.add(MLabel(id = tryStartL))
  lowerBlockMsil(cctx, fctx, insns, body)
  if hasCatch or hasFinally {
    // `leave` is required (not `br`) when exiting a CLR protected region.
    insns.add(MLeave(label = afterL))
  }

  // The `tryEnd` label for all catch EHClauses = first insn after the try body.
  // It is placed right before the first catch handler (or before the finally
  // handler when there are no catch clauses).
  val tryBodyEndL = freshLabelMsil(fctx)
  insns.add(MLabel(id = tryBodyEndL))

  var i = 0
  while i < catches.count {
    val c = catches[i]
    val handlerStartL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerStartL))
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
    insns.add(MLeave(label = afterL))
    val handlerEndL = freshLabelMsil(fctx)
    insns.add(MLabel(id = handlerEndL))
    // System.Exception typed catch: flags=0, token = TypeRef RID for System.Exception.
    insns.add(MEHClause(
      flags        = 0,
      tryStart     = tryStartL,
      tryEnd       = tryBodyEndL,
      handlerStart = handlerStartL,
      handlerEnd   = handlerEndL,
      catchToken   = 0x01000000 + cctx.trException))
    i = i + 1
  }

  // Finally handler: covers the entire try+catch region ([tryStartL, finallyStartL)).
  // `leave` in the try/catch body transfers to afterL; the CLR runs the finally
  // handler before transferring.  `endfinally` resumes the leave target or
  // rethrows the in-flight exception.
  match finally_ {
    case None -> {}
    case Some(fb) -> {
      val finallyStartL = freshLabelMsil(fctx)
      val finallyEndL   = freshLabelMsil(fctx)
      insns.add(MLabel(id = finallyStartL))
      lowerBlockMsil(cctx, fctx, insns, fb)
      insns.add(MEndfinally)
      insns.add(MLabel(id = finallyEndL))
      insns.add(MEHClause(
        flags        = 2,
        tryStart     = tryStartL,
        tryEnd       = finallyStartL,
        handlerStart = finallyStartL,
        handlerEnd   = finallyEndL,
        catchToken   = 0))
    }
  }

  insns.add(MLabel(id = afterL))
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
  val yieldSlots:  List[Int]              = newList()
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
    loopCont    = loopCont,
    yieldSlots  = yieldSlots)
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

// Return the TypeRef row for System.Action`N (N ≥ 1).
// TypeRefs are registered lazily on first use for each distinct N and cached
// in cctx.actionTypeRefs to avoid duplicate metadata rows.
func internActionTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val typeName = "Action`" + key
      val tRow = ctxAddTypeRef(cctx.lctx, "System", typeName, cctx.lctx.arRuntime)
      cctx.actionTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// Build a newobj token for System.Action`N<object,...> (N ≥ 1).
// Encodes a TypeSpec for the closed generic instantiation and returns
// the MemberRef token (0x0A...) for .ctor(object, native int).
func buildActionNCtorTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val trN = internActionTypeRef(cctx, nparams)
  // TypeDefOrRef coded index for a TypeRef at row R: (R << 2) | 1
  val codedIdx = (trN * 4) + 1
  val objArgs: List[MsilType] = newList()
  var ai = 0
  while ai < nparams { objArgs.add(MObject); ai = ai + 1 }
  val gblob = buildGenericInstBlob(codedIdx, objArgs)
  val specKey = "ActionSpec_ctor_" + toString(nparams)
  val tsRow = ctxAddTypeSpec(cctx.lctx, specKey, gblob)
  val ctorPs: List[MsilType] = newList()
  ctorPs.add(MObject)
  ctorPs.add(MNativeInt)
  val ctorSig = buildInstanceMethodSig(ctorPs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, ".ctor",
    "action_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
}

// Build a callvirt token for System.Action`N<object,...>::Invoke(object,...).
func buildActionNInvokeTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val trN = internActionTypeRef(cctx, nparams)
  val codedIdx = (trN * 4) + 1
  val objArgs: List[MsilType] = newList()
  var ai = 0
  while ai < nparams { objArgs.add(MObject); ai = ai + 1 }
  val gblob = buildGenericInstBlob(codedIdx, objArgs)
  val specKey = "ActionSpec_invoke_" + toString(nparams)
  val tsRow = ctxAddTypeSpec(cctx.lctx, specKey, gblob)
  val invokePs: List[MsilType] = newList()
  var pi = 0
  while pi < nparams { invokePs.add(MTypeVar(pi)); pi = pi + 1 }
  val invokeSig = buildInstanceMethodSig(invokePs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, "Invoke",
    "action_invoke_" + toString(nparams), invokeSig)
  0x0A000000 + mrRow
}

// Get or create a TypeRef for System.Func`(nparams+1) where nparams is the lambda parameter count.
// Reuses the actionTypeRefs map with a "func_N" key to avoid collisions.
func internFuncTypeRef(cctx: in CodegenCtx, nparams: in Int): Int {
  val key = "func_" + toString(nparams)
  match mapGet(cctx.actionTypeRefs, key) {
    case Some(r) -> r
    case None    -> {
      val funcArity = nparams + 1
      val typeName = "Func`" + toString(funcArity)
      val tRow = ctxAddTypeRef(cctx.lctx, "System", typeName, cctx.lctx.arRuntime)
      cctx.actionTypeRefs.add(key, tRow)
      tRow
    }
  }
}

// Build a newobj token for System.Func`(nparams+1)<object,...,object>::.ctor(object, nativeint).
// All type parameters are object: nparams input parameters + 1 return type.
func buildFuncNCtorTok(cctx: in CodegenCtx, nparams: in Int): Int {
  val trN = internFuncTypeRef(cctx, nparams)
  val codedIdx = (trN * 4) + 1
  val objArgs: List[MsilType] = newList()
  var ai = 0
  while ai < nparams + 1 { objArgs.add(MObject); ai = ai + 1 }
  val gblob = buildGenericInstBlob(codedIdx, objArgs)
  val specKey = "FuncSpec_ctor_" + toString(nparams)
  val tsRow = ctxAddTypeSpec(cctx.lctx, specKey, gblob)
  val ctorPs: List[MsilType] = newList()
  ctorPs.add(MObject)
  ctorPs.add(MNativeInt)
  val ctorSig = buildInstanceMethodSig(ctorPs, MVoid)
  val mrRow = ctxAddMemberRefForTypeSpec(
    cctx.lctx, tsRow, ".ctor",
    "func_ctor_" + toString(nparams), ctorSig)
  0x0A000000 + mrRow
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
      // The FFI resolver could not locate `target` in any loaded
      // reference assembly.  Falling through with a bare `MRet`
      // produced invalid IL for non-void returns and a runtime
      // VerificationException with no build-time signal (#1041).
      // Emit a runtime stub that throws on call so smoke-test
      // builds (declare-but-never-call) still build cleanly and
      // actual call sites get a clear runtime error.
      val msg = "FFI extern '" + target + "' on '" + decl.name
        + "' could not be resolved to a method on any loaded "
        + "reference assembly; check the @externTarget annotation."
      val msgTok = ctxInternUs(cctx.lctx, msg)
      insns.add(MLdStr(token = msgTok))
      insns.add(MNewobj(ctorToken = cctx.tokExceptionCtor))
      insns.add(MThrow)
      true
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

// True when a function body (or expression) contains at least one EYield node.
func exprContainsYieldMsil(e: in Expr): Bool {
  match e.kind {
    case EYield(_)         -> true
    case EBlock(b)         -> blockContainsYieldMsil(b)
    case EUnsafe(b)        -> blockContainsYieldMsil(b)
    case EIf(c, t, el, _) -> {
      if exprContainsYieldMsil(c) { return true }
      val tRes = match t {
        case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
        case EOBBlock(blk) -> blockContainsYieldMsil(blk)
      }
      if tRes { return true }
      match el {
        case Some(elB) -> match elB {
          case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
          case EOBBlock(blk) -> blockContainsYieldMsil(blk)
        }
        case None -> false
      }
    }
    case ECall(fn, args) -> {
      if exprContainsYieldMsil(fn) { return true }
      var ai = 0
      while ai < args.count {
        val res = match args[ai] {
          case CAPositional(ex) -> exprContainsYieldMsil(ex)
          case CANamed(_, ex, _) -> exprContainsYieldMsil(ex)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case EBinop(_, l, r)  -> exprContainsYieldMsil(l) or exprContainsYieldMsil(r)
    case EPrefix(_, op)   -> exprContainsYieldMsil(op)
    case EParen(inner)    -> exprContainsYieldMsil(inner)
    case EMember(recv, _) -> exprContainsYieldMsil(recv)
    case EAwait(inner)    -> exprContainsYieldMsil(inner)
    case ESpawn(inner)    -> exprContainsYieldMsil(inner)
    case ETry(inner)      -> exprContainsYieldMsil(inner)
    case EPropagate(inner) -> exprContainsYieldMsil(inner)
    case EMatch(scr, arms) -> {
      if exprContainsYieldMsil(scr) { return true }
      var ai = 0
      while ai < arms.count {
        val res = match arms[ai].body {
          case EOBExpr(ex)   -> exprContainsYieldMsil(ex)
          case EOBBlock(blk) -> blockContainsYieldMsil(blk)
        }
        if res { return true }
        ai = ai + 1
      }
      false
    }
    case _ -> false
  }
}

func stmtContainsYieldMsil(s: in Statement): Bool {
  match s.kind {
    case SExpr(e)  -> exprContainsYieldMsil(e)
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init)    -> exprContainsYieldMsil(init)
        case LBLet(_, _, init)    -> exprContainsYieldMsil(init)
        case LBVar(_, _, initOpt) -> match initOpt {
          case Some(init) -> exprContainsYieldMsil(init)
          case None       -> false
        }
      }
    }
    case SReturn(valOpt) -> match valOpt {
      case Some(e) -> exprContainsYieldMsil(e)
      case None    -> false
    }
    case SAssign(_, _, v) -> exprContainsYieldMsil(v)
    case SThrow(e)        -> exprContainsYieldMsil(e)
    case SWhile(_, c, b)  -> exprContainsYieldMsil(c) or blockContainsYieldMsil(b)
    case SFor(_, _, i, b) -> exprContainsYieldMsil(i) or blockContainsYieldMsil(b)
    case SLoop(_, b)      -> blockContainsYieldMsil(b)
    case SScope(_, b)     -> blockContainsYieldMsil(b)
    case SDefer(b)        -> blockContainsYieldMsil(b)
    case STry(b, catches, finally_) -> {
      if blockContainsYieldMsil(b) { return true }
      var ci = 0
      while ci < catches.count {
        if blockContainsYieldMsil(catches[ci].body) { return true }
        ci = ci + 1
      }
      match finally_ {
        case None     -> false
        case Some(fb) -> blockContainsYieldMsil(fb)
      }
    }
    case _ -> false
  }
}

func blockContainsYieldMsil(block: in Block): Bool {
  var i = 0
  while i < block.statements.count {
    if stmtContainsYieldMsil(block.statements[i]) { return true }
    i = i + 1
  }
  false
}

func funcBodyContainsYieldMsil(decl: in FunctionDecl): Bool {
  match decl.body {
    case Some(body) -> match body {
      case FBBlock(blk) -> blockContainsYieldMsil(blk)
      case FBExpr(e)    -> exprContainsYieldMsil(e)
    }
    case None -> false
  }
}

pub func lowerFuncMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                       pkgName: in String): MFunc {
  val isGenerator = decl.isAsync and funcBodyContainsYieldMsil(decl)

  // Generators return List<object> (the collected yield values), regardless
  // of what the source-level return type annotation says.
  val retTy =
    if isGenerator {
      MObject
    } else if startsWith(decl.name, "__lambda_") {
      // Synthetic lambda functions always return void.  We bypass decl.ret
      // entirely here: the bootstrap F# emitter may construct the FunctionDecl
      // with None<object> rather than None<TypeExpr> in the ret slot, causing
      // both `case Some` and `case None` arms to fail their isinst checks.
      // When emitMatch falls through it emits ldnull, giving retTy = null, which
      // yields 0x00 (ELEMENT_TYPE_END) in the method signature and triggers a
      // BadImageFormatException at load time.
      MVoid
    } else {
      match decl.ret {
        case Some(te) -> {
          val resolved = typeExprToMsil(te, pkgName)
          if elementTypeByte(resolved) == 0 { MVoid } else { resolved }
        }
        case None -> MVoid
      }
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

  // Generator preamble: allocate a List<object> yield collector and record
  // its slot index in fctx.yieldSlots so that EYield lowering can append to it.
  if isGenerator {
    insns.add(MNewobj(ctorToken = cctx.tokListObjCtor))
    val collSlot = allocSlotMsil(fctx, "__yield_collector", MObject)
    insns.add(MStloc(slot = collSlot - fctx.paramCount))
    fctx.yieldSlots.add(collSlot)
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
            // Three-way dispatch based on function kind:
            //   generators     → lowerBlockMsil (discard) + yield-collector return
            //   non-void       → lowerBlockExprMsil (keep trailing value on stack)
            //   void/Unit      → lowerBlockMsil (discard) + bare MRet
            if isGenerator {
              lowerBlockMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                val collSlot2 = fctx.yieldSlots[0]
                insns.add(MLdloc(slot = collSlot2 - fctx.paramCount))
                insns.add(MRet)
              }
            } else if retTy != MVoid {
              val _ = lowerBlockExprMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                insns.add(MRet)
              }
            } else {
              lowerBlockMsil(cctx, fctx, insns, block)
              if not endsWithReturnMsil(insns) {
                insns.add(MRet)
              }
            }
          }
          case FBExpr(e) -> {
            lowerExprMsil(cctx, fctx, insns, e)
            if isGenerator {
              insns.add(MPop)
              val collSlot3 = fctx.yieldSlots[0]
              insns.add(MLdloc(slot = collSlot3 - fctx.paramCount))
            }
            insns.add(MRet)
          }
        }
      }
      case None -> {
        if isGenerator {
          val collSlot4 = fctx.yieldSlots[0]
          insns.add(MLdloc(slot = collSlot4 - fctx.paramCount))
        }
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

// Lower an `impl Iface for Target { func m(…) { … } }` member into an MFunc
// that will be emitted as a virtual instance method on the target type.
//
// Differs from `lowerFuncMsil` in two ways:
//   1. Slot 0 is reserved for the implicit `this` (the receiver).  `self` in
//      the body lowers to `ldarg.0` (see `ESelf` in `lowerExprMsil`), so it
//      naturally points at the receiver.  User parameters occupy slots 1..N.
//      Lyric `impl` methods never include `self` in `decl.params`; the
//      receiver is always implicit, so no `hasExplicitSelf` check is needed.
//   2. The returned `MFunc.flags` carry `Public | Virtual | HideBySig` without
//      `NewSlot` or `Final` — the CLR wires the method to the interface slot
//      by name-matching.  See msil_self_test_m11.l for validation.
//
// The `MFunc.params` list excludes `this`; the signature builder
// (`buildInstanceMethodSig`) prepends the HASTHIS bit.
pub func lowerImplMethodMsil(cctx: in CodegenCtx, decl: in FunctionDecl,
                              pkgName: in String,
                              targetTypeName: in String): MFunc {
  val retTy = match decl.ret {
    case Some(te) -> typeExprToMsil(te, pkgName)
    case None     -> MVoid
  }
  // paramCount = 1 (this) + declared params.  emitLoadSlot/emitStoreSlot
  // distinguish params from locals by comparing slot indices against this.
  // Use targetTypeName (e.g. "Pkg.EnglishGreeter") as className so that
  // `self.method()` dispatch via MClass(fctx.className) resolves to the
  // correct methodTokens key.
  val fctx = makeFuncCtxMsil(pkgName, targetTypeName, 1 + decl.params.count)
  fctx.slotTicker.add(0)   // slot 0 = this, no name binding

  val insns: List[MInsn] = newList()

  // Allocate slots 1..N for user parameters.
  var pi = 0
  while pi < decl.params.count {
    val p = decl.params[pi]
    val paramTy = typeExprToMsil(p.ty, pkgName)
    val slot = fctx.slotTicker.count   // 1, 2, …
    fctx.slots.add(p.name, slot)
    fctx.types.add(p.name, paramTy)
    fctx.slotTicker.add(0)
    pi = pi + 1
  }

  // Lower the body — mirrors `lowerFuncMsil`'s logic but always non-extern.
  match decl.body {
    case Some(body) -> {
      match body {
        case FBBlock(block) -> {
          if retTy != MVoid {
            val _ = lowerBlockExprMsil(cctx, fctx, insns, block)
          } else {
            lowerBlockMsil(cctx, fctx, insns, block)
          }
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
    case None -> insns.add(MRet)
  }

  val paramTypes: List[MsilType] = newList()
  var pi2 = 0
  while pi2 < decl.params.count {
    paramTypes.add(typeExprToMsil(decl.params[pi2].ty, pkgName))
    pi2 = pi2 + 1
  }

  // Public | Virtual | HideBySig — no NewSlot/Final so CLR wires the
  // concrete method to the interface slot by name-matching, matching the
  // pattern used in msil_self_test_m11.l.
  val instanceFlags = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG

  MFunc(
    flags    = instanceFlags,
    name     = decl.name,
    params   = paramTypes,
    ret      = retTy,
    insns    = insns,
    maxStack = 16,
    locals   = fctx.locals)
}

// Return the last `.`-separated segment of `qualified` (the simple type name).
// E.g. `"Pkg.Greeter"` → `"Greeter"`, `"Greeter"` → `"Greeter"`.
pub func simpleNameOfQualifiedMsil(qualified: in String): String {
  var i = qualified.length - 1
  while i >= 0 {
    if qualified[i] == '.' {
      return qualified.substring(i + 1, qualified.length - i - 1)
    }
    i = i - 1
  }
  qualified
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
// §11. Band-2 helpers — aspect weaver, protected types, wire blocks.
// ─────────────────────────────────────────────────────────────────────────────

// Check whether an annotation list contains an annotation with the given head name.
func hasAnnotationMsil(anns: in List[Annotation], headName: in String): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count > 0 and segs[0] == headName {
      return true
    }
    i = i + 1
  }
  false
}

// ── Aspect weaver ─────────────────────────────────────────────────────────────

// Check whether a function name matches a POSIX-ish glob pattern.
// Supports * (any substring), ? (any single char).  Returns true on full match.
func globMatchMsil(glob: in String, name: in String): Bool {
  if glob == "*" { return true }
  if glob == name { return true }
  // Simple linear scan for * wildcard.
  var gi = 0
  var ni = 0
  while gi < glob.length and ni < name.length {
    val gc = glob[gi]
    if gc == '*' {
      // Consume the star then try each remaining position in name.
      gi = gi + 1
      if gi >= glob.length { return true }
      while ni < name.length {
        if globMatchMsil(glob.substring(gi), name.substring(ni)) { return true }
        ni = ni + 1
      }
      return false
    } else if gc == '?' {
      gi = gi + 1
      ni = ni + 1
    } else if gc == name[ni] {
      gi = gi + 1
      ni = ni + 1
    } else {
      return false
    }
  }
  // Consume trailing stars.
  while gi < glob.length and glob[gi] == '*' {
    gi = gi + 1
  }
  gi >= glob.length and ni >= name.length
}

// Check whether a function matches an aspect matcher predicate.
func matchesAspectMatcherMsil(matcher: in AspectMatcher, fn: in FunctionDecl): Bool {
  match matcher {
    case AMNameLike(glob, _) -> globMatchMsil(glob, fn.name)
    case AMAnnotated(annotName, _) -> hasAnnotationMsil(fn.annotations, annotName)
    case AMVisibility(vis, _) -> {
      match vis {
        case "pub" -> match fn.visibility {
          case Some(v) -> match v { case VisPub(_) -> true; case _ -> false }
          case None    -> false
        }
        case _ -> true
      }
    }
    case AMSignatureReturns(_, _) -> true  // bootstrap: skip return-type glob
  }
}

// Check whether a function is excluded from matching `aspectName`.
// `@no_aspect` with no args opts the function out of every aspect;
// `@no_aspect(Foo)` (or `@no_aspect(Foo, Bar)`) opts out only the
// named aspects, leaving others free to match.
func isOptedOutMsil(fn: in FunctionDecl, aspectName: in String): Bool {
  var i = 0
  while i < fn.annotations.count {
    val ann = fn.annotations[i]
    val segs = ann.name.segments
    if segs.count > 0 and segs[0] == "no_aspect" {
      // Bare `@no_aspect` (no args) → opt out of everything.
      if ann.args.count == 0 { return true }
      // Targeted `@no_aspect(Name1, Name2, …)` → opt out only when
      // `aspectName` is in the arg list.  Both `AAName` and `ABare`
      // are accepted; only the leading identifier portion matters.
      var j = 0
      while j < ann.args.count {
        val argName = match ann.args[j] {
          case AAName(n, _, _) -> n
          case ABare(n, _)     -> n
        }
        if argName == aspectName { return true }
        j = j + 1
      }
    }
    i = i + 1
  }
  false
}

// Check whether a function matches an aspect (all matchers AND, not in exceptNames).
func matchesAspectMsil(aspect: in AspectDecl, fn: in FunctionDecl): Bool {
  if isOptedOutMsil(fn, aspect.name) { return false }
  var ei = 0
  while ei < aspect.exceptNames.count {
    if aspect.exceptNames[ei] == fn.name { return false }
    ei = ei + 1
  }
  if aspect.matches.count == 0 { return false }
  var mi = 0
  while mi < aspect.matches.count {
    if not matchesAspectMatcherMsil(aspect.matches[mi], fn) { return false }
    mi = mi + 1
  }
  true
}

// Rewrite `proceed(args)` → `targetFuncName(p1, p2, ...)` in an expression
// tree.  Mirrors `rewriteProceeds` in `bootstrap/src/Lyric.Emitter/Weaver.fs`
// and `Lyric.Weaver.rewriteBlock` — the F# version is the spec, this port
// is what the self-hosted MSIL pipeline runs.  Without a proper AST walk
// the call to `proceed()` inside an aspect `around` body is silently
// dropped: the wrapped function never executes.
//
// Bootstrap-grade parity: `proceed`'s own argument list is ignored; the
// substitute always forwards the wrapper's own parameter list (matches the
// F# Weaver and `args.field` is not supported in this slice).

// Make a single-segment EPath expression at a zero span.
func makeProceedPathExpr(name: in String): Expr {
  val sp  = makeSpan(initialPosition(), initialPosition())
  val seg: List[String] = newList()
  seg.add(name)
  val mp  = ModulePath(segments = seg, span = sp)
  Expr(kind = EPath(path = mp), span = sp)
}

// Build the replacement ECall `targetFuncName(p1, p2, ...)`.
func proceedSubstitutionMsil(targetFuncName: in String, paramNames: in List[String]): Expr {
  val args: List[CallArg] = newList()
  var i = 0
  while i < paramNames.count {
    args.add(CAPositional(expr = makeProceedPathExpr(paramNames[i])))
    i = i + 1
  }
  Expr(
    kind = ECall(fn = makeProceedPathExpr(targetFuncName), args = args),
    span = makeSpan(initialPosition(), initialPosition()))
}

func isProceedCallMsil(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, _) -> {
      match f.kind {
        case EPath(path) ->
          path.segments.count == 1 and path.segments[0] == "proceed"
        case _ -> false
      }
    }
    case _ -> false
  }
}

// True for any `proceed(...)` call whose argument list is non-empty.  The
// bootstrap-grade rewriter always forwards the wrapper's own parameters
// regardless of what the user passed, so a non-empty arg list is silently
// dropped — panic instead so the author sees a clear diagnostic at build
// time rather than a baffling runtime mismatch (#1141).
func isProceedCallWithArgsMsil(expr: in Expr): Bool {
  match expr.kind {
    case ECall(f, args) -> {
      match f.kind {
        case EPath(path) ->
          path.segments.count == 1 and path.segments[0] == "proceed" and args.count > 0
        case _ -> false
      }
    }
    case _ -> false
  }
}

func rewriteProceedExprMsil(targetFuncName: in String, paramNames: in List[String], expr: in Expr): Expr {
  if isProceedCallWithArgsMsil(expr) {
    panic("Msil.Codegen: proceed(...) with explicit arguments is not supported by the bootstrap aspect weaver; the wrapper's own parameter list is always forwarded.  Drop the arguments or wait for the v1.x weaver (#1141).")
  }
  if isProceedCallMsil(expr) {
    return proceedSubstitutionMsil(targetFuncName, paramNames)
  }
  val s = expr.span
  match expr.kind {
    case ECall(f, args) -> {
      val newArgs: List[CallArg] = newList()
      var i = 0
      while i < args.count {
        newArgs.add(rewriteProceedCallArgMsil(targetFuncName, paramNames, args[i]))
        i = i + 1
      }
      Expr(kind = ECall(
        fn   = rewriteProceedExprMsil(targetFuncName, paramNames, f),
        args = newArgs), span = s)
    }
    case EParen(inner) ->
      Expr(kind = EParen(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ETuple(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteProceedExprMsil(targetFuncName, paramNames, xs[i]))
        i = i + 1
      }
      Expr(kind = ETuple(exprs = newXs), span = s)
    }
    case EList(xs) -> {
      val newXs: List[Expr] = newList()
      var i = 0
      while i < xs.count {
        newXs.add(rewriteProceedExprMsil(targetFuncName, paramNames, xs[i]))
        i = i + 1
      }
      Expr(kind = EList(exprs = newXs), span = s)
    }
    case EAwait(inner) ->
      Expr(kind = EAwait(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EYield(inner) ->
      Expr(kind = EYield(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ESpawn(inner) ->
      Expr(kind = ESpawn(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case ETry(inner) ->
      Expr(kind = ETry(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EOld(inner) ->
      Expr(kind = EOld(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPropagate(inner) ->
      Expr(kind = EPropagate(inner = rewriteProceedExprMsil(targetFuncName, paramNames, inner)), span = s)
    case EPrefix(op, operand) ->
      Expr(kind = EPrefix(op = op, operand = rewriteProceedExprMsil(targetFuncName, paramNames, operand)), span = s)
    case EBinop(op, l, r) ->
      Expr(kind = EBinop(
        op  = op,
        lhs = rewriteProceedExprMsil(targetFuncName, paramNames, l),
        rhs = rewriteProceedExprMsil(targetFuncName, paramNames, r)), span = s)
    case EAssign(t, op, v) ->
      Expr(kind = EAssign(
        target = rewriteProceedExprMsil(targetFuncName, paramNames, t),
        op     = op,
        value  = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case EMember(recv, n) ->
      Expr(kind = EMember(
        receiver   = rewriteProceedExprMsil(targetFuncName, paramNames, recv),
        memberName = n), span = s)
    case EIndex(recv, idxs) -> {
      val newIdxs: List[Expr] = newList()
      var i = 0
      while i < idxs.count {
        newIdxs.add(rewriteProceedExprMsil(targetFuncName, paramNames, idxs[i]))
        i = i + 1
      }
      Expr(kind = EIndex(
        receiver = rewriteProceedExprMsil(targetFuncName, paramNames, recv),
        indices  = newIdxs), span = s)
    }
    case ETypeApp(f, targs) ->
      Expr(kind = ETypeApp(
        fn   = rewriteProceedExprMsil(targetFuncName, paramNames, f),
        args = targs), span = s)
    case EIf(cond, thenB, elseB, form) -> {
      val newElse = match elseB {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedEOBMsil(targetFuncName, paramNames, e))
      }
      Expr(kind = EIf(
        cond       = rewriteProceedExprMsil(targetFuncName, paramNames, cond),
        thenBranch = rewriteProceedEOBMsil(targetFuncName, paramNames, thenB),
        elseBranch = newElse,
        thenForm   = form), span = s)
    }
    case EMatch(scrut, arms) ->
      Expr(kind = EMatch(
        scrutinee = rewriteProceedExprMsil(targetFuncName, paramNames, scrut),
        arms      = rewriteProceedMatchArmsMsil(targetFuncName, paramNames, arms)), span = s)
    case ELambda(lparams, body) ->
      Expr(kind = ELambda(
        lambdaParams = lparams,
        body         = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case EBlock(blk) ->
      Expr(kind = EBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EUnsafe(blk) ->
      Expr(kind = EUnsafe(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk)), span = s)
    case EInterpolated(segs) -> {
      val newSegs: List[InterpolatedSegment] = newList()
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISText(t, sp) -> newSegs.add(ISText(text = t, span = sp))
          case ISExpr(e)     ->
            newSegs.add(ISExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)))
        }
        i = i + 1
      }
      Expr(kind = EInterpolated(segments = newSegs), span = s)
    }
    // True leaves (no sub-expressions): ELiteral, EPath, ESelf, EResult, ERange, EError.
    // EForall / EExists carry body sub-expressions but are panic-rejected
    // by the bootstrap MSIL codegen before this rewriter runs (see lines
    // 1231 / 1234 above), and aspect `around` bodies cannot legally hold
    // a `proceed()` call inside a contract predicate, so leaving them in
    // the catch-all is intentional rather than an oversight (#1142).
    case _ -> expr
  }
}

func rewriteProceedCallArgMsil(targetFuncName: in String, paramNames: in List[String], arg: in CallArg): CallArg {
  match arg {
    case CAPositional(v)     -> CAPositional(expr = rewriteProceedExprMsil(targetFuncName, paramNames, v))
    case CANamed(n, v, span) -> CANamed(name = n, value = rewriteProceedExprMsil(targetFuncName, paramNames, v), span = span)
  }
}

func rewriteProceedEOBMsil(targetFuncName: in String, paramNames: in List[String], eob: in ExprOrBlock): ExprOrBlock {
  match eob {
    case EOBBlock(blk) -> EOBBlock(block = rewriteProceedBlockMsil(targetFuncName, paramNames, blk))
    case EOBExpr(e)    -> EOBExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e))
  }
}

func rewriteProceedMatchArmsMsil(targetFuncName: in String, paramNames: in List[String], arms: in List[MatchArm]): List[MatchArm] {
  val newArms: List[MatchArm] = newList()
  var i = 0
  while i < arms.count {
    val a = arms[i]
    val newGuard = match a.guard {
      case Some(g) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, g))
      case None    -> None
    }
    newArms.add(MatchArm(
      pattern = a.pattern,
      guard   = newGuard,
      body    = rewriteProceedEOBMsil(targetFuncName, paramNames, a.body),
      span    = a.span))
    i = i + 1
  }
  newArms
}

func rewriteProceedBindingMsil(targetFuncName: in String, paramNames: in List[String], b: in LocalBinding): LocalBinding {
  match b {
    case LBVal(pat, ty, init) ->
      LBVal(pat = pat, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
    case LBVar(name, ty, optInit) -> {
      val newInit = match optInit {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      LBVar(name = name, ty = ty, init = newInit)
    }
    case LBLet(name, ty, init) ->
      LBLet(name = name, ty = ty, init = rewriteProceedExprMsil(targetFuncName, paramNames, init))
  }
}

func rewriteProceedStmtMsil(targetFuncName: in String, paramNames: in List[String], stmt: in Statement): Statement {
  val s = stmt.span
  match stmt.kind {
    case SExpr(e) ->
      Statement(kind = SExpr(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SReturn(opt) -> {
      val newOpt = match opt {
        case None    -> None
        case Some(e) -> Some(value = rewriteProceedExprMsil(targetFuncName, paramNames, e))
      }
      Statement(kind = SReturn(value = newOpt), span = s)
    }
    case SLocal(binding) ->
      Statement(kind = SLocal(binding = rewriteProceedBindingMsil(targetFuncName, paramNames, binding)), span = s)
    case SAssign(t, op, v) ->
      Statement(kind = SAssign(
        target = rewriteProceedExprMsil(targetFuncName, paramNames, t),
        op     = op,
        value  = rewriteProceedExprMsil(targetFuncName, paramNames, v)), span = s)
    case SThrow(e) ->
      Statement(kind = SThrow(expr = rewriteProceedExprMsil(targetFuncName, paramNames, e)), span = s)
    case SFor(lbl, pat, iter, body) ->
      Statement(kind = SFor(
        label = lbl,
        pat   = pat,
        iter  = rewriteProceedExprMsil(targetFuncName, paramNames, iter),
        body  = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SWhile(lbl, cond, body) ->
      Statement(kind = SWhile(
        label = lbl,
        cond  = rewriteProceedExprMsil(targetFuncName, paramNames, cond),
        body  = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SLoop(lbl, body) ->
      Statement(kind = SLoop(label = lbl, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case SScope(b, body) ->
      Statement(kind = SScope(binding = b, body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    case STry(body, catches, finally_) -> {
      val newBody = rewriteProceedBlockMsil(targetFuncName, paramNames, body)
      val newCatches: List[CatchClause] = newList()
      var i = 0
      while i < catches.count {
        val cc = catches[i]
        newCatches.add(CatchClause(
          typeName = cc.typeName,
          bindName = cc.bindName,
          body     = rewriteProceedBlockMsil(targetFuncName, paramNames, cc.body),
          span     = cc.span))
        i = i + 1
      }
      val newFinally = match finally_ {
        case None     -> None
        case Some(fb) -> Some(rewriteProceedBlockMsil(targetFuncName, paramNames, fb))
      }
      Statement(kind = STry(body = newBody, catches = newCatches, finally_ = newFinally), span = s)
    }
    case SDefer(body) ->
      Statement(kind = SDefer(body = rewriteProceedBlockMsil(targetFuncName, paramNames, body)), span = s)
    // SBreak, SContinue, SInvariant, SRule, SItem: pass through
    case _ -> stmt
  }
}

func rewriteProceedBlockMsil(targetFuncName: in String, paramNames: in List[String], blk: in Block): Block {
  val newStmts: List[Statement] = newList()
  var i = 0
  while i < blk.statements.count {
    newStmts.add(rewriteProceedStmtMsil(targetFuncName, paramNames, blk.statements[i]))
    i = i + 1
  }
  Block(statements = newStmts, span = blk.span)
}

// Public entry: rewrite `proceed()` in the aspect's around body to call
// the renamed target function with the original function's params.
func rewriteProceedMsil(body: in Block, targetFuncName: in String, paramNames: in List[String]): Block {
  rewriteProceedBlockMsil(targetFuncName, paramNames, body)
}

// Wrap a Block in Some(FBBlock(block = b)): Option[FunctionBody].
// The explicit return type annotation ensures the bootstrap emitter binds the
// generic type param T of Option to FunctionBody (using ctx.ReturnType as a
// hint) instead of falling back to obj, which would cause pattern matches on
// the resulting option to silently miss both Some and None branches.
func makeSomeFBBlock(b: in Block): Option[FunctionBody] {
  Some(FBBlock(block = b))
}

// Synthesise a wrapper FunctionDecl for an aspect application.
// The wrapper has the aspect's around body; any call to "proceed" in it
// is rewritten to call `targetFuncName`.
func buildAspectWrapperMsil(originalFn: in FunctionDecl, aspect: in AspectDecl,
                             targetFuncName: in String): Option[FunctionDecl] {
  match aspect.around {
    case None -> None
    case Some(around) -> {
      // Build the wrapper: same signature as the original function.
      // Forward the wrapper's parameter list into `proceed()` (matches
      // F# Weaver.fs bootstrap-grade behaviour: `proceed`'s own arg list
      // is ignored).
      val paramNames: List[String] = newList()
      var pi = 0
      while pi < originalFn.params.count {
        paramNames.add(originalFn.params[pi].name)
        pi = pi + 1
      }
      val wrapperBody = rewriteProceedMsil(around.body, targetFuncName, paramNames)
      val wrapper = FunctionDecl(
        docComments  = newList(),
        annotations  = originalFn.annotations,
        visibility   = originalFn.visibility,
        isAsync      = false,
        name         = originalFn.name,
        generics     = None,
        params       = originalFn.params,
        ret          = originalFn.ret,
        whereClause  = None,
        contracts    = originalFn.contracts,
        body         = makeSomeFBBlock(wrapperBody),
        span         = originalFn.span)
      Some(wrapper)
    }
  }
}

// Rename a function decl (returns a new decl with a different name).
func renameFuncMsil(fn: in FunctionDecl, newName: in String): FunctionDecl {
  FunctionDecl(
    docComments  = fn.docComments,
    annotations  = fn.annotations,
    visibility   = fn.visibility,
    isAsync      = fn.isAsync,
    name         = newName,
    generics     = fn.generics,
    params       = fn.params,
    ret          = fn.ret,
    whereClause  = fn.whereClause,
    contracts    = fn.contracts,
    body         = fn.body,
    span         = fn.span)
}

// Aspect-weaving pre-pass: collect all IAspect items, then for each IFunc that
// matches an aspect, rename the original to `__aspect_target_<i>_<name>` and
// synthesise a wrapper with the original name.  Returns the rewritten SourceFile.
pub func weaveAspectsMsil(file: in SourceFile): SourceFile {
  // Collect aspect declarations.
  val aspects: List[AspectDecl] = newList()
  var ai = 0
  while ai < file.items.count {
    match file.items[ai].kind {
      case IAspect(decl) -> aspects.add(decl)
      case _             -> {}
    }
    ai = ai + 1
  }

  if aspects.count == 0 {
    return file   // nothing to do
  }

  // Build the rewritten item list.
  val newItems: List[Item] = newList()
  var ii = 0
  while ii < file.items.count {
    val item = file.items[ii]
    match item.kind {
      case IFunc(fn) -> {
        // Find the first matching aspect (if any).
        var matched = false
        var asp = 0
        while asp < aspects.count and not matched {
          val aspect = aspects[asp]
          if matchesAspectMsil(aspect, fn) {
            match aspect.around {
              case None -> {}
              case Some(_) -> {
                val targetName = "__aspect_target_" + toString(asp) + "_" + fn.name
                val renamedFn  = renameFuncMsil(fn, targetName)
                val renamedItem = Item(docComments = item.docComments, annotations = item.annotations, visibility = item.visibility, kind = IFunc(decl = renamedFn), span = item.span)
                newItems.add(renamedItem)
                match buildAspectWrapperMsil(fn, aspect, targetName) {
                  case Some(wrapper) -> {
                    val wrapperItem = Item(docComments = item.docComments, annotations = item.annotations, visibility = item.visibility, kind = IFunc(decl = wrapper), span = item.span)
                    newItems.add(wrapperItem)
                  }
                  case None -> {}
                }
                matched = true
              }
            }
          }
          asp = asp + 1
        }
        if not matched {
          newItems.add(item)
        }
      }
      case IAspect(_) -> {}  // drop aspect declarations from the output
      case _ -> newItems.add(item)
    }
    ii = ii + 1
  }

  SourceFile(
    moduleDoc        = file.moduleDoc,
    fileAnnotations  = file.fileAnnotations,
    packageDecl      = file.packageDecl,
    imports          = file.imports,
    items            = newItems,
    span             = file.span)
}

// ── Protected type lowering ───────────────────────────────────────────────────

// Lower an IProtected declaration to a sealed class with Monitor-based entry locking.
// Each PMEntry becomes a public method that acquires the lock, runs the body, releases it.
// The lock object is a private `object __lock` field.
func lowerProtectedMsil(cctx: in CodegenCtx, decl: in ProtectedTypeDecl,
                         pkgName: in String, items: in List[MPackageItem],
                         fns: in List[MFunc]): Unit {
  // For Band-2 bootstrap: emit the protected type as a regular record.
  // Full Monitor locking (Enter/Exit in a try/finally) deferred to Phase R6.
  // The type's fields are emitted as a record; entries become public methods.
  val recFields: List[MField] = newList()
  val recMethods: List[MFunc] = newList()

  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case PMField(pf) -> {
        match pf {
          case PFVar(name, ty, _, _) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC,
              name      = name,
              fieldType = typeExprToMsil(ty, pkgName)))
          }
          case PFLet(name, ty, _, _) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC + FDA_INIT_ONLY,
              name      = name,
              fieldType = typeExprToMsil(ty, pkgName)))
          }
          case PFImmutable(f) -> {
            recFields.add(MField(
              flags     = FDA_PUBLIC + FDA_INIT_ONLY,
              name      = f.name,
              fieldType = typeExprToMsil(f.ty, pkgName)))
          }
        }
      }
      case PMEntry(ed) -> {
        // Entry method: for bootstrap, emit as a regular function without locking.
        // Note: `entry` is a Lyric reserved keyword so we bind to `ed` here.
        val pTypes: List[MsilType] = newList()
        var pi = 0
        while pi < ed.params.count {
          pTypes.add(typeExprToMsil(ed.params[pi].ty, pkgName))
          pi = pi + 1
        }
        val retTy = match ed.ret {
          case Some(te) -> typeExprToMsil(te, pkgName)
          case None     -> MVoid
        }
        val entryFctx = makeFuncCtxMsil(pkgName, pkgName + "." + decl.name, ed.params.count)
        var epi = 0
        while epi < ed.params.count {
          val p     = ed.params[epi]
          val paramTy = typeExprToMsil(p.ty, pkgName)
          val slot  = entryFctx.slotTicker.count
          entryFctx.slots.add(p.name, slot)
          entryFctx.types.add(p.name, paramTy)
          entryFctx.slotTicker.add(0)
          epi = epi + 1
        }
        val entryInsns: List[MInsn] = newList()
        match ed.body {
          case FBBlock(block) -> {
            // Mirror the lowerFuncMsil retTy dispatch: non-void entry
            // bodies keep the trailing expression on the stack as the
            // return value; void/Unit entries discard it (#1039).
            if retTy != MVoid {
              val _ = lowerBlockExprMsil(cctx, entryFctx, entryInsns, block)
            } else {
              lowerBlockMsil(cctx, entryFctx, entryInsns, block)
            }
          }
          case FBExpr(e) -> {
            lowerExprMsil(cctx, entryFctx, entryInsns, e)
            entryInsns.add(MRet)
          }
        }
        if not endsWithReturnMsil(entryInsns) {
          entryInsns.add(MRet)
        }
        recMethods.add(MFunc(
          flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
          name     = ed.name,
          params   = pTypes,
          ret      = retTy,
          insns    = entryInsns,
          maxStack = 16,
          locals   = entryFctx.locals))
      }
      case PMFunc(fn) -> {
        val mf = lowerFuncMsil(cctx, fn, pkgName + "." + decl.name)
        recMethods.add(MFunc(
          flags    = MDA_PUBLIC + MDA_VIRTUAL + MDA_HIDE_BY_SIG,
          name     = mf.name,
          params   = mf.params,
          ret      = mf.ret,
          insns    = mf.insns,
          maxStack = mf.maxStack,
          locals   = mf.locals))
      }
      case PMInvariant(_) -> {}
    }
    mi = mi + 1
  }

  items.add(MPRecord(rec = MRecord(
    className = pkgName + "." + decl.name,
    namespace = pkgName,
    baseClass = "System.Object",
    fields    = recFields,
    methods   = recMethods)))
}

// ── Wire block lowering ───────────────────────────────────────────────────────

// Lower a wire block to a static factory class with a `create()` method that
// instantiates the dependency graph in topological order.
// For Band-2 bootstrap, we support WMSingleton and WMLocal members.
func lowerWireMsil(cctx: in CodegenCtx, decl: in WireDecl,
                   pkgName: in String, items: in List[MPackageItem],
                   fns: in List[MFunc]): Unit {
  // Synthesise a static factory function `<wireName>_create()` that
  // allocates each singleton in dependency order and returns the root.
  val createInsns: List[MInsn] = newList()
  val createFctx  = makeFuncCtxMsil(pkgName, pkgName, 0)
  val createLocals: List[MsilType] = newList()

  var mi = 0
  while mi < decl.members.count {
    match decl.members[mi] {
      case WMSingleton(name, ty, init, _) -> {
        // Allocate a local slot for this singleton.
        val localTy   = typeExprToMsil(ty, pkgName)
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMLocal(name, ty, init, _) -> {
        val localTy   = match ty {
          case Some(t) -> typeExprToMsil(t, pkgName)
          case None    -> MObject
        }
        val localSlot = allocSlotMsil(createFctx, name, localTy)
        lowerExprMsil(cctx, createFctx, createInsns, init)
        createInsns.add(MStloc(slot = localSlot - createFctx.paramCount))
      }
      case WMExpose(name, _) -> {
        // Return the exposed component.
        match mapGet(createFctx.slots, name) {
          case Some(slot) -> {
            createInsns.add(MLdloc(slot = slot - createFctx.paramCount))
          }
          case None -> {
            createInsns.add(MLdNull)
          }
        }
      }
      case _ -> {}
    }
    mi = mi + 1
  }
  createInsns.add(MRet)

  val createRetTy = MObject   // bootstrap: return object
  fns.add(MFunc(
    flags    = MDA_PUBLIC + MDA_STATIC + MDA_HIDE_BY_SIG,
    name     = decl.name + "_create",
    params   = newList(),
    ret      = createRetTy,
    insns    = createInsns,
    maxStack = 16,
    locals   = createFctx.locals))
}

// ─────────────────────────────────────────────────────────────────────────────
// §11b. Lambda-lifting pre-pass (Band 2, R6).
// ─────────────────────────────────────────────────────────────────────────────
//
// Extracts every ELambda in the file into a synthetic IFunc named __lambda_<i>
// so that addPackageTokens assigns deterministic MethodDef tokens before codegen.
// The ELambda nodes themselves are left in place; ELambda codegen then looks up
// __lambda_<i> by index from lambdaTicker.

// A zero-span position for synthetic AST nodes.
func syntheticPosition(): Position {
  Position(offset = 0, line = 0, column = 0)
}

func syntheticSpan(): Span {
  val p = syntheticPosition()
  Span(startPos = p, endPos = p)
}

// Check if a Block ends with an expression statement (SExpr).
// If true, the block has an implicit return value; otherwise it returns Unit/void.
func blockEndsWithExpr(block: in Block): Bool {
  if block.statements.count == 0 {
    false
  } else {
    val lastStmt = block.statements[block.statements.count - 1]
    match lastStmt.kind {
      case SExpr(_) -> true
      case _ -> false
    }
  }
}

// Convert a LambdaParam to a full Param (mode=PMIn, ty=Object).
// All lifted lambda params are typed as Object because the delegate types used
// (System.Action`N<object,...>) expect object parameters.  If the lambda body
// uses a param typed Int/Bool/etc., the value arrives as a boxed object and the
// body works regardless (bootstrap-grade: unboxing is implicit via object field
// access or is unnecessary for void-body lambdas like the test cases here).
func lambdaParamToParam(lp: in LambdaParam): Param {
  val seg: List[String] = newList()
  seg.add("Object")
  val ty = TypeExpr(kind = TRef(path = ModulePath(segments = seg, span = syntheticSpan())),
                    span = syntheticSpan())
  Param(mode = PMIn, name = lp.name, ty = ty, dflt = None, span = lp.span)
}

// BFS lambda-lifting helpers — collect ELambda nodes in breadth-first order
// so that indices assigned here match the order codegenMsil encounters them.
//
// The BFS contract: when an ELambda is found, assign its index, create the
// synthetic IFunc, and push the lambda body onto `deferred` for later
// processing.  Do NOT recurse into the lambda body here.  The caller
// (liftLambdasMsil) drains `deferred` in FIFO order after all top-level
// expressions are processed, which naturally matches the codegen traversal
// order (outer lambdas numbered before any nested lambda in their bodies).
func collectLambdasBfsExpr(e: in Expr, ticker: in List[Int], synths: in List[Item], deferred: in List[Block]): Unit {
  match e.kind {
    case ELambda(lparams, body) -> {
      // BFS: assign index, create synthetic IFunc, defer body (no recursion here).
      val idx = ticker.count
      ticker.add(0)
      val lname = "__lambda_" + toString(idx)
      val params: List[Param] = newList()
      var lpi = 0
      while lpi < lparams.count {
        params.add(lambdaParamToParam(lparams[lpi]))
        lpi = lpi + 1
      }
      // Infer return type: if the body ends with SExpr, the lambda implicitly returns that value (Object in bootstrap).
      // Otherwise, it returns Unit (void, ret = None).
      val retTy: Option[TypeExpr] =
        if blockEndsWithExpr(body) {
          val seg: List[String] = newList()
          seg.add("Object")
          Some(TypeExpr(kind = TRef(path = ModulePath(segments = seg, span = syntheticSpan())),
                        span = syntheticSpan()))
        } else {
          None
        }
      val decl = FunctionDecl(
        docComments = newList(),
        annotations = newList(),
        visibility  = None,
        isAsync     = false,
        name        = lname,
        generics    = None,
        params      = params,
        ret         = retTy,
        whereClause = None,
        contracts   = newList(),
        body        = Some(FBBlock(block = body)),
        span        = syntheticSpan())
      synths.add(Item(
        docComments = newList(),
        annotations = newList(),
        visibility  = None,
        kind        = IFunc(decl = decl),
        span        = syntheticSpan()))
      deferred.add(body)
    }
    case ECall(fn, args) -> {
      collectLambdasBfsExpr(fn, ticker, synths, deferred)
      var ai = 0
      while ai < args.count {
        match args[ai] {
          case CAPositional(ex)    -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case CANamed(_, ex, _)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
        }
        ai = ai + 1
      }
    }
    case EBinop(_, lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case EPrefix(_, operand)  -> { collectLambdasBfsExpr(operand, ticker, synths, deferred) }
    case EParen(inner)        -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EMember(recv, _)     -> { collectLambdasBfsExpr(recv, ticker, synths, deferred) }
    case EIf(cond, thenB, elseOpt, _) -> {
      collectLambdasBfsExpr(cond, ticker, synths, deferred)
      match thenB {
        case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
        case EOBBlock(blk) -> {
          var si = 0
          while si < blk.statements.count {
            collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
            si = si + 1
          }
        }
      }
      match elseOpt {
        case Some(elseB) -> {
          match elseB {
            case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
            case EOBBlock(blk) -> {
              var ei = 0
              while ei < blk.statements.count {
                collectLambdasBfsStmt(blk.statements[ei], ticker, synths, deferred)
                ei = ei + 1
              }
            }
          }
        }
        case None -> {}
      }
    }
    case EBlock(block) -> {
      var si = 0
      while si < block.statements.count {
        collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case EUnsafe(block) -> {
      var si = 0
      while si < block.statements.count {
        collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case EMatch(scr, arms) -> {
      collectLambdasBfsExpr(scr, ticker, synths, deferred)
      var ai = 0
      while ai < arms.count {
        match arms[ai].body {
          case EOBExpr(ex)   -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case EOBBlock(blk) -> {
            var si = 0
            while si < blk.statements.count {
              collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
              si = si + 1
            }
          }
        }
        ai = ai + 1
      }
    }
    case EList(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectLambdasBfsExpr(exprs[ei], ticker, synths, deferred)
        ei = ei + 1
      }
    }
    case EIndex(recv, indices) -> {
      collectLambdasBfsExpr(recv, ticker, synths, deferred)
      var ii = 0
      while ii < indices.count {
        collectLambdasBfsExpr(indices[ii], ticker, synths, deferred)
        ii = ii + 1
      }
    }
    case EAwait(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EYield(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case ESpawn(inner)     -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case ETry(inner)       -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EPropagate(inner) -> { collectLambdasBfsExpr(inner, ticker, synths, deferred) }
    case EAssign(_, _, v)  -> { collectLambdasBfsExpr(v, ticker, synths, deferred) }
    case EInterpolated(segs) -> {
      var si = 0
      while si < segs.count {
        match segs[si] {
          case ISExpr(ex) -> { collectLambdasBfsExpr(ex, ticker, synths, deferred) }
          case _          -> {}
        }
        si = si + 1
      }
    }
    case ETuple(exprs) -> {
      var ei = 0
      while ei < exprs.count {
        collectLambdasBfsExpr(exprs[ei], ticker, synths, deferred)
        ei = ei + 1
      }
    }
    case ETypeApp(fn, _)  -> { collectLambdasBfsExpr(fn, ticker, synths, deferred) }
    case _ -> {}
  }
}

func collectLambdasBfsStmt(s: in Statement, ticker: in List[Int], synths: in List[Item], deferred: in List[Block]): Unit {
  match s.kind {
    case SLocal(binding) -> match binding {
      case LBVal(_, _, init)    -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
      case LBLet(_, _, init)    -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
      case LBVar(_, _, initOpt) -> match initOpt {
        case Some(init) -> { collectLambdasBfsExpr(init, ticker, synths, deferred) }
        case None       -> {}
      }
    }
    case SAssign(_, _, v)  -> { collectLambdasBfsExpr(v, ticker, synths, deferred) }
    case SReturn(valOpt)   -> match valOpt {
      case Some(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
      case None    -> {}
    }
    case SExpr(e)  -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SThrow(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SWhile(_, cond, body) -> {
      collectLambdasBfsExpr(cond, ticker, synths, deferred)
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SFor(_, _, iter, body) -> {
      collectLambdasBfsExpr(iter, ticker, synths, deferred)
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SLoop(_, body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SScope(_, body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case SDefer(body) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
    }
    case STry(body, catches, finally_) -> {
      var si = 0
      while si < body.statements.count {
        collectLambdasBfsStmt(body.statements[si], ticker, synths, deferred)
        si = si + 1
      }
      var ci = 0
      while ci < catches.count {
        val cblk = catches[ci].body
        var csi = 0
        while csi < cblk.statements.count {
          collectLambdasBfsStmt(cblk.statements[csi], ticker, synths, deferred)
          csi = csi + 1
        }
        ci = ci + 1
      }
      match finally_ {
        case None -> {}
        case Some(fb) -> {
          var fsi = 0
          while fsi < fb.statements.count {
            collectLambdasBfsStmt(fb.statements[fsi], ticker, synths, deferred)
            fsi = fsi + 1
          }
        }
      }
    }
    case SInvariant(e)   -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
    case SRule(lhs, rhs) -> {
      collectLambdasBfsExpr(lhs, ticker, synths, deferred)
      collectLambdasBfsExpr(rhs, ticker, synths, deferred)
    }
    case _ -> {}
  }
}

// BFS-based liftLambdasMsil: extract all ELambda nodes into synthetic IFunc
// items in breadth-first order so lambda indices match the codegen traversal.
pub func liftLambdasMsil(file: in SourceFile): SourceFile {
  val ticker: List[Int] = newList()
  val synths: List[Item] = newList()
  val deferred: List[Block] = newList()

  // Phase 1: walk every top-level item's body, collecting direct lambdas.
  // Each ELambda body is pushed to `deferred` rather than recursed into.
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        match decl.body {
          case Some(body) -> {
            match body {
              case FBBlock(block) -> {
                var si = 0
                while si < block.statements.count {
                  collectLambdasBfsStmt(block.statements[si], ticker, synths, deferred)
                  si = si + 1
                }
              }
              case FBExpr(e) -> { collectLambdasBfsExpr(e, ticker, synths, deferred) }
            }
          }
          case None -> {}
        }
      }
      case IVal(decl)   -> { collectLambdasBfsExpr(decl.init, ticker, synths, deferred) }
      case IConst(decl) -> { collectLambdasBfsExpr(decl.init, ticker, synths, deferred) }
      case _ -> {}
    }
    i = i + 1
  }

  // Phase 2: BFS — process deferred lambda bodies in FIFO order.
  // New lambdas found inside lambda bodies are appended to `deferred` and
  // processed in subsequent iterations, ensuring outer lambdas are always
  // numbered before any lambdas nested inside their bodies.
  var di = 0
  while di < deferred.count {
    val blk = deferred[di]
    var si = 0
    while si < blk.statements.count {
      collectLambdasBfsStmt(blk.statements[si], ticker, synths, deferred)
      si = si + 1
    }
    di = di + 1
  }

  if synths.count == 0 {
    return file
  }

  // Build new items list: original items + synthetic lambdas.
  val newItems: List[Item] = newList()
  var j = 0
  while j < file.items.count {
    newItems.add(file.items[j])
    j = j + 1
  }
  var k = 0
  while k < synths.count {
    newItems.add(synths[k])
    k = k + 1
  }

  SourceFile(
    moduleDoc       = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl     = file.packageDecl,
    imports         = file.imports,
    items           = newItems,
    span            = file.span)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11c. Auto-FFI scoring — extern type method resolution (Band 2, R6).
// ─────────────────────────────────────────────────────────────────────────────
//
// When a call site matches `recv.method(args)` and `recv` is an EPath that
// resolves to a name in cctx.externTypeNames (populated from IExternType items),
// emit a direct CLR MemberRef callvirt rather than falling back to the generic
// stub.

// Populate cctx.externTypeNames from IExternType items in the file.
// Called from addPackageTokens before the IFunc pre-scan.
func scanExternTypesMsil(cctx: in CodegenCtx, file: in SourceFile): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IExternType(decl) -> {
        cctx.externTypeNames.add(decl.name, decl.clrName)
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// Emit an auto-FFI method call for an extern-type receiver.
// `recvName` is the Lyric name; `clrFqn` is the CLR fully-qualified type name.
// Returns the MsilType of the result (MObject for all calls in bootstrap).
func emitAutoFfiCallMsil(
  cctx:       in CodegenCtx,
  fctx:       in FuncCtx,
  insns:      in List[MInsn],
  recvExpr:   in Expr,
  methodName: in String,
  args:       in List[CallArg],
  clrFqn:     in String
): MsilType {
  val sp = splitTypeFqn(clrFqn)
  val asmName = clrAssemblyForType(clrFqn)
  val tRefRow = internFfiTypeRef(cctx, asmName, sp.ns, sp.name)

  // The receiver is always a type name (the EPath matched externTypeNames), so
  // this is a static call: no HASTHIS, no receiver load, emit `call` not `callvirt`.
  // Bootstrap-grade: registers sig as (object…) : void — works correctly for
  // void-returning static methods.  Methods with non-void returns require
  // explicit @externTarget annotations or --target dotnet-legacy.
  val argTypes: List[MsilType] = newList()
  var ai = 0
  while ai < args.count {
    argTypes.add(MObject)
    ai = ai + 1
  }
  val sig = buildStaticMethodSig(argTypes, MVoid)
  val mrRow = ctxAddMemberRef(cctx.lctx, tRefRow, methodName, "autoffi_" + methodName, sig)
  val tok = 0x0A000000 + mrRow

  // Load args only (no receiver — it's a type reference, not an instance).
  var bi = 0
  while bi < args.count {
    val aTy = lowerCallArgMsil(cctx, fctx, insns, args[bi])
    boxIfNeededMsil(cctx, insns, aTy)
    bi = bi + 1
  }
  insns.add(MCall(methodToken = tok))
  MVoid
}

// ─────────────────────────────────────────────────────────────────────────────
// §12. Package codegen — main entry point.
// ─────────────────────────────────────────────────────────────────────────────

// Determine whether a function is the program entry point.
func isMainFuncMsil(decl: in FunctionDecl): Bool {
  decl.name == "main" and decl.params.count == 0
}

// Resolve an `impl Iface for Target` block to its fully-qualified target and
// interface names.  Both names live in the current package today (cross-
// package resolution lands with the broader cross-assembly impl story), so
// the segments default to the local package prefix unless the iface is
// already multi-segment.
func implTargetNameMsil(decl: in ImplDecl, pkgName: in String): String {
  match decl.target.kind {
    case TRef(path) -> pkgName + "." + lastSegmentMsil(path)
    case _          -> pkgName + ".__impl_target"
  }
}

func implIfaceNameMsil(decl: in ImplDecl, pkgName: in String): String {
  val segs = decl.iface.head.segments
  if segs.count == 1 {
    pkgName + "." + segs[0]
  } else {
    joinSegsMsil(segs, ".")
  }
}

// Pre-pass: collect every IImpl block into `cctx.implEntries`.  Each impl
// method is lowered through `lowerImplMethodMsil` so it carries virtual
// instance-method flags and slot 0 = `this`; the methods are NOT added to
// any record yet — that injection happens in the IRecord arm of the main
// loop via `injectImplMethodsIntoRecord`.
pub func collectImplEntriesMsil(cctx: in CodegenCtx, file: in SourceFile,
                                 pkgName: in String): Unit {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IImpl(decl) -> {
        val targetName = implTargetNameMsil(decl, pkgName)
        val ifaceName  = implIfaceNameMsil(decl, pkgName)
        val methods: List[MFunc] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMplFunc(fn) -> methods.add(lowerImplMethodMsil(cctx, fn, pkgName, targetName))
            case IMplAssoc(_) -> {}
          }
          mi = mi + 1
        }
        cctx.implEntries.add(ImplEntryMsil(
          targetTypeName = targetName,
          ifaceTypeName  = ifaceName,
          methods        = methods))
      }
      case _ -> {}
    }
    i = i + 1
  }
}

// Append any pre-collected impl methods whose target matches `targetFqn` to
// the record's method list, producing a new `MRecord`.  The original record
// is left untouched.
pub func injectImplMethodsIntoRecord(cctx: in CodegenCtx, rec: in MRecord,
                                      targetFqn: in String): MRecord {
  val mergedMethods: List[MFunc] = newList()
  var bi = 0
  while bi < rec.methods.count {
    mergedMethods.add(rec.methods[bi])
    bi = bi + 1
  }
  var ei = 0
  while ei < cctx.implEntries.count {
    val implEntry = cctx.implEntries[ei]
    if implEntry.targetTypeName == targetFqn {
      var mi = 0
      while mi < implEntry.methods.count {
        mergedMethods.add(implEntry.methods[mi])
        mi = mi + 1
      }
    }
    ei = ei + 1
  }
  MRecord(
    className = rec.className,
    namespace = rec.namespace,
    baseClass = rec.baseClass,
    fields    = rec.fields,
    methods   = mergedMethods)
}

// Produce an `MPackage` from a parsed source file.
// The caller must subsequently call `lowerMPackageWithCtx(pkg, cctx.lctx, entryToken)`
// to emit the PE bytes.
pub func codegenMPackage(file: in SourceFile, cctx: in CodegenCtx): MPackage {
  val pkgSegs = file.packageDecl.path.segments
  val pkgName = joinSegsMsil(pkgSegs, ".")

  val fns:          List[MFunc]        = newList()
  val staticFields: List[MStaticField] = newList()
  val items:        List[MPackageItem] = newList()
  var hasMain = false

  // ── Band-2: aspect pre-pass ───────────────────────────────────────────────
  // Before lowering functions, run the aspect weaver to rename matched
  // functions and synthesise wrapper functions.  The weaver walks all IAspect
  // and IFunc items in the source file and returns a rewritten item list.
  val weavedFile = weaveAspectsMsil(file)

  // ── #878: IImpl pre-pass ──────────────────────────────────────────────────
  // Mirrors the JVM backend's approach (`Jvm.Codegen.codegenPackage`): scan
  // every IImpl block up-front, lower each impl method to an instance-method
  // MFunc, and stash the result on `cctx.implEntries`.  The main loop below
  // then (a) injects matching entries' methods into each IRecord's method
  // list — emitted as virtual instance methods by `lowerMRecord` — and (b)
  // queues an `MPImpl(MImplData)` item per entry, processed after all
  // TypeDefs are emitted so `lowerMImpl` can resolve TypeDef rows and
  // MethodDef tokens by name.
  collectImplEntriesMsil(cctx, weavedFile, pkgName)

  var i = 0
  while i < weavedFile.items.count {
    val item = weavedFile.items[i]
    match item.kind {
      case IRecord(decl) -> {
        val baseRec = lowerRecordMsil(decl, pkgName)
        val rec = injectImplMethodsIntoRecord(cctx, baseRec, pkgName + "." + decl.name)
        items.add(MPRecord(rec = rec))
      }
      case IExposedRec(decl) -> {
        val baseRec = lowerRecordMsil(decl, pkgName)
        val rec = injectImplMethodsIntoRecord(cctx, baseRec, pkgName + "." + decl.name)
        items.add(MPRecord(rec = rec))
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
      case IConst(decl) -> {
        // Module-level compile-time constant → static literal field on the host class.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, 0)
        val initInsns: List[MInsn] = newList()
        lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        // Fold the constant value from the first instruction (ldc.i4 for Int).
        val constVal = match initInsns.count {
          case n if n > 0 -> match initInsns[0] {
            case MLdcI4(v) -> v
            case _         -> 0
          }
          case _ -> 0
        }
        val sfield = MStaticField(
          flags      = FDA_PUBLIC + FDA_STATIC + FDA_LITERAL + FDA_HAS_DEFAULT,
          name       = decl.name,
          fieldType  = typeExprToMsil(decl.ty, pkgName),
          constValue = constVal,
          hasLiteral = true,
          initInsns  = newList())
        staticFields.add(sfield)
        // Register the inlined value so EPath references emit ldc.i4 directly.
        cctx.constValues.add(decl.name, constVal)
      }
      case IVal(decl) -> {
        // Module-level runtime value → static readonly field initialized in .cctor.
        val initFctx = makeFuncCtxMsil(pkgName, pkgName, 0)
        val initInsns: List[MInsn] = newList()
        val valTy = lowerExprMsil(cctx, initFctx, initInsns, decl.init)
        val fieldTy = match decl.ty {
          case Some(te) -> typeExprToMsil(te, pkgName)
          case None     -> valTy
        }
        val fieldName = match decl.pattern.kind {
          case PBinding(name, _) -> name
          case _                 -> "__val_" + toString(staticFields.count)
        }
        // When the init is a single ldc.i4 (literal Int), inline into constValues
        // and pass an empty initInsns to avoid generating a .cctor for this field.
        // All uses of the val in this package will emit ldc.i4 directly.
        var sfInitInsns = initInsns
        if initInsns.count == 1 {
          match initInsns[0] {
            case MLdcI4(v) -> {
              cctx.constValues.add(fieldName, v)
              sfInitInsns = newList()
            }
            case _ -> {}
          }
        }
        val sfield = MStaticField(
          flags      = FDA_PUBLIC + FDA_STATIC + FDA_INIT_ONLY,
          name       = fieldName,
          fieldType  = fieldTy,
          constValue = 0,
          hasLiteral = false,
          initInsns  = sfInitInsns)
        staticFields.add(sfield)
      }
      case IEnum(decl) -> {
        // Band-2 #849: CLR enum type.
        val caseNames: List[String] = newList()
        var ci = 0
        while ci < decl.cases.count {
          caseNames.add(decl.cases[ci].name)
          ci = ci + 1
        }
        items.add(MPEnum(e = MEnum(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          cases     = caseNames)))
      }
      case IInterface(decl) -> {
        // Band-2 #850: interface declaration.
        val ifaceMethods: List[MInterfaceMethod] = newList()
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case IMSig(sig) -> {
              val pTypes: List[MsilType] = newList()
              var pi = 0
              while pi < sig.params.count {
                pTypes.add(typeExprToMsil(sig.params[pi].ty, pkgName))
                pi = pi + 1
              }
              val retTy = match sig.ret {
                case Some(te) -> typeExprToMsil(te, pkgName)
                case None     -> MVoid
              }
              ifaceMethods.add(MInterfaceMethod(
                name   = sig.name,
                params = pTypes,
                ret    = retTy))
            }
            case IMFunc(fn) -> {
              // Default interface method — for now, emit as abstract signature.
              val pTypes: List[MsilType] = newList()
              var pi = 0
              while pi < fn.params.count {
                pTypes.add(typeExprToMsil(fn.params[pi].ty, pkgName))
                pi = pi + 1
              }
              val retTy = match fn.ret {
                case Some(te) -> typeExprToMsil(te, pkgName)
                case None     -> MVoid
              }
              ifaceMethods.add(MInterfaceMethod(
                name   = fn.name,
                params = pTypes,
                ret    = retTy))
            }
            case IMAssoc(_) -> {}
          }
          mi = mi + 1
        }
        items.add(MPInterface(iface = MInterface(
          className = pkgName + "." + decl.name,
          namespace = pkgName,
          methods   = ifaceMethods)))
      }
      case IImpl(_) -> {
        // Handled by the `collectImplEntriesMsil` pre-pass above; both the
        // record-method injection and the InterfaceImpl/MethodImpl emission
        // happen elsewhere in this function so the source-order arm is a
        // no-op (#878).
      }
      case IOpaque(decl) -> {
        // Band-2 #853: opaque type.
        if decl.hasBody {
          val oFields: List[MField] = newList()
          var fi = 0
          while fi < decl.members.count {
            match decl.members[fi] {
              case OMField(f) -> {
                oFields.add(MField(
                  flags     = FDA_PRIVATE,
                  name      = f.name,
                  fieldType = typeExprToMsil(f.ty, pkgName)))
              }
              case OMInvariant(_) -> {}
            }
            fi = fi + 1
          }
          val isProj = hasAnnotationMsil(decl.annotations, "projectable")
          items.add(MPOpaque(opaqueData = MOpaque(
            className     = pkgName + "." + decl.name,
            namespace     = pkgName,
            fields        = oFields,
            methods       = newList(),
            isProjectable = isProj)))
        }
      }
      case IProtected(decl) -> {
        // Band-2 #855: protected type — Monitor-based locking.
        lowerProtectedMsil(cctx, decl, pkgName, items, fns)
      }
      case IWire(decl) -> {
        // Band-2 #855: wire block — static DI factory class.
        lowerWireMsil(cctx, decl, pkgName, items, fns)
      }
      case IAspect(_)       -> {}  // consumed by weaveAspectsMsil above
      case ITypeAlias(_)    -> {}
      case IScopeKind(_)    -> {}
      case IExtern(_)       -> {}
      case IExternType(_)   -> {}
      case ITest(_)         -> {}
      case IProperty(_)     -> {}
      case IFixture(_)      -> {}
      case IConfig(_)       -> {}
      case IError           -> {}
    }
    i = i + 1
  }

  // Emit the host class: functions + static fields (IConst/IVal).
  if fns.count > 0 or staticFields.count > 0 {
    items.add(MPFuncs(hostClass = pkgName, funcs = fns, staticFields = staticFields))
  }

  // ── #878: MPImpl emission ─────────────────────────────────────────────────
  // After every record/interface/host-class TypeDef has been added to `items`,
  // queue one `MPImpl(MImplData)` per pre-pass entry so the lowering layer
  // emits the InterfaceImpl row after all TypeDefs are in the table.  The row
  // numbers are resolved by name in `lowerMImpl` (`findTypeDefRowByName`).
  var ie = 0
  while ie < cctx.implEntries.count {
    val implEntry = cctx.implEntries[ie]
    // `slots` is reserved for future aliased-implementation support (impl
    // methods whose name differs from the interface slot they satisfy).
    // Today, Lyric `impl` blocks always use the same name as the interface
    // method, so CLR name-matching wires them without explicit MethodImpl rows
    // and `lowerMImpl` does not iterate slots.
    val mslots: List[MImplSlot] = newList()
    var mi = 0
    while mi < implEntry.methods.count {
      val mname = implEntry.methods[mi].name
      mslots.add(MImplSlot(
        ifaceMethodToken = 0,
        implMethodToken  = 0,
        ifaceMethodName  = mname,
        implMethodName   = mname))
      mi = mi + 1
    }
    items.add(MPImpl(implData = MImplData(
      targetTypeDefRow = 0,
      ifaceTypeToken   = 0,
      slots            = mslots,
      targetTypeName   = implEntry.targetTypeName,
      ifaceTypeName    = implEntry.ifaceTypeName)))
    ie = ie + 1
  }

  MPackage(packageName = pkgName, items = items)
}
