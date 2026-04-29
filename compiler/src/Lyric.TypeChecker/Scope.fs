/// Lexical scope stack and the package-level symbol table.
namespace Lyric.TypeChecker

open System.Collections.Generic

/// A package's symbol table: a flat map of name → list of symbols
/// (`list` because Lyric admits some shadowing patterns and we want
/// to keep all candidates for diagnostics).
type SymbolTable() =
    let map = Dictionary<string, ResizeArray<Symbol>>()

    member _.Add(s: Symbol) =
        let bucket =
            match map.TryGetValue(s.Name) with
            | true, b -> b
            | false, _ ->
                let b = ResizeArray<Symbol>()
                map.[s.Name] <- b
                b
        bucket.Add(s)

    member _.TryFind(name: string) : Symbol seq =
        match map.TryGetValue(name) with
        | true, b -> upcast b
        | false, _ -> Seq.empty

    member this.TryFindOne(name: string) : Symbol option =
        this.TryFind(name) |> Seq.tryHead

    member _.All() : Symbol seq =
        seq {
            for kvp in map do
                for s in kvp.Value do
                    yield s
        }

/// A single lexical scope's local bindings (parameters, val/var/let).
/// Bindings shadow outer scopes; lookup walks the chain.
type LocalBinding =
    { Name: string
      Type: Type
      IsMutable: bool }

/// Stack of lexical scopes. Innermost-first; each scope is a
/// dictionary of name → LocalBinding.
type Scope() =
    let frames = ResizeArray<Dictionary<string, LocalBinding>>()
    do frames.Add(Dictionary())

    member _.Push() =
        frames.Add(Dictionary())

    member _.Pop() =
        if frames.Count > 1 then
            frames.RemoveAt(frames.Count - 1)

    member _.Add(binding: LocalBinding) =
        let top = frames.[frames.Count - 1]
        top.[binding.Name] <- binding

    /// Look up the innermost binding for `name`, walking outward.
    /// Returns None if not found in any frame.
    member _.TryFind(name: string) : LocalBinding option =
        let mutable result = None
        let mutable i = frames.Count - 1
        while result.IsNone && i >= 0 do
            match frames.[i].TryGetValue(name) with
            | true, b -> result <- Some b
            | false, _ -> ()
            i <- i - 1
        result

    member _.Depth = frames.Count

/// Generic-parameter set: names of type parameters in scope. Used by
/// the type resolver to resolve a bare `T` to `TVar "T"` instead of
/// failing to find the symbol.
type GenericContext() =
    let stack = ResizeArray<HashSet<string>>()
    do stack.Add(HashSet())

    member _.Push(names: string seq) =
        let h = HashSet(names)
        stack.Add(h)

    member _.Pop() =
        if stack.Count > 1 then
            stack.RemoveAt(stack.Count - 1)

    member _.IsTypeParam(name: string) : bool =
        let mutable found = false
        let mutable i = stack.Count - 1
        while not found && i >= 0 do
            if stack.[i].Contains(name) then found <- true
            i <- i - 1
        found
