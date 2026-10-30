//! verifier/vcgen_file.l — goals for a file and its package scope.
//! Part of the Lyric.Verifier vcgen split (#8160); no behaviour of its own.
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.SelfFields as SelfFields

// #336: aspect weaving (Lyric.Weaver.weaveFile) now runs in the
// verifier driver before VC generation.  goalsForFile receives the
// woven SourceFile — original IFuncs are replaced with renamed
// `__aspect_target` declarations plus wrapper IFuncs carrying the
// composed contracts (§5 of docs/26-aspects.md).  IAspect items have
// already been dropped, so the verifier sees the body the runtime
// executes.  The V0031 same-package warning is therefore retired.
// With nothing known of the package's other files, a type named `Result`
// or `Option` may be declared there (#8108).
pub func goalsForFile(file: in SourceFile, level: in VerificationLevel): (List[Goal], List[Diagnostic]) {
  goalsForFileInScope(file, level, unknownPackageScope())
}

// `file` with the records and distinct types of `typeItems` added that it
// does not declare itself.
func withSiblingTypes(file: in SourceFile, typeItems: in List[Item]): SourceFile {
  if typeItems.count == 0 {
    return file
  }
  val declared: List[String] = newList()
  val items: List[Item] = newList()
  for it in file.items {
    items.add(it)
    match it.kind {
      case IRecord(d) -> declared.add(d.name)
      case IDistinctType(d) -> declared.add(d.name)
      case _ -> ()
    }
  }
  for it in typeItems {
    val name = match it.kind { case IRecord(d) -> d.name; case IDistinctType(d) -> d.name; case _ -> "" }
    if name.length > 0 and not declared.contains(name) {
      declared.add(name)
      items.add(it)
    }
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

// `scope.known` says `scope.typeNames` are all the top-level type names
// the package's other files declare; `scope.siblings` is what else they
// declare, and `scope.imports` the packages whose declarations the
// verifier can read (#8230, #8231).
pub func goalsForFileInScope(
  file: in SourceFile, level: in VerificationLevel, pscope: in PackageScope
): (List[Goal], List[Diagnostic]) {
  val siblingsKnown = pscope.known
  val siblingTypeNames = pscope.typeNames
  if not vlIsProofRequired(level) {
    val noGoals: List[Goal] = newList()
    val noDiags: List[Diagnostic] = newList()
    return (noGoals, noDiags)
  }
  // A type spelt like a primitive reaches the verifier as the primitive —
  // `record Unit { xs: List[Int] }` as `Unit`, a value — so nothing about
  // its values can be trusted: the file fails closed (#8109).  A type the
  // package's other files declare is in scope here too, and when they are
  // not all known any of them may be one (#8214).
  val shadowedPrimitive = shadowedPrimitiveName(file, siblingTypeNames)
  val shadowReason = if not siblingsKnown {
    "the package's other files, which are not all known and may declare a type named like a primitive"
  } else if shadowedPrimitive.length > 0 {
    "a type named `" + shadowedPrimitive + "`, which the verifier would take for the primitive of that name"
  } else {
    ""
  }
  if shadowReason.length > 0 {
    val noGoals: List[Goal] = newList()
    val shadowDiags: List[Diagnostic] = newList()
    shadowDiags.add(untranslatableDiag(shadowReason, file.packageDecl.path.span))
    return (noGoals, shadowDiags)
  }
  // A type declared twice — a file no type check has rejected yet (T0001)
  // — leaves every sort named by it ambiguous: nothing is proved (#8341).
  match duplicateTypeDeclaration(file) {
    case Some(dup) -> {
      val noGoals: List[Goal] = newList()
      val dupDiags: List[Diagnostic] = newList()
      dupDiags.add(
        untranslatableDiag(
          "a second declaration of the type `" + dup.name +
            "` (T0001), which leaves every value of that name ambiguous; nothing in this file is proved",
          dup.span
        )
      )
      return (noGoals, dupDiags)
    }
    case None -> ()
  }

  // Build callee table from file's IFunc and protected-type PMFunc items.
  // A function is reachable by its name and by its name qualified with
  // this file's package (`P.f`, #8102).  A name declared more than once is
  // never reachable by its name alone (`registerFileFunctions`, #8341).
  val callees: Map[String, FunctionDecl] = newMap()
  val calleeDecls: List[FunctionDecl] = newList()
  val packagePrefix = joinPathSegments(file.packageDecl.path.segments) + "."
  val calleeDiags: List[Diagnostic] = newList()
  val unprovedFuncs = registerFileFunctions(
    file,
    pscope.siblings.functions,
    packagePrefix,
    callees,
    calleeDecls,
    calleeDiags
  )
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IProtected(decl) -> {
        // #663: Hoare-call rule at a PMEntry call site reads
        // `callees.<entry>.contracts` to derive the post-state.
        // Verification combines invariants with ed.contracts, so the
        // callee stub must do the same; otherwise a caller can't
        // conclude the invariant after a cross-entry call.
        val protInvs: List[ContractClause] = collectProtectedInvariants(decl)
        var mi = 0
        while mi < decl.members.count {
          match decl.members[mi] {
            case PMFunc(fn) -> {
              addMemberCallee(callees, decl.name + "::" + fn.name, fn)
              calleeDecls.add(fn)
            }
            case PMEntry(ed) -> {
              val stubContracts: List[ContractClause] = newList()
              var pi = 0
              while pi < protInvs.count {
                stubContracts.add(protInvs[pi])
                pi = pi + 1
              }
              val edOwn = ed.contracts
              pi = 0
              while pi < edOwn.count {
                stubContracts.add(edOwn[pi])
                pi = pi + 1
              }
              val noDoc: List[DocComment] = newList()
              val noAnn: List[Annotation] = newList()
              val entryFn: FunctionDecl = FunctionDecl(
                docComments = noDoc,
                annotations = noAnn,
                visibility = ed.visibility,
                isAsync = false,
                name = decl.name + "::" + ed.name,
                generics = None,
                params = ed.params,
                ret = ed.ret,
                whereClause = None,
                contracts = stubContracts,
                body = Some(value = ed.body),
                span = ed.span
              )
              addMemberCallee(callees, decl.name + "::" + ed.name, entryFn)
              calleeDecls.add(entryFn)
            }
            case _ -> {
            }
          }
          mi = mi + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }

  val checkedArith = match level { case VLProofRequiredChecked -> true; case _ -> false }
  val sharedSymbols: List[SymbolDecl] = newList()

  // The records and distinct types the package's other files declare are in
  // scope here as well as this file's own (#8306).
  val modelFile = withSiblingTypes(file, pscope.siblings.typeItems)
  // Collect distinct-type aliases (`pub type Cents = Long`) so record /
  // protected field-sort lookups and the per-function `sortOfTypeExprE`
  // call sites resolve them to the underlying primitive (#3853).
  val distinctMap: Map[String, TypeExpr] = newMap()
  var dti0 = 0
  while dti0 < modelFile.items.count {
    match modelFile.items[dti0].kind {
      case IDistinctType(dtDecl) -> {
        if not distinctMap.containsKey(dtDecl.name) {
          distinctMap.add(dtDecl.name, distinctRepresentation(dtDecl))
        }
      }
      case _ -> ()
    }
    dti0 = dti0 + 1
  }
  registerScalarAliases(modelFile, distinctMap)

  var mi = 0
  while mi < 2 {
    val monadName = if mi == 0 { "Result" } else { "Option" }
    if monadNameShadowed(file, monadName) or not siblingsKnown or siblingTypeNames.contains(monadName) {
      distinctMap.add(shadowedMonadKey(monadName), TypeExpr(kind = TUnit, span = file.packageDecl.path.span))
    }
    mi = mi + 1
  }

  val fieldInfosMap: Map[String, SortInfo] = newMap()
  val recordDefaultsMap: Map[String, List[Option[Expr]]] = newMap()
  val recordNames: List[String] = newList()

  // Pre-register every `IRecord` as an SMT datatype with one constructor
  // matching the record's fields.  Lets the verifier reason about
  // `Amount(value = c)` constructors and `result.value` field reads against
  // a properly declared sort, instead of falling back to uninterpreted
  // names that z3 rejects as "unknown constant" (#3843).  A generic record
  // is one parametric datatype, a sort parameter per type parameter, as the
  // preamble's `Result`/`Option` are: `Box[Int]` and `Box[T]` are its
  // instances, and a field read on either has the field's sort at that
  // instance (#8340).
  var ri = 0
  while ri < modelFile.items.count {
    match modelFile.items[ri].kind {
      // Datatype field names share z3's name space with free constants
      // and parameters, so a free param named `capacity` would clash with
      // the selector `capacity` from a Bucket datatype declaration even
      // though their sorts differ (#3855).  Disambiguate selector names by
      // prefixing them with `<TypeName>__` — `Bucket__capacity` for a
      // Bucket-field reading.  EMember's record-field translation mirrors
      // this prefix when it emits the selector TApp.
      case IRecord(recDecl) -> {
        val recTypeParams = genericTypeParamNames(recDecl.generics)
        // A generic record named like the standard library's `Result` or
        // `Option` is taken for neither: its sorts are renamed apart from
        // the preamble's (`unshadowMonadSort`) and stay uninterpreted.
        val monadNamed = recTypeParams.count > 0 and (recDecl.name == "Result" or recDecl.name == "Option")
        // A generic record whose fields name the record itself (`next:
        // Option[Node[T]]`) would be a parametric datatype nested through
        // another, which the solver rejects as not well-founded: it stays
        // an uninterpreted sort, its field reads failing closed.
        val selfNested = recTypeParams.count > 0 and recordFieldsNameRecord(recDecl, recTypeParams, distinctMap)
        if not monadNamed and not selfNested {
          val sortParams: List[String] = newList()
          val sortParamSorts: List[Sort] = newList()
          for tp in recTypeParams {
            val sp = recordSortParamName(recDecl.name, tp)
            sortParams.add(sp)
            val noArgs: List[Sort] = newList()
            sortParamSorts.add(SDatatype(name = sp, args = noArgs))
          }
          val dtFields: List[DatatypeField] = newList()
          val dtDefaults: List[Option[Expr]] = newList()
          var fi = 0
          while fi < recDecl.members.count {
            match recDecl.members[fi] {
              case RMField(fld) -> {
                addGenericDatatypeField(
                  dtFields,
                  fieldInfosMap,
                  distinctMap,
                  recDecl.name + "__" + fld.name,
                  fld.ty,
                  recTypeParams,
                  sortParamSorts
                )
                dtDefaults.add(fld.dflt)
              }
              case _ -> ()
            }
            fi = fi + 1
          }
          val dtCtors: List[DatatypeCtor] = newList()
          dtCtors.add(DatatypeCtor(name = recDecl.name, fields = dtFields))
          sharedSymbols.add(DeclDatatype(name = recDecl.name, constructors = dtCtors, params = sortParams))
          if not recordDefaultsMap.containsKey(recDecl.name) {
            recordDefaultsMap.add(recDecl.name, dtDefaults)
            recordNames.add(recDecl.name)
          }
        }
      }
      // Same as IRecord above, but for protected types.  Lets
      // `make`'s `ensures: result.tokens == capacity` discharge against
      // the prefixed selector `Bucket__tokens`.
      case IProtected(pdecl) -> {
        val dtFields: List[DatatypeField] = newList()
        var pfi = 0
        while pfi < pdecl.members.count {
          match pdecl.members[pfi] {
            case PMField(pf) -> {
              match pf {
                case PFVar(fname, fty, _, _, _, _) -> addDatatypeField(
                  dtFields,
                  fieldInfosMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFLet(fname, fty, _, _, _, _) -> addDatatypeField(
                  dtFields,
                  fieldInfosMap,
                  distinctMap,
                  pdecl.name + "__" + fname,
                  fty
                )
                case PFImmutable(fd) -> addDatatypeField(dtFields, fieldInfosMap, distinctMap, pdecl.name + "__" + fd.name, fd.ty)
              }
            }
            case _ -> ()
          }
          pfi = pfi + 1
        }
        val dtCtors: List[DatatypeCtor] = newList()
        dtCtors.add(DatatypeCtor(name = pdecl.name, fields = dtFields))
        val noParams: List[String] = newList()
        sharedSymbols.add(DeclDatatype(name = pdecl.name, constructors = dtCtors, params = noParams))
      }
      case _ -> ()
    }
    ri = ri + 1
  }

  // A record's own methods, which a `recv.m(...)` call reaches before any
  // dot-named `func R.m` (#8101).
  val recordMethodsMap: Map[String, Bool] = newMap()
  var rmi = 0
  while rmi < modelFile.items.count {
    match modelFile.items[rmi].kind {
      case IRecord(rmDecl) -> {
        var rmj = 0
        while rmj < rmDecl.members.count {
          match rmDecl.members[rmj] {
            case RMFunc(rmFn) -> {
              val rmKey = rmDecl.name + "." + rmFn.name
              if not recordMethodsMap.containsKey(rmKey) {
                recordMethodsMap.add(rmKey, true)
              }
            }
            case _ -> ()
          }
          rmj = rmj + 1
        }
      }
      case _ -> ()
    }
    rmi = rmi + 1
  }

  // Build env0 carrying the distinct-type alias map collected above (#3853).
  val env0Init = envEmpty(callees, sharedSymbols, checkedArith)
  val cyclicNames = contractCycles(env0Init, calleeDecls, recordNames, recordDefaultsMap)
  // A module-level `val` or `const` with a declared type is a value of that
  // type; any other module-level name's type is unknown (#8109).
  var gi = 0
  while gi < file.items.count {
    match file.items[gi].kind {
      case IConst(cd) -> {
        if not distinctMap.containsKey(globalTypeKey(cd.name)) {
          distinctMap.add(globalTypeKey(cd.name), cd.ty)
        }
      }
      case IVal(vd) -> match vd.ty {
        case Some(vty) -> match simpleBindingName(vd.pattern) {
          case Some(vn) -> {
            if not distinctMap.containsKey(globalTypeKey(vn)) {
              distinctMap.add(globalTypeKey(vn), vty)
            }
          }
          case None -> ()
        }
        case None -> ()
      }
      case _ -> ()
    }
    gi = gi + 1
  }
  val valueTypesMap = fileValueTypes(modelFile, distinctMap)
  addScopeCaseFacts(file, pscope, valueTypesMap)
  val env0 = VEnv(
    vars = env0Init.vars,
    varNames = env0Init.varNames,
    sorts = env0Init.sorts,
    callees = env0Init.callees,
    symbols = env0Init.symbols,
    checkedArithmetic = env0Init.checkedArithmetic,
    distincts = distinctMap,
    fieldInfos = fieldInfosMap,
    recordDefaults = recordDefaultsMap,
    fresh = env0Init.fresh,
    recordMethods = recordMethodsMap,
    finals = env0Init.finals,
    mutables = env0Init.mutables,
    protectedMembers = env0Init.protectedMembers,
    contractStack = env0Init.contractStack,
    cyclic = cyclicNames,
    valueTypes = valueTypesMap,
    typeParams = env0Init.typeParams
  )

  val allGoals: List[Goal] = newList()
  val allDiags: List[Diagnostic] = newList()
  appendTermList2(allDiags, calleeDiags)

  i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(fn) -> {
        val fnLevel = levelOfFunction(level, fn)
        if vlIsProofRequired(fnLevel) and not unprovedFuncs.contains(i) {
          // #336: aspect weaving runs in driver.l before this point, so
          // the IFunc here is either an original function with no
          // matching aspect, an `__aspect_target` (the renamed inner
          // body), or a wrapper carrying the composed contracts.  All
          // three are verified the same way against their declared
          // contracts.
          val fnEnv = freshSymbolsEnv(env0)
          val (goals, diags) = goalsForFunction(fnEnv, fn)
          var gi = 0
          while gi < goals.count {
            allGoals.add(goals[gi])
            gi = gi + 1
          }
          appendTermList2(allDiags, diags)
        }
      }
      case IProtected(decl) -> {
        val invContracts: List[ContractClause] = collectProtectedInvariants(decl)
        goalsForProtectedMembers(level, env0, decl.name, decl.members, invContracts, allGoals, allDiags)
      }
      // Methods are verified like functions, the receiver `self` a
      // parameter and the type's parameters in scope (#8231).
      case IRecord(rd) -> goalsForRecordMethods(level, env0, rd.name, rd.generics, rd.members, allGoals, allDiags)
      case IExposedRec(rd) -> goalsForRecordMethods(level, env0, rd.name, rd.generics, rd.members, allGoals, allDiags)
      case IImpl(id) -> goalsForImplMethods(level, env0, file, pscope, id, allGoals, allDiags)
      case IInterface(iface) -> goalsForInterfaceDefaults(level, env0, iface, allGoals, allDiags)
      case _ -> {
      }
    }
    i = i + 1
  };

  (allGoals, dedupeDiagnostics(allDiags))
}
