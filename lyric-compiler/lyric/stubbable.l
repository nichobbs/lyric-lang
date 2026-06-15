//! AST-level synthesis for `@stubbable` interfaces.
//!
//! A `@stubbable` interface gets a sibling stub record + impl synthesised
//! before the type checker runs.  For each non-Unit method a `_value` field
//! is added; for every supported method (including Unit) a `_counter` field
//! of type `StubCounter` is added with a `makeStubCounter()` default.  The
//! synthesised impl increments the counter on entry before returning the value.
//! `import Std.Testing.Mocking` is injected automatically when any stub is
//! synthesised so `StubCounter` and `makeStubCounter()` are in scope.
//!
//!   @stubbable
//!   pub interface Clock { func now(): Instant }
//!
//! becomes (additionally):
//!
//!   pub record ClockStub {
//!     pub now_value: Instant
//!     pub now_counter: StubCounter = makeStubCounter()
//!   }
//!   impl Clock for ClockStub {
//!     func now(): Instant {
//!       stubCounterIncrement(self.now_counter)
//!       return self.now_value
//!     }
//!   }
//!
//! Generic interfaces, `Self`-bearing and async methods are skipped.
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

func counterFieldName(methodName: in String): String {
  methodName + "_counter"
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

// Append the `pub <method>_counter: StubCounter = makeStubCounter()` field for
// every supported method, including Unit-returning ones.  Callers read the
// counter after exercising the stub to assert the expected call count.
func appendCounterField(fields: in List[RecordMember], sg: in FunctionSig): Unit {
  if not isStubbableMethodSig(sg) {
    return
  }
  val noDoc: List[DocComment] = newList()
  val noAnn: List[Annotation] = newList()
  val counterTy = TypeExpr(kind = TRef(path = mkPath("StubCounter", sg.span)), span = sg.span)
  val calleePath = Expr(kind = EPath(path = mkPath("makeStubCounter", sg.span)), span = sg.span)
  val noArgs: List[CallArg] = newList()
  val defaultExpr = Expr(kind = ECall(fn = calleePath, args = noArgs), span = sg.span)
  fields.add(
    RMField(
      field = FieldDecl(
        docComments = noDoc,
        annotations = noAnn,
        visibility = Some(value = VisPub(span = sg.span)),
        isMutable = false,
        name = counterFieldName(sg.name),
        ty = counterTy,
        dflt = Some(value = defaultExpr),
        span = sg.span
      )
    )
  )
}

// The stub method body: always a block that first increments the call counter,
// then returns `self.<method>_value` for non-Unit methods.
func stubMethodBody(sg: in FunctionSig): FunctionBody {
  val stmts: List[Statement] = newList()
  val selfE = Expr(kind = ESelf, span = sg.span)
  val counterAcc = Expr(kind = EMember(receiver = selfE, memberName = counterFieldName(sg.name)), span = sg.span)
  val incrFn = Expr(kind = EPath(path = mkPath("stubCounterIncrement", sg.span)), span = sg.span)
  val incrArgs: List[CallArg] = newList()
  incrArgs.add(CAPositional(expr = counterAcc))
  val incrCall = Expr(kind = ECall(fn = incrFn, args = incrArgs), span = sg.span)
  stmts.add(Statement(kind = SExpr(expr = incrCall), span = sg.span))
  if not isUnitReturn(sg) {
    val valueAcc = Expr(kind = EMember(receiver = selfE, memberName = valueFieldName(sg.name)), span = sg.span)
    stmts.add(Statement(kind = SReturn(value = Some(value = valueAcc)), span = sg.span))
  }
  FBBlock(block = Block(statements = stmts, span = sg.span))
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

// One `pub <method>_value` field per non-Unit supported method, plus one
// `pub <method>_counter: StubCounter = makeStubCounter()` per supported method.
func synthesiseStubRecord(id: in InterfaceDecl): RecordDecl {
  val fields: List[RecordMember] = newList()
  var i = 0
  while i < id.members.count {
    match id.members[i] {
      case IMSig(sg) -> {
        appendStubField(fields, sg)
        appendCounterField(fields, sg)
      }
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

// Return true if the file already has `import Std.Testing.Mocking`.
func hasMockingImport(imports: in List[ImportDecl]): Bool {
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    if imp.path.segments.count == 3
      and imp.path.segments[0] == "Std"
      and imp.path.segments[1] == "Testing"
      and imp.path.segments[2] == "Mocking" {
      return true
    }
    i = i + 1
  }
  false
}

// Return a copy of `imports` with a synthetic `import Std.Testing.Mocking` appended.
func addMockingImport(imports: in List[ImportDecl], span: in Span): List[ImportDecl] {
  val result: List[ImportDecl] = newList()
  var i = 0
  while i < imports.count {
    result.add(imports[i])
    i = i + 1
  }
  val segs: List[String] = newList()
  segs.add("Std")
  segs.add("Testing")
  segs.add("Mocking")
  result.add(ImportDecl(
    path = ModulePath(segments = segs, span = span),
    selector = None,
    asAlias = None,
    isPubUse = false,
    isExtern = false,
    span = span
  ))
  result
}

// Return the import list to use for the rewritten file.  If stubs were
// synthesised and `Std.Testing.Mocking` is not yet imported, add it so
// `StubCounter` and `makeStubCounter()` resolve during type-check.
func buildImports(file: in SourceFile, stubsAdded: in Bool): List[ImportDecl] {
  if not stubsAdded {
    return file.imports
  }
  if hasMockingImport(file.imports) {
    return file.imports
  }
  addMockingImport(file.imports, file.span)
}

// Return `file` with the synthesised `@stubbable` items appended and, when
// stubs are present, `import Std.Testing.Mocking` ensured in the import list.
pub func stubbableRewriteFile(file: in SourceFile): SourceFile {
  val newItems = synthesiseItems(file.items)
  val stubsAdded = newItems.count > file.items.count
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = buildImports(file, stubsAdded),
    items = newItems,
    span = file.span
  )
}
