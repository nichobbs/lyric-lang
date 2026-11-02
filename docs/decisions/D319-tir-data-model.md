# D319 - The `Lyric.Tir` data model: `Ty`, `TExpr` and the declaration records (docs/70 phase 3a, #8612)

**Status:** shipped (types only). The first step of docs/70 §13 phase 3a. The
verifier, `NodeId`s on the parser's nodes, the §5 type rules and the TIR
builder are later steps and have their own entries.

## Context

docs/70 §6.2 sketches the typed IR. Package interfaces (phase 5a) record
signatures with the same `Ty` and need it before the rest of 3a, so the model
lands on its own, with nothing in it that belongs to the checker.

## Decision

`Lyric.Tir` (`lyric-compiler/lyric/tir/`) holds data and pure functions on it.
It depends on `Lyric.Symbols` (declarations are `SymbolId`s) and `Lyric.Lexer`
(`Span`) and on nothing else of the compiler.

1. **`Ty`** has twelve cases: `TPrim`, `TTuple`, `TNullable`, `TFunc`,
   `TArray`, `TSlice`, `TNamed(sym, args)`, `TParam(owner, index)`, `TRefined`,
   `TLen`, `TNever`, `TException`, `TExtern(HostTypeRef)`. There is no error
   case and no inference case. `Never` is a type, not a scalar
   (`TPrimKind` has the twelve scalars).
   - `Self` inside an interface is `TParam(iface, selfParamIndex())` with index
     `-1`; elsewhere `Self` is already replaced. No `TSelf` case.
   - An array length is `ArrayLen`: `ALKnown`, `ALParam(owner, index)` for a
     value generic, or `ALUnsized`. A value generic argument is `TLen`.
   - Built-in types with no declaration (`Task[T]`, `buffer[T]`) are `TNamed`
     with the checker's reserved negative ids; `isBuiltinSymbol` names the
     test.
   - `TExtern` carries the host's own type name and arguments, so two extern
     declarations of one host type are one type (docs/70 §4.2).
2. **`tyEq` is structural and has no wildcard.** A parameter equals only the
   same parameter. A refinement equals only a refinement with the same bounds
   and inclusivity, and not its underlying type: the conversion is the explicit
   node `XConvert(CvUnrefine)` (or `CvRangeCheck` the other way). This differs
   from the checker's `typeEquiv`, which unwraps refinements, and is why the
   verifier can demand exact equality.
3. **`TExpr`** is `{ id: NodeId, ty: Ty, span, kind: TExprKind }`. Kinds as in
   §6.2, with these choices:
   - `XCall(callee, args)`: `Callee` is `Direct`, `Interface` (with the
     interface's own arguments), `Indirect`, `Extern(HostMemberRef)` or
     `Intrinsic(IntrinsicOp)`. An argument is `TArgIn(value)`,
     `TArgOut(place)` or `TArgInout(place)`.
   - `XConstruct(sym, fields)` lists fields in declaration order, defaults
     filled in. `XField` and patterns name a field by `FieldRef`.
   - `&&`, `||`, `implies` and `??` are `XShort`: they do not evaluate both
     sides, so they are not calls.
   - String interpolation is `XInterp(parts)` with every part a `String`.
   - `XBlock(stmts, tail)`; statements are `TStmt` (`TsLet`, `TsVar`,
     `TsReturn`, loops, `TsTry`, ...). Local items are lifted out by the
     builder and do not appear.
   - `ConvKind` has `CvWiden`, `CvWrapDistinct`, `CvUnwrapDistinct`,
     `CvRangeCheck`, `CvUnrefine`, `CvUpcast`, `CvBoxToHost`, `CvToSlice`,
     `CvToList`, `CvLiftNullable` and `CvFromNever`; the source type is the
     inner node's `ty`.
   - A closure lists its captures with `CmByValue` / `CmByRef`.
   - Patterns are `TPat { id, ty, span, kind }` and bind `LocalDecl`s.
4. **Declarations.** `TFnDecl` (type parameters, parameters with modes and
   defaults, result, contracts, body), `TSig` (a signature as a call checks
   against it), `TFieldSig`, `TSymEntry` (kind, generics, signature, fields,
   type, mutability) and `TPackage`. `TSymEntry` is what the verifier needs to
   know about a declaration it meets, from the package or a loaded interface;
   phase 5a may extend or replace it for interfaces but reuses `Ty`.
5. **Identities.** `NodeId` and `LocalId` are records of an `Int`, defined in
   `Lyric.Tir`. Giving the parser's nodes a `NodeId` (docs/70 §6.1) is a later
   step and decides then whether the parser imports `Lyric.Tir` or the type
   moves to a leaf package.

## Not decided here

- Associated-type projections (`AssociatedTypeDecl`) have no `Ty` case yet; an
  additive `TAssoc` case lands with phase 5a if interface signatures need it.
- Whether a `HostMemberRef` carries its member's host-metadata token; it holds
  the signature as Lyric types, which is what the verifier compares.

## Consequences

Nothing consumes the model yet, so behaviour is unchanged. `tir_self_test.l`
builds types and a generic identity function by hand and covers `tyEq` and
`renderTy`.
