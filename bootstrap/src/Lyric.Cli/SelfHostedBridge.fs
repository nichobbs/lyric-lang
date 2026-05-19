/// Shared utilities for the `SelfHosted*` bridge modules
/// (`SelfHostedCli.fs`, `SelfHostedFmt.fs`, etc.).
///
/// Each bridge module follows the same pattern: compile a tiny
/// driver program so the emitter materialises a self-hosted DLL into
/// the per-process stdlib cache, `Assembly.LoadFrom` every cached
/// DLL, reflect out the static entry point on
/// `Lyric.<Name>.Program`, and cache the resulting delegate for
/// subsequent calls in the same process.
///
/// # Single-shot semantics (#344)
///
/// Every bridge calls `preloadStdlibAssemblies` on first use and
/// caches the resolved delegate forever afterwards.  This is safe
/// for one-shot CLI invocations (the common case): the working set
/// grows by exactly one set of stdlib assemblies, then stabilises.
///
/// In a long-running daemon (a future `lyric lsp` is the motivating
/// example) the same bridge is hit many times.  Today this is still
/// safe because the delegate cache prevents repeated
/// `Assembly.LoadFrom` calls.  It would become a real leak if either
///
///   * the bridge stops caching and resolves every call (don't do
///     that — the resolve is the slow part anyway), or
///   * a future LSP recompiles with different feature flags and
///     produces a new set of stdlib DLLs that need to be loaded
///     and later released.
///
/// The structural fix for that future is to load into a collectible
/// `AssemblyLoadContext` (`isCollectible = true`, .NET Core 3+) so
/// that a daemon can unload the per-session ALC before allocating a
/// fresh one.  Until the LSP lands and exercises that path, the
/// bridges stay on the default AppDomain via `Assembly.LoadFrom`
/// — see `loadFromCache` below for the single seam to swap.
module internal Lyric.Cli.SelfHostedBridge

open System.Reflection
open Lyric.Emitter

/// Load every Lyric-emitted stdlib DLL in the per-process cache into
/// the default AppDomain.  Idempotent: `Assembly.LoadFrom` returns
/// the cached `Assembly` on a duplicate path.  Best-effort —
/// missing/corrupt cache entries surface later when a consumer
/// reflects out a missing type.
///
/// See module docstring for the single-shot semantics and the
/// future-proofing path (collectible AssemblyLoadContext).
let preloadStdlibAssemblies () : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        try Assembly.LoadFrom p |> ignore
        with _ -> ()

/// Load a single bridge DLL by path.  Lives here so the future
/// collectible-ALC migration only has to change one call site.
let loadFromCache (path: string) : Assembly =
    Assembly.LoadFrom path
