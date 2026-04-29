/// Resolve function-shaped declarations (`FunctionDecl`, `FunctionSig`)
/// into the type-checker's `ResolvedSig`. Lives in its own file so
/// `ExprChecker` can call it without forward-reference gymnastics.
module Lyric.TypeChecker.Signature

open Lyric.Lexer
open Lyric.Parser.Ast
open Lyric.TypeChecker
open Lyric.TypeChecker.Symbols

let private genericNames (gp: GenericParams option) : string list =
    match gp with
    | None -> []
    | Some gps ->
        gps.Params |> List.choose (fun g ->
            match g with
            | GPType (name, _)  -> Some name
            | GPValue _         -> None)

let private withGenericContext
        (env: CheckEnv)
        (extra: string list)
        (action: CheckEnv -> 'a) : 'a =
    let saved = env.Generics
    let merged = GenericContext.union env.Generics (GenericContext.make extra)
    let env' = { env with Generics = merged }
    let result = action env'
    // Restore by ignoring `env'` — the caller still holds `env` with
    // `saved` intact (we only mutate ScopeStack/Diagnostics, not the
    // record fields).
    ignore saved
    result

/// Resolve a function signature given a parser-side `Param list`
/// + return type + generic clause. The shared signature checker is
/// reused by `FunctionDecl` (top-level) and `FunctionSig` (interface
/// member / extern decl).
let resolveSignature
        (env: CheckEnv)
        (generics: GenericParams option)
        (params': Param list)
        (returnTy: TypeExpr option) : ResolvedSig =
    let gNames = genericNames generics
    withGenericContext env gNames (fun env' ->
        let pTys =
            params' |> List.map (fun p -> Resolver.resolve env' p.Type)
        let rTy =
            match returnTy with
            | Some t -> Resolver.resolve env' t
            | None   -> Type.unit'
        { Generics = gNames
          Params   = pTys
          Return   = rTy })

let resolveFunction (env: CheckEnv) (fd: FunctionDecl) : ResolvedSig =
    resolveSignature env fd.Generics fd.Params fd.Return

let resolveFunctionSig (env: CheckEnv) (fs: FunctionSig) : ResolvedSig =
    resolveSignature env fs.Generics fs.Params fs.Return
