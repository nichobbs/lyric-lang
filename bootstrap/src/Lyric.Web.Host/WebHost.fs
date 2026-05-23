/// Lyric.Web.Host — .NET host shim for the lyric-web Kestrel kernel.
///
/// Phase 8 of #733 (final): BCL `System.Net.HttpListener` path-finder
/// backend.  Real ASP.NET Core Kestrel + minimal-API routing lands as
/// a follow-up under #784 — that path needs Microsoft.AspNetCore NuGet
/// deps + a real Lyric-to-host callback mechanism to dispatch routes
/// to user-defined handlers, while the HttpListener path stays
/// self-contained and proves the SDK channel + port binding work
/// (which was the visible no-op symptom in #784).
///
/// The kernel file `lyric-web/src/web.l` declares `serve(...)` with
/// `@externTarget("Lyric.Web.HttpListenerHost.serve")`; the emitter
/// resolves it to the static method below at codegen time.
///
/// Path-finder scope:
///   - Binds an HttpListener on `(host, port)`.
///   - Responds to every request with a 200 OK + JSON description of
///     the registered routing table (route methods / patterns / handler
///     names / summaries) so callers can verify the listener is alive
///     and the routes were forwarded correctly.
///   - Blocks the calling thread until the listener is stopped (matches
///     ASP.NET Core's `host.Run()` semantics — only Ctrl-C / SIGTERM
///     can stop it).
///   - Background workers (`workerNames` / `workerIntervals` /
///     `workerHandlers`) are intentionally not invoked because real
///     dispatch needs a Lyric-callable bridge.  Their metadata is
///     logged in the JSON response so callers can inspect what would
///     run.

namespace Lyric.Web

open System
open System.IO
open System.Net
open System.Text

/// Minimal JSON-string escaper.
module private JsonHelp =
    let escape (s: string) : string =
        let sb = StringBuilder()
        sb.Append('"') |> ignore
        for c in s do
            match c with
            | '\\' -> sb.Append("\\\\") |> ignore
            | '"'  -> sb.Append("\\\"") |> ignore
            | '\n' -> sb.Append("\\n")  |> ignore
            | '\r' -> sb.Append("\\r")  |> ignore
            | '\t' -> sb.Append("\\t")  |> ignore
            | _    -> sb.Append(c)      |> ignore
        sb.Append('"') |> ignore
        sb.ToString()

    let arr (xs: seq<string>) : string =
        let escaped = xs |> Seq.map escape |> String.concat ","
        sprintf "[%s]" escaped

    let intArr (xs: seq<int>) : string =
        sprintf "[%s]" (xs |> Seq.map string |> String.concat ",")

[<Sealed; AbstractClass>]
type HttpListenerHost private () =

    /// Bind an HttpListener on `(host, port)` and serve until killed.
    ///
    /// Phase-8 path-finder: every request returns a 200 OK with a JSON
    /// payload describing the routing table; the listener actually binds
    /// the port (so `netstat -tnlp | grep :port` confirms it's alive),
    /// fixing the silent no-op behaviour from #784.
    static member serve(host: string, port: int, swaggerEnabled: bool,
                         specPath: string, corsEnabled: bool,
                         corsOrigins: string, corsMethods: string,
                         corsHeaders: string, corsMaxAge: int,
                         routeMethods:    string[],
                         routePatterns:   string[],
                         routeHandlers:   string[],
                         routeSummaries:  string[],
                         workerNames:     string[],
                         workerIntervals: int[],
                         workerHandlers:  string[]) : unit =
        if String.IsNullOrEmpty(host) || port < 1 || port > 65535 then
            // Match the kernel's `requires:` clauses: host non-empty,
            // port in range.  Run-the-listener semantics make a failed
            // bind a hard exit, but the precondition guards prevent
            // calling with garbage from upstream.
            failwith "Lyric.Web.HttpListenerHost.serve: invalid host/port"
        let listener = new HttpListener()
        // HttpListener prefix syntax: "http://+:port/" matches all hostnames.
        // "+" requires elevation on Windows; for path-finder use, bind to
        // localhost if the supplied host is "127.0.0.1" / "localhost" /
        // "0.0.0.0", else use the supplied hostname.
        let bindHost =
            match host with
            | "0.0.0.0" | "+" | "*" -> "+"
            | _ -> host
        let prefix = sprintf "http://%s:%d/" bindHost port
        listener.Prefixes.Add(prefix)
        let payload =
            sprintf "{\"lyric-web\":\"phase-8-pathfinder\",\"host\":%s,\"port\":%d,\"swagger\":%b,\"specPath\":%s,\"cors\":%b,\"routes\":{\"methods\":%s,\"patterns\":%s,\"handlers\":%s,\"summaries\":%s},\"workers\":{\"names\":%s,\"intervals\":%s,\"handlers\":%s}}"
                (JsonHelp.escape host) port swaggerEnabled (JsonHelp.escape specPath)
                corsEnabled
                (JsonHelp.arr routeMethods) (JsonHelp.arr routePatterns)
                (JsonHelp.arr routeHandlers) (JsonHelp.arr routeSummaries)
                (JsonHelp.arr workerNames) (JsonHelp.intArr workerIntervals)
                (JsonHelp.arr workerHandlers)
        try
            listener.Start()
            // Serve requests forever.  Single-thread sync loop is fine
            // for path-finder; production Kestrel does proper async I/O.
            let mutable running = true
            while running do
                try
                    let ctx = listener.GetContext()
                    let resp = ctx.Response
                    resp.StatusCode <- 200
                    resp.ContentType <- "application/json"
                    let bytes = Encoding.UTF8.GetBytes(payload: string)
                    resp.ContentLength64 <- int64 bytes.Length
                    resp.OutputStream.Write(bytes, 0, bytes.Length)
                    resp.OutputStream.Close()
                with
                | :? HttpListenerException -> running <- false
                | :? System.ObjectDisposedException -> running <- false
                | _ -> ()  // log + continue in a real server
        finally
            try listener.Close() with _ -> ()
