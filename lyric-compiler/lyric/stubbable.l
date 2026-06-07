//! AST-level synthesis for `@stubbable` interfaces.
//!
//! Mirrors `bootstrap/src/Lyric.Parser/Stubbable.fs`.  A `@stubbable`
//! interface gets a sibling stub record + impl synthesised before the type
//! checker runs:
//!
//!   @stubbable
//!   pub interface Clock { func now(): Instant }
//!
//! becomes (additionally):
//!
//!   pub record ClockStub { pub now_value: Instant }
//!   impl Clock for ClockStub { func now(): Instant = self.now_value }
//!
//! so callers can construct the stub directly (`ClockStub(now_value = …)`) and
//! pass it where the interface is expected.  Generic interfaces, `Self`-bearing
//! and async methods are skipped (left in the interface untouched).
package Lyric.Stubbable

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

func isStubbable(a: in Annotation): Bool {
  a.name.segments.count > 0 and a.name.segments[0] == "stubbable"
}

func hasStubbable(it: in Item): Bool {
  var i = 0
  while i < it.annotations.count {
    if isStubbable(it.annotations[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// A `Self` mention anywhere in a method type makes it unsupported for the stub
// (a stub field/impl would need the concrete type, which isn't known here).
func mentionsSelf(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TGenericApp(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case TAType(t) -> if mentionsSelf(t) { return true }
          case TAValue(_) -> {
          }
        }
        i = i + 1
      }
      false
    }
    case TArray(_, elem) -> mentionsSelf(elem)
    case TSlice(elem) -> mentionsSelf(elem)
    case TTuple(ts) -> {
      var i = 0
      while i < ts.count {
        if mentionsSelf(ts[i]) {
          return true
        }
        i = i + 1
      }
      false
    }
    case TNullable(inner) -> mentionsSelf(inner)
    case TFunction(ps, r) -> {
      var i = 0
      while i < ps.count {
        if mentionsSelf(ps[i]) {
          return true
        }
        i = i + 1
      }
      mentionsSelf(r)
    }
    case TParen(inner) -> mentionsSelf(inner)
    case _ -> false
  }
}

func isStubbableMethodSig(sg: in FunctionSig): Bool {
  if sg.isAsync {
    return false
  }
  val returnOk = match sg.ret { case None -> true; case Some(te) -> not mentionsSelf(te) }
  if not returnOk {
    return false
  }
  var i = 0
  while i < sg.params.count {
    if mentionsSelf(sg.params[i].ty) {
      return false
    }
    i = i + 1
  }
  true
}

func isUnitReturn(sg: in FunctionSig): Bool {
  match sg.ret {
    case None -> true
    case Some(te) -> match te.kind {
      // TUnit is the canonical parser form for the `Unit` built-in.
      case TUnit -> true
      // TRef("Unit") covers a narrow edge: if a parser context emits the
      // built-in as a path reference rather than the dedicated TUnit token
      // (e.g. a type annotation `Unit` in certain parse positions).  The
      // single-segment guard prevents a user-defined type also named "Unit"
      // in a nested module from matching; the stdlib built-in has no namespace
      // prefix so only the bare name is expected here.
      case TRef(p) -> p.segments.count == 1 and p.segments[0] == "Unit"
      case _ -> false
    }
  }
}

func mkPath(name: in String, span: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = span)
}

func valueFieldName(methodName: in String): String {
  methodName + "_value"
}

// Append the `pub <method>_value: <ReturnType>` field for one supported,
// non-Unit method (no-op for Unit / unsupported methods).
func appendStubField(fields: in List[RecordMember], sg: in FunctionSig): Unit {
  if not isStubbableMethodSig(sg) {
    return
  }
  if isUnitReturn(sg) {
    return
  }
  val returnTy = match sg.ret { case Some(te) -> te; case None -> TypeExpr(kind = TUnit, span = sg.span) }
  val noDoc: List[DocComment] = newList()
  val noAnn: List[Annotation] = newList()
  fields.add(
    RMField(
      field = FieldDecl(
        docComments = noDoc,
        annotations = noAnn,
        visibility = Some(value = VisPub(span = sg.span)),
        isMutable = false,
        name = valueFieldName(sg.name),
        ty = returnTy,
        dflt = None,
        span = sg.span
      )
    )
  )
}

// The stub method body: `self.<method>_value` for a value-returning method, or
// an empty block for a Unit-returning one.
func stubMethodBody(sg: in FunctionSig): FunctionBody {
  if isUnitReturn(sg) {
    val noStmts: List[Statement] = newList()
    return FBBlock(block = Block(statements = noStmts, span = sg.span))
  }
  val selfE = Expr(kind = ESelf, span = sg.span)
  val mem = Expr(kind = EMember(receiver = selfE, memberName = valueFieldName(sg.name)), span = sg.span)
  FBExpr(expr = mem)
}

// Append the impl method for one supported interface method (no-op otherwise).
func appendStubMethod(methods: in List[ImplMember], sg: in FunctionSig): Unit {
  if not isStubbableMethodSig(sg) {
    return
  }
  val noDoc: List[DocComment] = newList()
  val noAnn: List[Annotation] = newList()
  val noContracts: List[ContractClause] = newList()
  methods.add(
    IMplFunc(
      fn = FunctionDecl(
        docComments = noDoc,
        annotations = noAnn,
        visibility = None,
        isAsync = sg.isAsync,
        name = sg.name,
        generics = sg.generics,
        params = sg.params,
        ret = sg.ret,
        whereClause = sg.whereClause,
        contracts = noContracts,
        body = Some(value = stubMethodBody(sg)),
        span = sg.span
      )
    )
  )
}

// One `pub <method>_value` field per non-Unit supported method.
func synthesiseStubRecord(id: in InterfaceDecl): RecordDecl {
  val fields: List[RecordMember] = newList()
  var i = 0
  while i < id.members.count {
    match id.members[i] {
      case IMSig(sg) -> appendStubField(fields, sg)
      case _ -> {
      }
    }
    i = i + 1
  }
  RecordDecl(name = id.name + "Stub", generics = None, whereClause = None, members = fields, span = id.span)
}

// `impl <Iface> for <Iface>Stub` — each supported method returns its
// `<method>_value` field (Unit methods get an empty body).
func synthesiseStubImpl(id: in InterfaceDecl): ImplDecl {
  val methods: List[ImplMember] = newList()
  var i = 0
  while i < id.members.count {
    match id.members[i] {
      case IMSig(sg) -> appendStubMethod(methods, sg)
      case _ -> {
      }
    }
    i = i + 1
  }
  val noArgs: List[TypeArg] = newList()
  ImplDecl(
    generics = None,
    iface = ConstraintRef(head = mkPath(id.name, id.span), args = noArgs, span = id.span),
    target = TypeExpr(kind = TRef(path = mkPath(id.name + "Stub", id.span)), span = id.span),
    whereClause = None,
    members = methods,
    span = id.span
  )
}

// Append the synthesised stub record + impl for one `@stubbable` interface item
// (no-op for plain or generic interfaces).
func appendStubsForInterface(result: in List[Item], it: in Item, id: in InterfaceDecl): Unit {
  if not hasStubbable(it) {
    return
  }
  // Generic interfaces are skipped (bootstrap scope): they need generic stubs.
  val isGeneric = match id.generics { case Some(_) -> true; case None -> false }
  if isGeneric {
    return
  }
  val recDoc: List[DocComment] = newList()
  val recAnn: List[Annotation] = newList()
  result.add(
    Item(
      docComments = recDoc,
      annotations = recAnn,
      visibility = Some(value = VisPub(span = id.span)),
      kind = IRecord(decl = synthesiseStubRecord(id)),
      span = id.span
    )
  )
  val impDoc: List[DocComment] = newList()
  val impAnn: List[Annotation] = newList()
  result.add(
    Item(
      docComments = impDoc,
      annotations = impAnn,
      visibility = None,
      kind = IImpl(decl = synthesiseStubImpl(id)),
      span = id.span
    )
  )
}

// Append a synthesised stub record + impl for every non-generic `@stubbable`
// interface; the original interface item is kept unchanged.
pub func synthesiseItems(items: in List[Item]): List[Item] {
  val result: List[Item] = newList()
  var c = 0
  while c < items.count {
    result.add(items[c])
    c = c + 1
  }
  var j = 0
  while j < items.count {
    match items[j].kind {
      case IInterface(id) -> appendStubsForInterface(result, items[j], id)
      case _ -> {
      }
    }
    j = j + 1
  }
  result
}

// Return `file` with the synthesised `@stubbable` items appended.
pub func stubbableRewriteFile(file: in SourceFile): SourceFile {
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = synthesiseItems(file.items),
    span = file.span
  )
}
