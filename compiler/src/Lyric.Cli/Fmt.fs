/// `lyric fmt` — canonical pretty-printer for Lyric source files.
///
/// Works from the parser's AST, so non-doc comments are not preserved
/// (the Lyric lexer discards them per §1.3 of the grammar).  Doc
/// comments (`///` and `//!`) are preserved because they are part of
/// the AST.
///
/// Canonical formatting rules
/// --------------------------
/// * 2-space indentation.
/// * Opening brace `{` inline when there are no contract/where clauses;
///   on its own line otherwise.
/// * One blank line between top-level items.
/// * Contract clauses each on their own line, indented 2 spaces under
///   the function signature.
/// * Trailing newline; no trailing whitespace per line.
module Lyric.Cli.Fmt

open System.Text
open Lyric.Parser.Ast
open Lyric.Lexer

// ---------------------------------------------------------------------------
// Helper: document model (list of lines, no trailing newline per line)
// ---------------------------------------------------------------------------

/// A Doc is a list of strings where each string is one source line
/// (without a trailing newline).  Blank lines are represented as "".
type private Doc = string list

let private ind (n: int) (doc: Doc) : Doc =
    let prefix = String.replicate n " "
    doc |> List.map (fun l -> if l = "" then "" else prefix + l)

// ---------------------------------------------------------------------------
// Operator tables (standalone — reference nothing from the big rec group)
// ---------------------------------------------------------------------------

let private binPrec = function
    | BImplies             -> 1
    | BOr  | BXor          -> 2
    | BAnd                 -> 3
    | BEq  | BNeq
    | BLt  | BLte
    | BGt  | BGte          -> 4
    | BCoalesce            -> 5
    | BAdd | BSub          -> 6
    | BMul | BDiv | BMod   -> 7

let private binStr = function
    | BImplies  -> "implies"  | BOr  -> "or"  | BXor  -> "xor"
    | BAnd      -> "and"
    | BEq       -> "=="       | BNeq -> "!="
    | BLt       -> "<"        | BLte -> "<="
    | BGt       -> ">"        | BGte -> ">="
    | BCoalesce -> "??"
    | BAdd      -> "+"        | BSub -> "-"
    | BMul      -> "*"        | BDiv -> "/" | BMod -> "%"

let private assignStr = function
    | AssEq      -> "="  | AssPlus  -> "+=" | AssMinus  -> "-="
    | AssStar    -> "*=" | AssSlash -> "/=" | AssPercent -> "%="

let private intSufStr = function
    | I8  -> "i8"  | I16 -> "i16" | I32 -> "i32" | I64 -> "i64"
    | U8  -> "u8"  | U16 -> "u16" | U32 -> "u32" | U64 -> "u64"
    | NoIntSuffix -> ""

let private floatSufStr = function
    | F32 -> "f32" | F64 -> "f64" | NoFloatSuffix -> ""

// ---------------------------------------------------------------------------
// String/char escape (standalone)
// ---------------------------------------------------------------------------

let private escapeStr (s: string) : string =
    let sb = StringBuilder(s.Length + 4)
    for c in s do
        match c with
        | '"'  -> sb.Append "\\\"" |> ignore
        | '\\' -> sb.Append "\\\\" |> ignore
        | '\n' -> sb.Append "\\n"  |> ignore
        | '\r' -> sb.Append "\\r"  |> ignore
        | '\t' -> sb.Append "\\t"  |> ignore
        | c when int c < 0x20 ->
            sb.Append(sprintf "\\u%04x" (int c)) |> ignore
        | c    -> sb.Append c |> ignore
    sb.ToString()

let private pathStr (mp: ModulePath) : string =
    String.concat "." mp.Segments

// ---------------------------------------------------------------------------
// One big mutual-recursion group covering types, expressions, patterns,
// statements, and items.  Everything that can indirectly recurse must live
// here; helpers defined outside cannot be referenced from within the group
// if they in turn reference members of this group.
// ---------------------------------------------------------------------------

let rec private typeStr (te: TypeExpr) : string =
    match te.Kind with
    | TRef mp                -> pathStr mp
    | TGenericApp (mp, args) ->
        sprintf "%s[%s]" (pathStr mp) (args |> List.map typeArgStr |> String.concat ", ")
    | TArray (sz, elem)      ->
        sprintf "array[%s, %s]" (typeArgStr sz) (typeStr elem)
    | TSlice elem            -> sprintf "slice[%s]" (typeStr elem)
    | TRefined (mp, rb)      ->
        sprintf "%s range %s" (pathStr mp) (rangeBoundStr rb)
    | TTuple ts              ->
        sprintf "(%s)" (ts |> List.map typeStr |> String.concat ", ")
    | TNullable t            -> typeStr t + "?"
    | TFunction (ps, r)      ->
        sprintf "(%s) -> %s"
            (ps |> List.map typeStr |> String.concat ", ") (typeStr r)
    | TUnit                  -> "()"
    | TSelf                  -> "Self"
    | TNever                 -> "Never"
    | TParen t               -> sprintf "(%s)" (typeStr t)
    | TError                 -> "<type-error>"

and private typeArgStr (ta: TypeArg) : string =
    match ta with
    | TAType te  -> typeStr te
    | TAValue e  -> exprInline 0 e

and private rangeBoundStr (rb: RangeBound) : string =
    match rb with
    | RBClosed   (lo, hi) -> sprintf "%s ..= %s" (exprInline 0 lo) (exprInline 0 hi)
    | RBHalfOpen (lo, hi) -> sprintf "%s ..< %s" (exprInline 0 lo) (exprInline 0 hi)
    | RBLowerOpen hi      -> sprintf "..= %s" (exprInline 0 hi)
    | RBUpperOpen lo      -> sprintf "%s .." (exprInline 0 lo)

and private patStr (p: Pattern) : string =
    match p.Kind with
    | PWildcard                  -> "_"
    | PLiteral l                 -> litStr l
    | PRange (lo, incl, hi)      ->
        let op = if incl then "..=" else ".."
        sprintf "%s %s %s" (exprInline 0 lo) op (exprInline 0 hi)
    | PBinding (n, None)         -> n
    | PBinding (n, Some inner)   -> sprintf "%s @ %s" n (patStr inner)
    | PConstructor (mp, [])      -> pathStr mp
    | PConstructor (mp, ps)      ->
        sprintf "%s(%s)" (pathStr mp) (ps |> List.map patStr |> String.concat ", ")
    | PRecord (mp, fields, ignoreRest) ->
        let fieldStrs =
            fields |> List.map (function
                | RPFNamed (n, p, _) -> sprintf "%s: %s" n (patStr p)
                | RPFShort (n, _)    -> n)
        let rest = if ignoreRest then [".."] else []
        sprintf "%s { %s }" (pathStr mp)
            (fieldStrs @ rest |> String.concat ", ")
    | PTuple ps                  ->
        sprintf "(%s)" (ps |> List.map patStr |> String.concat ", ")
    | PParen inner               -> sprintf "(%s)" (patStr inner)
    | PTypeTest (inner, ty)      -> sprintf "%s: %s" (patStr inner) (typeStr ty)
    | POr ps                     -> ps |> List.map patStr |> String.concat " | "
    | PError                     -> "<pat-error>"

and private litStr (l: Literal) : string =
    match l with
    | LInt   (v, s)  -> string v + intSufStr s
    | LFloat (v, s)  ->
        let vStr = sprintf "%g" v
        let vStr = if vStr.Contains '.' || vStr.Contains 'e' then vStr else vStr + ".0"
        vStr + floatSufStr s
    | LChar cp ->
        let c = char cp
        match c with
        | '\\'  -> "'\\\\'" | '\'' -> "'\\'"; | '\n' -> "'\\n'"
        | '\r'  -> "'\\r'"; | '\t' -> "'\\t'"
        | c when int c < 0x20 -> sprintf "'\\u%04x'" (int c)
        | c     -> sprintf "'%c'" c
    | LString s        -> sprintf "\"%s\"" (escapeStr s)
    | LTripleString s  -> "\"\"\"" + s + "\"\"\""
    | LRawString s     -> sprintf "r\"%s\"" s
    | LBool true       -> "true"
    | LBool false      -> "false"
    | LUnit            -> "()"

/// Inline (single-line) expression printer.  `minPrec` is the minimum
/// precedence the caller is willing to accept without wrapping in parens.
and private exprInline (minPrec: int) (e: Expr) : string =
    match e.Kind with
    | ELiteral l         -> litStr l
    | EInterpolated segs ->
        let inner =
            segs |> List.map (function
                | ISText (s, _) -> escapeStr s
                | ISExpr ex     -> "${" + exprInline 0 ex + "}")
            |> String.concat ""
        sprintf "\"%s\"" inner
    | EPath mp           -> pathStr mp
    | EParen inner       -> sprintf "(%s)" (exprInline 0 inner)
    | ETuple es          ->
        sprintf "(%s)" (es |> List.map (exprInline 0) |> String.concat ", ")
    | EList es           ->
        sprintf "[%s]" (es |> List.map (exprInline 0) |> String.concat ", ")
    | EIf (cond, thenBr, elseBr, thenForm) ->
        if thenForm then
            let thenStr = eobInline thenBr
            let elseStr =
                match elseBr with
                | Some eb -> " else " + eobInline eb
                | None    -> ""
            sprintf "if %s then %s%s" (exprInline 0 cond) thenStr elseStr
        else
            let thenStr = eobInline thenBr
            let elseStr =
                match elseBr with
                | Some eb -> " else " + eobInline eb
                | None    -> ""
            sprintf "if %s %s%s" (exprInline 0 cond) thenStr elseStr
    | EMatch (scrut, arms) ->
        let armStr (a: MatchArm) =
            let guard =
                match a.Guard with
                | Some g -> sprintf " if %s" (exprInline 0 g)
                | None   -> ""
            sprintf "case %s%s -> %s" (patStr a.Pattern) guard (eobInline a.Body)
        sprintf "match %s { %s }"
            (exprInline 0 scrut) (arms |> List.map armStr |> String.concat "; ")
    | EAwait inner       -> sprintf "await %s" (exprInline 0 inner)
    | ESpawn inner       -> sprintf "spawn %s" (exprInline 0 inner)
    | ETry inner         -> sprintf "try %s" (exprInline 0 inner)
    | EOld inner         -> sprintf "old(%s)" (exprInline 0 inner)
    | EForall (binders, whereEx, body) ->
        let bindsStr =
            binders |> List.map (fun b -> sprintf "%s: %s" b.Name (typeStr b.Type))
            |> String.concat ", "
        let whereStr =
            match whereEx with
            | Some w -> sprintf " where %s" (exprInline 0 w)
            | None   -> ""
        sprintf "forall (%s)%s { %s }" bindsStr whereStr (exprInline 0 body)
    | EExists (binders, whereEx, body) ->
        let bindsStr =
            binders |> List.map (fun b -> sprintf "%s: %s" b.Name (typeStr b.Type))
            |> String.concat ", "
        let whereStr =
            match whereEx with
            | Some w -> sprintf " where %s" (exprInline 0 w)
            | None   -> ""
        sprintf "exists (%s)%s { %s }" bindsStr whereStr (exprInline 0 body)
    | ESelf              -> "self"
    | EResult            -> "result"
    | ELambda (ps, body) ->
        if List.isEmpty ps then
            sprintf "{ %s }" (blockInline body)
        else
            let psStr =
                ps |> List.map (fun lp ->
                    match lp.Type with
                    | Some ty -> sprintf "%s: %s" lp.Name (typeStr ty)
                    | None    -> lp.Name)
                |> String.concat ", "
            sprintf "{ %s -> %s }" psStr (blockInline body)
    | ECall (fn, args)   ->
        sprintf "%s(%s)" (exprInline 0 fn) (args |> List.map callArgStr |> String.concat ", ")
    | ETypeApp (fn, args) ->
        sprintf "%s[%s]" (exprInline 0 fn) (args |> List.map typeArgStr |> String.concat ", ")
    | EIndex (recv, indices) ->
        sprintf "%s[%s]" (exprInline 0 recv) (indices |> List.map (exprInline 0) |> String.concat ", ")
    | EMember (recv, name) -> sprintf "%s.%s" (exprInline 0 recv) name
    | EPropagate inner   -> sprintf "%s?" (exprInline 0 inner)
    | EPrefix (op, inner) ->
        let opStr = match op with PreNeg -> "-" | PreNot -> "not " | PreRef -> "&"
        sprintf "%s%s" opStr (exprInline 0 inner)
    | EBinop (op, lhs, rhs) ->
        let prec    = binPrec op
        let lhsStr  = exprInline prec lhs
        // Right child uses same prec for right-assoc ops (implies, ??)
        let rhsPrec = match op with BImplies | BCoalesce -> prec | _ -> prec + 1
        let rhsStr  = exprInline rhsPrec rhs
        let s = sprintf "%s %s %s" lhsStr (binStr op) rhsStr
        if prec < minPrec then sprintf "(%s)" s else s
    | ERange rb          -> rangeBoundStr rb
    | EAssign (tgt, op, value) ->
        sprintf "%s %s %s" (exprInline 0 tgt) (assignStr op) (exprInline 0 value)
    | EBlock b           -> sprintf "{ %s }" (blockInline b)
    | EUnsafe b          -> sprintf "unsafe { %s }" (blockInline b)
    | EError             -> "<error>"

and private eobInline (eob: ExprOrBlock) : string =
    match eob with
    | EOBExpr e  -> exprInline 0 e
    | EOBBlock b -> sprintf "{ %s }" (blockInline b)

and private blockInline (b: Block) : string =
    b.Statements |> List.map stmtInline |> String.concat "; "

and private stmtInline (s: Statement) : string =
    match s.Kind with
    | SLocal lb ->
        match lb with
        | LBVal (p, ty, init) ->
            let tyStr = match ty with Some t -> ": " + typeStr t | None -> ""
            sprintf "val %s%s = %s" (patStr p) tyStr (exprInline 0 init)
        | LBVar (name, ty, init) ->
            let tyStr   = match ty   with Some t -> ": " + typeStr t | None -> ""
            let initStr = match init with Some e -> " = " + exprInline 0 e | None -> ""
            sprintf "var %s%s%s" name tyStr initStr
        | LBLet (name, ty, init) ->
            let tyStr = match ty with Some t -> ": " + typeStr t | None -> ""
            sprintf "let %s%s = %s" name tyStr (exprInline 0 init)
    | SAssign (tgt, op, value) ->
        sprintf "%s %s %s" (exprInline 0 tgt) (assignStr op) (exprInline 0 value)
    | SReturn (Some ex) -> sprintf "return %s" (exprInline 0 ex)
    | SReturn None      -> "return"
    | SBreak  (Some l)  -> sprintf "break %s" l
    | SBreak  None      -> "break"
    | SContinue (Some l)-> sprintf "continue %s" l
    | SContinue None    -> "continue"
    | SThrow ex         -> sprintf "throw %s" (exprInline 0 ex)
    | STry (body, catches) ->
        let catchStr (c: CatchClause) =
            let bind = match c.Bind with Some b -> " as " + b | None -> ""
            sprintf "catch %s%s { %s }" c.Type bind (blockInline c.Body)
        sprintf "try { %s } %s"
            (blockInline body) (catches |> List.map catchStr |> String.concat " ")
    | SDefer b          -> sprintf "defer { %s }" (blockInline b)
    | SScope (bind, body) ->
        let bindStr = match bind with Some n -> " " + n | None -> ""
        sprintf "scope%s { %s }" bindStr (blockInline body)
    | SFor (lbl, pat, iter, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        sprintf "%sfor %s in %s { %s }" lblStr (patStr pat) (exprInline 0 iter) (blockInline body)
    | SWhile (lbl, cond, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        sprintf "%swhile %s { %s }" lblStr (exprInline 0 cond) (blockInline body)
    | SLoop (lbl, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        sprintf "%sdo { %s }" lblStr (blockInline body)
    | SInvariant ex     -> sprintf "invariant: %s" (exprInline 0 ex)
    | SExpr ex          -> exprInline 0 ex
    | SRule (lhs, rhs)  -> sprintf "%s -> %s" (exprInline 0 lhs) (exprInline 0 rhs)
    | SItem item        -> itemDoc item |> String.concat "; "

and private callArgStr (ca: CallArg) : string =
    match ca with
    | CANamed (n, v, _) -> sprintf "%s = %s" n (exprInline 0 v)
    | CAPositional e    -> exprInline 0 e

// --- Generic and where-clause helpers (inside rec group so itemDoc can use them) ---

and private genParamStr (gp: GenericParam) : string =
    match gp with
    | GPType (n, _)              -> n
    | GPValue (n, constraint', _)-> sprintf "%s: %s" n (typeStr constraint')

and private genParamsStr (gps: GenericParams option) : string =
    match gps with
    | None    -> ""
    | Some gp ->
        sprintf "[%s]" (gp.Params |> List.map genParamStr |> String.concat ", ")

and private constraintRefStr (cr: ConstraintRef) : string =
    let args =
        if List.isEmpty cr.Args then ""
        else sprintf "[%s]" (cr.Args |> List.map typeArgStr |> String.concat ", ")
    pathStr cr.Head + args

and private whereBoundStr (wb: WhereBound) : string =
    sprintf "%s: %s" wb.Name (wb.Constraints |> List.map constraintRefStr |> String.concat " + ")

and private whereClauseStr (wc: WhereClause option) : string =
    match wc with
    | None    -> ""
    | Some wc -> "where " + (wc.Bounds |> List.map whereBoundStr |> String.concat ", ")

and private paramStr (p: Param) : string =
    let modeStr =
        match p.Mode with
        | PMIn    -> "in " | PMOut -> "out " | PMInout -> "inout "
    let defStr =
        match p.Default with
        | Some d -> " = " + exprInline 0 d
        | None   -> ""
    sprintf "%s: %s%s%s" p.Name modeStr (typeStr p.Type) defStr

and private contractStr (cc: ContractClause) : string =
    match cc with
    | CCRequires  (ex, _) -> sprintf "requires: %s"  (exprInline 0 ex)
    | CCEnsures   (ex, _) -> sprintf "ensures: %s"   (exprInline 0 ex)
    | CCWhen      (ex, _) -> sprintf "when: %s"      (exprInline 0 ex)
    | CCDecreases (ex, _) -> sprintf "decreases: %s" (exprInline 0 ex)
    | CCRaises    (tys,_) ->
        sprintf "raises: %s" (tys |> List.map typeStr |> String.concat ", ")

and private annotationArgStr (aa: AnnotationArg) : string =
    let valStr = function
        | AVInt    (v, _) -> string v
        | AVString (s, _) -> sprintf "\"%s\"" (escapeStr s)
        | AVBool   (b, _) -> if b then "true" else "false"
        | AVIdent  (i, _) -> i
    match aa with
    | AAName (n, v, _) -> sprintf "%s = %s" n (valStr v)
    | ABare  (n, _)    -> n
    | ALiteral (v, _)  -> valStr v

and private annotationStr (a: Annotation) : string =
    if List.isEmpty a.Args then "@" + pathStr a.Name
    else
        sprintf "@%s(%s)"
            (pathStr a.Name)
            (a.Args |> List.map annotationArgStr |> String.concat ", ")

and private docLines (docs: DocComment list) : Doc =
    docs |> List.map (fun d ->
        let prefix = if d.IsModule then "//!" else "///"
        if d.Text = "" then prefix else prefix + " " + d.Text)

and private fieldDeclStr (fd: FieldDecl) : string =
    let vis    = match fd.Visibility with Some _ -> "pub " | None -> ""
    let defStr = match fd.Default with Some e -> " = " + exprInline 0 e | None -> ""
    sprintf "%s%s: %s%s" vis fd.Name (typeStr fd.Type) defStr

and private funcSigStr (sg: FunctionSig) : string =
    let asyncStr  = if sg.IsAsync then "async " else ""
    let gens      = genParamsStr sg.Generics
    let paramsStr = sg.Params |> List.map paramStr |> String.concat ", "
    let retStr    = match sg.Return with Some t -> ": " + typeStr t | None -> ""
    sprintf "%sfunc %s%s(%s)%s" asyncStr sg.Name gens paramsStr retStr

// ---------------------------------------------------------------------------
// Block printer (multi-line, returns unindented lines)
// ---------------------------------------------------------------------------

and private blockLines (b: Block) : Doc =
    b.Statements |> List.collect stmtLines

and private stmtLines (s: Statement) : Doc =
    match s.Kind with
    | SLocal _ | SAssign _ | SReturn _ | SBreak _ | SContinue _
    | SThrow _ | SInvariant _ | SRule _ ->
        [stmtInline s]
    | SExpr ex ->
        match ex.Kind with
        | EMatch (scrut, arms) ->
            let armDoc (a: MatchArm) : Doc =
                let guard =
                    match a.Guard with
                    | Some g -> sprintf " if %s" (exprInline 0 g)
                    | None   -> ""
                match a.Body with
                | EOBExpr body ->
                    [sprintf "case %s%s -> %s" (patStr a.Pattern) guard (exprInline 0 body)]
                | EOBBlock blk ->
                    [sprintf "case %s%s -> {" (patStr a.Pattern) guard]
                    @ ind 2 (blockLines blk)
                    @ ["}"]
            [sprintf "match %s {" (exprInline 0 scrut)]
            @ ind 2 (arms |> List.collect armDoc)
            @ ["}"]
        | EIf (cond, thenBr, elseBr, false) ->
            ifBlockLines cond thenBr elseBr
        | _ ->
            [stmtInline s]
    | SFor (lbl, pat, iter, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        [sprintf "%sfor %s in %s {" lblStr (patStr pat) (exprInline 0 iter)]
        @ ind 2 (blockLines body)
        @ ["}"]
    | SWhile (lbl, cond, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        [sprintf "%swhile %s {" lblStr (exprInline 0 cond)]
        @ ind 2 (blockLines body)
        @ ["}"]
    | SLoop (lbl, body) ->
        let lblStr = match lbl with Some l -> l + ": " | None -> ""
        [sprintf "%sdo {" lblStr]
        @ ind 2 (blockLines body)
        @ ["}"]
    | STry (body, catches) ->
        let catchDoc (c: CatchClause) : Doc =
            let bind = match c.Bind with Some b -> " as " + b | None -> ""
            [sprintf "} catch %s%s {" c.Type bind]
            @ ind 2 (blockLines c.Body)
        ["try {"]
        @ ind 2 (blockLines body)
        @ (catches |> List.collect catchDoc)
        @ ["}"]
    | SDefer body ->
        ["defer {"]
        @ ind 2 (blockLines body)
        @ ["}"]
    | SScope (bind, body) ->
        let bindStr = match bind with Some n -> " " + n | None -> ""
        [sprintf "scope%s {" bindStr]
        @ ind 2 (blockLines body)
        @ ["}"]
    | SItem item ->
        itemDoc item

and private ifBlockLines cond thenBr elseBr : Doc =
    let condStr = exprInline 0 cond
    let thenDoc =
        match thenBr with
        | EOBBlock b -> blockLines b
        | EOBExpr  e -> [exprInline 0 e]
    let elseDoc : Doc =
        match elseBr with
        | None -> ["}"]
        | Some (EOBBlock b) ->
            ["} else {"] @ ind 2 (blockLines b) @ ["}"]
        | Some (EOBExpr { Kind = EIf (c2, tb2, eb2, false) }) ->
            let inner = ifBlockLines c2 tb2 eb2
            match inner with
            | []     -> ["}"]
            | h :: t -> ["} else " + h] @ t
        | Some (EOBExpr e) ->
            ["} else {"] @ ind 2 [exprInline 0 e] @ ["}"]
    [sprintf "if %s {" condStr]
    @ ind 2 thenDoc
    @ elseDoc

// ---------------------------------------------------------------------------
// Item printers (inside rec group because stmtLines -> SItem -> itemDoc)
// ---------------------------------------------------------------------------

and private itemDoc (item: Item) : Doc =
    let visStr = match item.Visibility with Some _ -> "pub " | None -> ""
    let annoLines = item.Annotations |> List.map annotationStr
    let header    = docLines item.DocComments @ annoLines
    match item.Kind with

    | IFunc fn ->
        funcDoc visStr fn

    | IRecord rd ->
        header @ recordDoc visStr "record" rd.Name rd.Generics rd.Where rd.Members

    | IExposedRec rd ->
        header @ recordDoc visStr "exposed record" rd.Name rd.Generics rd.Where rd.Members

    | IUnion ud ->
        header @ unionDoc visStr ud

    | IEnum ed ->
        header @ enumDoc visStr ed

    | IOpaque od ->
        let odAnnos = od.Annotations |> List.map annotationStr
        let gens    = genParamsStr od.Generics
        let whereL  = let s = whereClauseStr od.Where in if s = "" then [] else ["  " + s]
        let body =
            if not od.HasBody then []
            else
                let mLines =
                    od.Members |> List.collect (function
                        | OMField     fd -> [fieldDeclStr fd]
                        | OMInvariant ic -> [sprintf "invariant: %s" (exprInline 0 ic.Expr)])
                [sprintf "%sopaque type %s%s {" visStr od.Name gens]
                @ whereL
                @ ind 2 mLines
                @ ["}"]
        if List.isEmpty body then
            docLines item.DocComments @ odAnnos
            @ [sprintf "%sopaque type %s%s" visStr od.Name gens]
        else
            docLines item.DocComments @ odAnnos @ body

    | IDistinctType dt ->
        let gens      = genParamsStr dt.Generics
        let rangeStr  =
            match dt.Range with
            | Some rb -> " range " + rangeBoundStr rb
            | None    -> ""
        let derivesStr =
            if List.isEmpty dt.Derives then ""
            else " derives " + String.concat ", " dt.Derives
        header
        @ [sprintf "%stype %s%s = %s%s%s"
            visStr dt.Name gens (typeStr dt.Underlying) rangeStr derivesStr]

    | ITypeAlias ta ->
        header
        @ [sprintf "%salias %s%s = %s" visStr ta.Name (genParamsStr ta.Generics) (typeStr ta.RHS)]

    | IProtected pd ->
        let gens   = genParamsStr pd.Generics
        let whereL = let s = whereClauseStr pd.Where in if s = "" then [] else ["  " + s]
        let mLines = pd.Members |> List.collect protectedMemberDoc
        header
        @ [sprintf "%sprotected type %s%s {" visStr pd.Name gens]
        @ whereL
        @ ind 2 mLines
        @ ["}"]

    | IInterface id ->
        let gens   = genParamsStr id.Generics
        let whereL = let s = whereClauseStr id.Where in if s = "" then [] else ["  " + s]
        let mLines =
            id.Members |> List.collect (function
                | IMSig  sg -> [funcSigStr sg]
                | IMFunc fn -> funcDoc "" fn
                | IMAssoc a ->
                    match a.Default with
                    | Some t -> [sprintf "type %s = %s" a.Name (typeStr t)]
                    | None   -> [sprintf "type %s" a.Name])
        header
        @ [sprintf "%sinterface %s%s {" visStr id.Name gens]
        @ whereL
        @ ind 2 mLines
        @ ["}"]

    | IImpl id ->
        let gens    = genParamsStr id.Generics
        let target  = typeStr id.Target
        let ifStr   = constraintRefStr id.Interface
        let whereL  = let s = whereClauseStr id.Where in if s = "" then [] else ["  " + s]
        let mLines  =
            id.Members |> List.collect (function
                | IMplFunc  fn -> funcDoc "" fn
                | IMplAssoc a  ->
                    match a.Default with
                    | Some t -> [sprintf "type %s = %s" a.Name (typeStr t)]
                    | None   -> [sprintf "type %s" a.Name])
        header
        @ [sprintf "impl%s %s for %s {" gens ifStr target]
        @ whereL
        @ ind 2 mLines
        @ ["}"]

    | IWire wd ->
        let parStr  = wd.Params |> List.map paramStr |> String.concat ", "
        let mLines  =
            wd.Members |> List.map (function
                | WMProvided  (n, ty, _) ->
                    sprintf "provided %s: %s" n (typeStr ty)
                | WMSingleton (n, ty, init, _) ->
                    sprintf "singleton %s: %s = %s" n (typeStr ty) (exprInline 0 init)
                | WMScoped    (scope, n, ty, init, _) ->
                    sprintf "scoped %s %s: %s = %s" scope n (typeStr ty) (exprInline 0 init)
                | WMBind      (iface, prov, _) ->
                    sprintf "bind %s = %s" (typeStr iface) (exprInline 0 prov)
                | WMExpose    (n, _) -> sprintf "expose %s" n
                | WMLocal     (n, ty, init, _) ->
                    let tyStr = match ty with Some t -> ": " + typeStr t | None -> ""
                    sprintf "val %s%s = %s" n tyStr (exprInline 0 init))
        header
        @ [sprintf "wire %s(%s) {" wd.Name parStr]
        @ ind 2 mLines
        @ ["}"]

    | IScopeKind sd ->
        header @ [sprintf "scope_kind %s" sd.Name]

    | IConst cd ->
        header
        @ [sprintf "%sconst %s: %s = %s"
            visStr cd.Name (typeStr cd.Type) (exprInline 0 cd.Init)]

    | IVal vd ->
        let tyStr = match vd.Type with Some t -> ": " + typeStr t | None -> ""
        header
        @ [sprintf "%sval %s%s = %s"
            visStr (patStr vd.Pattern) tyStr (exprInline 0 vd.Init)]

    | IExtern ep ->
        let epAnnos = ep.Annotations |> List.map annotationStr
        let mLines  =
            ep.Members |> List.map (function
                | EMRecord r       -> sprintf "record %s" r.Name
                | EMExposedRec r   -> sprintf "exposed record %s" r.Name
                | EMUnion u        -> sprintf "union %s" u.Name
                | EMEnum e         -> sprintf "enum %s" e.Name
                | EMOpaque o       -> sprintf "opaque type %s" o.Name
                | EMSig sg         -> funcSigStr sg
                | EMTypeAlias ta   -> sprintf "type %s" ta.Name
                | EMDistinctType d -> sprintf "distinct type %s" d.Name)
        docLines item.DocComments @ epAnnos
        @ [sprintf "extern %s {" (pathStr ep.Path)]
        @ ind 2 mLines
        @ ["}"]

    | IExternType et ->
        header
        @ [sprintf "extern type %s%s = \"%s\""
            et.Name (genParamsStr et.Generics) et.ClrName]

    | ITest td ->
        header
        @ [sprintf "test \"%s\" {" (escapeStr td.Title)]
        @ ind 2 (blockLines td.Body)
        @ ["}"]

    | IProperty pd ->
        let bindsStr =
            pd.ForAll |> List.map (fun b -> sprintf "%s: %s" b.Name (typeStr b.Type))
            |> String.concat ", "
        let whereStr =
            match pd.Where with
            | Some w -> sprintf " where %s" (exprInline 0 w)
            | None   -> ""
        header
        @ [sprintf "property \"%s\" forall (%s)%s {" (escapeStr pd.Title) bindsStr whereStr]
        @ ind 2 (blockLines pd.Body)
        @ ["}"]

    | IFixture fd ->
        let tyStr = match fd.Type with Some t -> ": " + typeStr t | None -> ""
        header
        @ [sprintf "fixture %s%s = %s" fd.Name tyStr (exprInline 0 fd.Init)]

    | IError ->
        ["// <parse-error>"]

and private funcDoc (visStr: string) (fn: FunctionDecl) : Doc =
    let annoLines     = fn.Annotations |> List.map annotationStr
    let fnDocLines    = docLines fn.DocComments
    let asyncStr      = if fn.IsAsync then "async " else ""
    let gens          = genParamsStr fn.Generics
    let paramsStr     = fn.Params |> List.map paramStr |> String.concat ", "
    let retStr        = match fn.Return with Some t -> ": " + typeStr t | None -> ""
    let sig_          = sprintf "%s%sfunc %s%s(%s)%s" visStr asyncStr fn.Name gens paramsStr retStr
    let contractLines = fn.Contracts |> List.map (fun c -> "  " + contractStr c)
    let whereLines    =
        match fn.Where with
        | None    -> []
        | Some wc -> ["  " + whereClauseStr (Some wc)]
    let extraLines = contractLines @ whereLines
    fnDocLines @ annoLines @
    match fn.Body with
    | None             -> [sig_] @ contractLines @ whereLines
    | Some (FBExpr e)  -> [sig_ + " = " + exprInline 0 e]
    | Some (FBBlock b) ->
        if List.isEmpty extraLines then
            [sig_ + " {"] @ ind 2 (blockLines b) @ ["}"]
        else
            [sig_] @ extraLines @ ["{"] @ ind 2 (blockLines b) @ ["}"]

and private recordDoc visStr kind name gens where_ members : Doc =
    let genStr  = genParamsStr gens
    let whereL  = let s = whereClauseStr where_ in if s = "" then [] else ["  " + s]
    let mLines  =
        members |> List.collect (function
            | RMField     fd -> [fieldDeclStr fd]
            | RMInvariant ic -> [sprintf "invariant: %s" (exprInline 0 ic.Expr)]
            | RMFunc      fn -> funcDoc "" fn)
    [sprintf "%s%s %s%s {" visStr kind name genStr]
    @ whereL
    @ ind 2 mLines
    @ ["}"]

and private unionDoc visStr (ud: UnionDecl) : Doc =
    let gens    = genParamsStr ud.Generics
    let whereL  = let s = whereClauseStr ud.Where in if s = "" then [] else ["  " + s]
    let caseDoc =
        ud.Cases |> List.collect (fun c ->
            let cDocLines = docLines c.DocComments
            let cAnnos    = c.Annotations |> List.map annotationStr
            let fieldsStr =
                c.Fields |> List.map (function
                    | UFNamed (n, ty, _) -> sprintf "%s: %s" n (typeStr ty)
                    | UFPos   (ty, _)    -> typeStr ty)
                |> String.concat ", "
            let caseLine =
                if List.isEmpty c.Fields then sprintf "case %s" c.Name
                else sprintf "case %s(%s)" c.Name fieldsStr
            cDocLines @ cAnnos @ [caseLine])
    [sprintf "%sunion %s%s {" visStr ud.Name gens]
    @ whereL
    @ ind 2 caseDoc
    @ ["}"]

and private enumDoc visStr (ed: EnumDecl) : Doc =
    let caseDoc =
        ed.Cases |> List.collect (fun c ->
            let cDocLines = docLines c.DocComments
            let cAnnos    = c.Annotations |> List.map annotationStr
            cDocLines @ cAnnos @ [sprintf "case %s" c.Name])
    [sprintf "%senum %s {" visStr ed.Name]
    @ ind 2 caseDoc
    @ ["}"]

and private protectedMemberDoc (pm: ProtectedMember) : Doc =
    match pm with
    | PMField (PFVar (n, ty, init, _)) ->
        let initStr = match init with Some e -> " = " + exprInline 0 e | None -> ""
        [sprintf "var %s: %s%s" n (typeStr ty) initStr]
    | PMField (PFLet (n, ty, init, _)) ->
        let initStr = match init with Some e -> " = " + exprInline 0 e | None -> ""
        [sprintf "let %s: %s%s" n (typeStr ty) initStr]
    | PMField (PFImmutable fd) -> [fieldDeclStr fd]
    | PMInvariant ic -> [sprintf "invariant: %s" (exprInline 0 ic.Expr)]
    | PMEntry ed ->
        let vStr      = match ed.Visibility with Some _ -> "pub " | None -> ""
        let paramsStr = ed.Params |> List.map paramStr |> String.concat ", "
        let retStr    = match ed.Return with Some t -> ": " + typeStr t | None -> ""
        let conLines  = ed.Contracts |> List.map (fun c -> "  " + contractStr c)
        let sig_      = sprintf "%sentry %s(%s)%s" vStr ed.Name paramsStr retStr
        let bodyLines =
            match ed.Body with
            | FBBlock b -> blockLines b
            | FBExpr  e -> [exprInline 0 e]
        if List.isEmpty conLines then
            [sig_ + " {"] @ ind 2 bodyLines @ ["}"]
        else
            [sig_] @ conLines @ ["{"] @ ind 2 bodyLines @ ["}"]
    | PMFunc fn -> funcDoc "" fn

// ---------------------------------------------------------------------------
// Import and file-level printers (outside the rec group; call into it)
// ---------------------------------------------------------------------------

let private importDoc (imp: ImportDecl) : Doc =
    let selStr =
        match imp.Selector with
        | None -> ""
        | Some (ISSingle item) ->
            let a = match item.Alias with Some a -> " as " + a | None -> ""
            "." + item.Name + a
        | Some (ISGroup items) ->
            let itemStr (i: ImportItem) =
                match i.Alias with Some a -> i.Name + " as " + a | None -> i.Name
            ".{" + (items |> List.map itemStr |> String.concat ", ") + "}"
    let aliasStr = match imp.Alias with Some a -> " as " + a | None -> ""
    let kw       = if imp.IsPubUse then "pub use" else "import"
    [sprintf "%s %s%s%s" kw (pathStr imp.Path) selStr aliasStr]

// ---------------------------------------------------------------------------
// Top-level formatter
// ---------------------------------------------------------------------------

/// Format a parsed source file into canonical Lyric source text.
let format (file: SourceFile) : string =
    let sb = StringBuilder()
    let emit (line: string) =
        sb.AppendLine(line.TrimEnd()) |> ignore

    for d in file.ModuleDoc do
        let prefix = if d.IsModule then "//!" else "///"
        emit (if d.Text = "" then prefix else prefix + " " + d.Text)

    for a in file.FileLevelAnnotations do
        emit (annotationStr a)

    emit (sprintf "package %s" (pathStr file.Package.Path))

    if not (List.isEmpty file.Imports) then
        emit ""
        for imp in file.Imports do
            for line in importDoc imp do emit line

    if not (List.isEmpty file.Items) then
        emit ""
        for i, doc in file.Items |> List.mapi (fun i item -> i, itemDoc item) do
            if i > 0 then emit ""
            for line in doc do emit line

    sb.ToString()

/// Returns `true` when `source` already matches its canonical form.
let isFormatted (source: string) (file: SourceFile) : bool =
    let canonical = format file
    let normalise (s: string) = s.Replace("\r\n", "\n").TrimEnd()
    normalise source = normalise canonical
