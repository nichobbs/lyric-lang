//! verifier/vcgen_register.l — registering the declarations of a file (callees, overloads, datatypes).
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// Register each non-generic type alias whose right-hand side is a scalar —
// a primitive, an inline range (`alias Pct = Int range 0 ..= 100`), a
// distinct or range subtype, or another such alias — under its name, so a
// value declared with the alias has the sort, width and range of what it
// names: a quantifier over `alias S = Small` ranges over `Small` (#8214).
// An alias of `Result`, `Option` or a nullable type is registered too (#8168).
// An alias of a record, union or other named type is left as it was: its
// name is not a distinct type's, which `S(x)` would otherwise construct.
func registerScalarAliases(file: in SourceFile, distinctMap: in Map[String, TypeExpr]): Unit {
  var changed = true
  var pass = 0
  while changed and pass < 16 {
    changed = false
    var i = 0
    while i < file.items.count {
      match file.items[i].kind {
        case ITypeAlias(ad) -> {
          val isGeneric = match ad.generics { case Some(_) -> true; case None -> false }
          if not isGeneric and not distinctMap.containsKey(ad.name) and aliasNamesScalar(distinctMap, ad.rhs) {
            distinctMap.add(ad.name, ad.rhs)
            changed = true
          }
        }
        case _ -> ()
      }
      i = i + 1
    }
    pass = pass + 1
  }
}

func aliasNamesScalar(distinctMap: in Map[String, TypeExpr], te: in TypeExpr): Bool {
  match te.kind {
    case TRefined(_, _) -> true
    // An alias of the standard library's `Result`, `Option` or a nullable
    // type has that datatype's sort: it is resolved before the sort is
    // chosen (#8168).  A user's own `Result`/`Option` is renamed apart
    // later (`unshadowMonadSort`), so it never reaches `Lyric!Result`.
    case TGenericApp(head, targs) -> head.segments.count == 1 and
      (
        head.segments[0] == "Result" and targs.count == 2 or
          head.segments[0] == "Option" and targs.count == 1
      )
    case TNullable(_) -> true
    case TRef(path) -> {
      if path.segments.count == 1 {
        val name = path.segments[0]
        isSome(primitiveSort(name)) or distinctMap.containsKey(name)
      } else {
        false
      }
    }
    case _ -> false
  }
}

// What a distinct type stands for in a proof: its underlying type, refined
// by its range when it is a range subtype (`type Port = UInt range 1 ..=
// 65535` is `UInt range 1 ..= 65535`), so a value of it carries the bound
// and a construction must establish it (#7872).
func distinctRepresentation(dt: in DistinctTypeDecl): TypeExpr {
  match dt.rangeClause {
    case Some(rb) -> match dt.underlying.kind {
      case TRef(path) -> TypeExpr(
        kind = TRefined(underlying = path, range = rb),
        span = dt.underlying.span
      )
      case _ -> dt.underlying
    }
    case None -> dt.underlying
  }
}

// Register one field of a record or protected type's datatype under its
// selector name, with its sort info: its signed width when it is an `Int` or
// `Long` (#7871), its range when it is a range subtype (#7872).
func addDatatypeField(
  dtFields: in List[DatatypeField],
  infos: in Map[String, SortInfo],
  distinctMap: in Map[String, TypeExpr],
  selector: in String,
  ty: in TypeExpr,
): Unit {
  val info = sortOfTypeExprWith(distinctMap, ty)
  dtFields.add(DatatypeField(name = selector, sort = info.sort))
  if not infos.containsKey(selector) {
    infos.add(selector, info)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Names declared more than once (#8341).
// ─────────────────────────────────────────────────────────────────────────────
// Register the file's functions in `callees` (and their declarations in
// `decls`); return the indices of the items that are not proved.  Names are
// counted over the whole package — this file's functions and
// `siblingFunctions`, the other files' — since the build merges them and
// the type checker resolves a call among all of them (#8341).
//
// A name the package declares once is reachable by its name and as
// `P.name`.  Functions of one name and different arities — overloads,
// which the language admits — are reachable only through
// `overloadCalleeKey`, each the declaration of its arity in this file: a
// call reaches the one taking exactly its argument count
// (`resolveOverloadedCallee`), and a call whose declaration of that arity
// is in another file, or that reaches one only by filling defaults, is not
// resolved and fails closed.  Each overload this file declares is proved.
// Two declarations of one name and arity in the package are a duplicate
// the type checker rejects (T0001), which reaches the verifier only when
// nothing type checked the program first (the language server): which one a
// call reaches is not known, so this file's are neither reachable nor
// proved, and each is reported.
func registerFileFunctions(
  file: in SourceFile,
  siblingFunctions: in List[FunctionArity],
  packagePrefix: in String,
  callees: in Map[String, FunctionDecl],
  decls: in List[FunctionDecl],
  diags: in List[Diagnostic],
): List[Int] {
  val unproved: List[Int] = newList()
  // How many functions the package declares of each name, and of each name
  // and arity.
  val byName: Map[String, Int] = newMap()
  val byArity: Map[String, Int] = newMap()
  for item in file.items {
    match item.kind {
      case IFunc(fn) -> {
        bumpCount(byName, fn.name)
        bumpCount(byArity, overloadCalleeKey(fn.name, fn.params.count))
      }
      case _ -> ()
    }
  }
  for sf in siblingFunctions {
    bumpCount(byName, sf.name)
    bumpCount(byArity, overloadCalleeKey(sf.name, sf.paramCount))
  }
  // Any declaration of the file stands for the siblings' in the callee table,
  // whose parameters are not known, only their count.
  var anyDecl: Option[FunctionDecl] = None
  for item in file.items {
    match item.kind {
      case IFunc(fn) -> match anyDecl { case None -> { anyDecl = Some(value = fn) }; case Some(_) -> () }
      case _ -> ()
    }
  }
  match anyDecl {
    case Some(stand) -> {
      for sf in siblingFunctions {
        if countOf(byName, sf.name) > 1 {
          addCalleeIfAbsent(callees, siblingOverloadKey(sf.name, sf.paramCount), stand)
          addCalleeIfAbsent(callees, siblingOverloadKey(packagePrefix + sf.name, sf.paramCount), stand)
        }
      }
    }
    case None -> ()
  }
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        decls.add(fn)
        val arityKey = overloadCalleeKey(fn.name, fn.params.count)
        if countOf(byName, fn.name) > 1 {
          addCalleeIfAbsent(callees, overloadedMarkerKey(fn.name), fn)
          addCalleeIfAbsent(callees, overloadedMarkerKey(packagePrefix + fn.name), fn)
        }
        if countOf(byArity, arityKey) > 1 {
          addCalleeIfAbsent(callees, siblingOverloadKey(fn.name, fn.params.count), fn)
          addCalleeIfAbsent(callees, siblingOverloadKey(packagePrefix + fn.name, fn.params.count), fn)
          unproved.add(i)
          diags.add(
            untranslatableDiag(
              "'" + fn.name + "' is declared more than once in its package with " + toString(fn.params.count) +
                " parameter(s) (T0001); no declaration of it is proved, and no call reaching one is translated",
              fn.span
            )
          )
        } else if countOf(byName, fn.name) > 1 {
          addCalleeIfAbsent(callees, arityKey, fn)
          addCalleeIfAbsent(callees, overloadCalleeKey(packagePrefix + fn.name, fn.params.count), fn)
          addOverloadDecl(callees, fn.name, fn)
          addOverloadDecl(callees, packagePrefix + fn.name, fn)
        } else {
          addCalleeIfAbsent(callees, fn.name, fn)
          addCalleeIfAbsent(callees, packagePrefix + fn.name, fn)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  unproved
}

func addCalleeIfAbsent(callees: in Map[String, FunctionDecl], key: in String, fn: in FunctionDecl): Unit {
  if not callees.containsKey(key) {
    callees.add(key, fn)
  }
}

func bumpCount(m: in Map[String, Int], key: in String): Unit {
  val n = countOf(m, key)
  if m.containsKey(key) {
    val _ = m.remove(key)
  }
  m.add(key, n + 1)
}

func countOf(m: in Map[String, Int], key: in String): Int {
  match mapGet(m, key) {
    case Some(n) -> n
    case None -> 0
  }
}

// The callee-table key of the overload of `name` taking `arity` arguments.
// `/` never occurs in a name.
func overloadCalleeKey(name: in String, arity: in Int): String {
  name + "/" + toString(arity)
}

// The callee-table key of the method `method` declared in the body of record
// `record`, which a `recv.method(...)` call reaches before any dot-named
// function (#8356).
func recordMethodCalleeKey(record: in String, method: in String): String {
  "!method/" + record + "::" + method
}

// The callee-table key present when `name` names functions of more than
// one declaration (#8341).
func overloadedMarkerKey(name: in String): String {
  "!overloaded/" + name
}

/// Whether `name` names more than one function of its package (this file's or another's), which a
/// call by that name alone cannot pick (`resolveOverloadedCallee`).
pub func calleeIsOverloaded(env: in VEnv, name: in String): Bool {
  env.callees.containsKey(overloadedMarkerKey(name))
}

// The callee-table key of the `index`th overload of `name` this file declares.
func overloadDeclKey(name: in String, index: in Int): String {
  "~overload/" + name + "/" + toString(index)
}

// The callee-table key present when the package declares a function of
// `name` taking `arity` parameters that the verifier cannot read as a
// candidate: another file's, or one of a duplicate (#8341).
func siblingOverloadKey(name: in String, arity: in Int): String {
  "~sibling/" + name + "/" + toString(arity)
}

func addOverloadDecl(callees: in Map[String, FunctionDecl], name: in String, fn: in FunctionDecl): Unit {
  var k = 0
  while callees.containsKey(overloadDeclKey(name, k)) {
    k = k + 1
  }
  callees.add(overloadDeclKey(name, k), fn)
}

// The function a call of the overloaded `name` with `args` reaches: the one
// declaration of this file that the call fits (`callDefaultsFilled`: each
// parameter it leaves out has a default, each named argument names one).
// The type checker binds a call to one of the declarations it fits by the
// rule of D210 (a call supplying every parameter first, then the fewest
// defaults filled), but only after the argument types have ruled some out,
// which the verifier cannot see: a call that fits several, or that fits one
// but may fit a declaration the verifier cannot read (another file's, a
// duplicate's, of a parameter count the call fits), is not resolved.
func resolveOverloadedCallee(env: in VEnv, name: in String, args: in List[CallArg]): Option[FunctionDecl] {
  var found: Option[FunctionDecl] = None
  var fits = 0
  var k = 0
  while env.callees.containsKey(overloadDeclKey(name, k)) {
    match mapGet(env.callees, overloadDeclKey(name, k)) {
      case Some(decl) -> {
        val names: List[String] = newList()
        val defaults: List[Bool] = newList()
        for p in decl.params {
          names.add(p.name)
          defaults.add(isSome(p.dflt))
        }
        if callDefaultsFilled(names, defaults, 0, args) >= 0 {
          fits = fits + 1
          found = Some(value = decl)
        }
      }
      case None -> ()
    }
    k = k + 1
  }
  var n = args.count
  while n <= args.count + 64 {
    if env.callees.containsKey(siblingOverloadKey(name, n)) {
      return None
    }
    n = n + 1
  }
  if fits == 1 {
    found
  } else {
    None
  }
}

// The function of this file a call of `name` with `args` reaches: the one
// declaration of that name, or the overload taking that many arguments.
func fileCallee(env: in VEnv, name: in String, args: in List[CallArg]): Option[FunctionDecl] {
  match mapGet(env.callees, name) {
    case Some(decl) -> Some(value = decl)
    case None -> if calleeIsOverloaded(env, name) { resolveOverloadedCallee(env, name, args) } else { None }
  }
}

// Register a protected type's member under `key`; two members of one key
// (one protected type's functions or entries of one name) are reachable by
// neither.  No call reaches a member through this table (a call to one
// fails closed), so the ambiguity needs no report.
func addMemberCallee(callees: in Map[String, FunctionDecl], key: in String, fn: in FunctionDecl): Unit {
  val marker = overloadedMarkerKey(key)
  if callees.containsKey(marker) {
    return ()
  }
  if callees.containsKey(key) {
    val _ = callees.remove(key)
    callees.add(marker, fn)
  } else {
    callees.add(key, fn)
  }
}

// A type name the file declares twice, at its second declaration.
record DuplicateType {
  name: String
  span: Span
}

func duplicateTypeDeclaration(file: in SourceFile): Option[DuplicateType] {
  val seen: Map[String, Bool] = newMap()
  for item in file.items {
    val declared = match item.kind {
      case ITypeAlias(d) -> d.name
      case IDistinctType(d) -> d.name
      case IRecord(d) -> d.name
      case IExposedRec(d) -> d.name
      case IUnion(d) -> d.name
      case IEnum(d) -> d.name
      case IOpaque(d) -> d.name
      case IProtected(d) -> d.name
      case IInterface(d) -> d.name
      case _ -> ""
    }
    if declared.length > 0 {
      if seen.containsKey(declared) {
        return Some(value = DuplicateType(name = declared, span = item.span))
      }
      seen.add(declared, true)
    }
  }
  None
}

// A field of a generic record (#8340): its sort read with the record's type
// parameters in scope, each then named by the datatype's sort parameter for
// it (`sortParamSorts`, in `typeParams` order).  A field whose type is not
// generic is registered as `addDatatypeField` registers it.
func addGenericDatatypeField(
  dtFields: in List[DatatypeField],
  infos: in Map[String, SortInfo],
  distinctMap: in Map[String, TypeExpr],
  selector: in String,
  ty: in TypeExpr,
  typeParams: in List[String],
  sortParamSorts: in List[Sort],
): Unit {
  if typeParams.count == 0 {
    addDatatypeField(dtFields, infos, distinctMap, selector, ty)
    return ()
  }
  val raw = sortOfTypeExprIn(distinctMap, typeParams, ty)
  val info = SortInfo(
    sort = substSortParams(raw.sort, typeParams, sortParamSorts),
    range = raw.range,
    intBits = raw.intBits
  )
  dtFields.add(DatatypeField(name = selector, sort = info.sort))
  if not infos.containsKey(selector) {
    infos.add(selector, info)
  }
}

// The key under which `fieldInfos` records the declared result sort of the
// method `method` of the record `record`, in terms of the record's sort
// parameters (#8356).  `!` keeps it apart from every field selector.
func recordMethodResultKey(record: in String, method: in String): String {
  record + "." + method + "!result"
}

// Record the result sort of each method of `rd` that declares one, read with
// the record's type parameters in scope and named by the datatype's sort
// parameters as a field's is, so a call on a value of the record sort
// `Box[Int]` instantiates it there (`instantiateRecordSort`).  A method with
// type parameters of its own, one whose result names `Self`, and a name
// declared twice with different result sorts are left out: such a call keeps
// the sort of an unmodelled value.
func addRecordMethodResults(
  rd: in RecordDecl,
  typeParams: in List[String],
  sortParamSorts: in List[Sort],
  infos: in Map[String, SortInfo],
  distinctMap: in Map[String, TypeExpr],
): Unit {
  for m in rd.members {
    match m {
      case RMFunc(fn) -> {
        val key = recordMethodResultKey(rd.name, fn.name)
        val own = genericTypeParamNames(fn.generics)
        var info = SortInfo(sort = SUninterp(name = "call"), range = RBKNone)
        match fn.ret {
          case Some(te) -> {
            if own.count == 0 and not typeNamesSelf(te) {
              val raw = sortOfTypeExprIn(distinctMap, typeParams, te)
              info = SortInfo(
                sort = substSortParams(raw.sort, typeParams, sortParamSorts),
                range = raw.range,
                intBits = raw.intBits
              )
            }
          }
          case None -> ()
        }
        if infos.containsKey(key) {
          match mapGet(infos, key) {
            case Some(prev) -> {
              if smtRenderSort(prev.sort) != smtRenderSort(info.sort) {
                infos.add(key, SortInfo(sort = SUninterp(name = "call"), range = RBKNone))
              }
            }
            case None -> ()
          }
        } else {
          infos.add(key, info)
        }
      }
      case _ -> ()
    }
  }
}

// Whether the type expression `te` mentions `Self`, or is of a kind the
// result sorts above do not read.
func typeNamesSelf(te: in TypeExpr): Bool {
  match te.kind {
    case TSelf -> true
    case TError -> true
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == "Self"
    case TGenericApp(head, targs) -> {
      if head.segments.count == 1 and head.segments[0] == "Self" {
        return true
      }
      for ta in targs {
        match ta {
          case TAType(inner) -> {
            if typeNamesSelf(inner) {
              return true
            }
          }
          case _ -> ()
        }
      }
      false
    }
    case TArray(_, element) -> typeNamesSelf(element)
    case TSlice(element) -> typeNamesSelf(element)
    case TTuple(types) -> {
      for t in types {
        if typeNamesSelf(t) {
          return true
        }
      }
      false
    }
    case TNullable(inner) -> typeNamesSelf(inner)
    case TParen(inner) -> typeNamesSelf(inner)
    case _ -> false
  }
}

// Whether a field of the generic record `rd` has a sort that names `rd`.
func recordFieldsNameRecord(rd: in RecordDecl, typeParams: in List[String], distinctMap: in Map[String, TypeExpr]): Bool {
  for m in rd.members {
    match m {
      case RMField(fld) -> {
        if sortNamesDatatype(sortOfTypeExprIn(distinctMap, typeParams, fld.ty).sort, rd.name) {
          return true
        }
      }
      case _ -> ()
    }
  }
  false
}

func sortNamesDatatype(s: in Sort, name: in String): Bool {
  match s {
    case SDatatype(n, args) -> {
      if n == name {
        return true
      }
      for a in args {
        if sortNamesDatatype(a, name) {
          return true
        }
      }
      false
    }
    case SSlice(e) -> sortNamesDatatype(e, name)
    case SArray(e) -> sortNamesDatatype(e, name)
    case _ -> false
  }
}

// The names of the type parameters of `generics` (not its value
// parameters).
func genericTypeParamNames(generics: in Option[GenericParams]): List[String] {
  val names: List[String] = newList()
  match generics {
    case Some(gp) -> {
      for g in gp.params {
        match g {
          case GPType(n, _) -> names.add(n)
          case _ -> ()
        }
      }
    }
    case None -> ()
  }
  names
}

// The contracts and `@pure` bodies of the public functions of the packages
// `file` imports, so a call to one (`Std.String.isEmpty(s)`) is that function
// applied to its arguments, with its facts, rather than a value of a sort the
// verifier does not know (#7532).  `Std.Core` is left to the monad models.
// A function is reachable by its package-qualified name, by its alias-
// qualified name when the import is renamed, and by its bare name when
// nothing else in scope, own or imported, has that name.
func registerImportedFunctions(
  file: in SourceFile,
  imports: in ImportScope,
  siblingFunctions: in List[FunctionArity],
  callees: in Map[String, FunctionDecl],
): Unit {
  val bare: Map[String, Int] = newMap()
  for item in file.items {
    match item.kind {
      case IFunc(fn) -> bumpCount(bare, fn.name)
      case _ -> ()
    }
  }
  for sf in siblingFunctions {
    bumpCount(bare, sf.name)
  }
  val imported: List[ResolvedPackage] = newList()
  for imp in file.imports {
    if imp.isExtern {
      continue
    }
    val pkgName = joinPathSegments(imp.path.segments)
    if pkgName == "Std.Core" {
      continue
    }
    for rp in imports.packages {
      if rp.name == pkgName {
        imported.add(rp)
        for fn in rp.decls.callees {
          addCalleeIfAbsent(callees, pkgName + "." + fn.name, fn)
          match imp.asAlias {
            case Some(alias) -> addCalleeIfAbsent(callees, alias + "." + fn.name, fn)
            case None -> ()
          }
          bumpCount(bare, fn.name)
        }
      }
    }
  }
  for rp in imported {
    for fn in rp.decls.callees {
      if countOf(bare, fn.name) == 1 {
        addCalleeIfAbsent(callees, fn.name, fn)
      }
    }
  }
}
