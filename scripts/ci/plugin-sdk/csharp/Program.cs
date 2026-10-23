// A plugin for the Demo.Api sample package, written against the C# SDK that
// `lyric plugin sdk --lang csharp` generates (scripts/ci/plugin-sdk-e2e.sh).
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Nodes;
using Demo.Api;
using Lyric.Plugin;

public sealed class DemoGreeter : IGreeter
{
    private readonly FilesClient files;
    private readonly NotifyClient notify;

    public DemoGreeter(PluginContext context)
    {
        files = new FilesClient(context);
        notify = new NotifyClient(context);
    }

    public Result<Greeting, GreetError> Greet(string name, int times)
    {
        if (name.Length == 0) return Result<Greeting, GreetError>.Failure(new GreetError.BadName(name));
        return Result<Greeting, GreetError>.Success(new Greeting
        {
            Text = "hello " + name,
            Count = times,
            Big = 9007199254740993L,
            Huge = ulong.MaxValue,
            Ratio = 0.5F,
            Initial = name[0],
            Tags = new List<string> { "a", "b" },
            Mood = Mood.Happy,
            Note = null,
            Data = new byte[] { 0, 1, 255 },
            Scores = new Dictionary<string, long> { ["min"] = long.MinValue },
            Pair = (times, name),
            Extra = JsonNode.Parse("{\"k\":[1,2.5,\"s\",null,true]}"),
            Shapes = new List<Shape> { new Shape.Circle(1.5), new Shape.Rect(2, 3), new Shape.Empty() },
        });
    }

    public Result<double, GreetError> Area(Shape s) => s switch
    {
        Shape.Circle c => Result<double, GreetError>.Success(3.0 * c.Radius * c.Radius),
        Shape.Rect r => Result<double, GreetError>.Success(r.W * r.H),
        _ => Result<double, GreetError>.Success(0),
    };

    public Result<List<DocRef>, GreetError> Open(DocRef doc, Dictionary<string, long> counts) =>
        Result<List<DocRef>, GreetError>.Success(new List<DocRef> { doc, new DocRef(doc.Value + counts.Values.Sum()) });

    public Result<Greeting, GreetError> Echo(Greeting g) => Result<Greeting, GreetError>.Success(g);

    public Result<string, GreetError> ReadVia(string path)
    {
        var shown = notify.Show("reading " + path, 1);
        if (shown is not Result<Unit, CallError<GreetError>>.Err { Error: CallError<GreetError>.Boundary { Error: BoundaryError.NotGranted } })
            return Result<string, GreetError>.Failure(new GreetError.Failed("Notify should not be granted"));
        if (files.Grant is not { } grant || grant.Roots.Count != 1)
            return Result<string, GreetError>.Failure(new GreetError.Failed("the Files grant is missing"));
        return files.ReadFile(path) switch
        {
            Result<string, CallError<GreetError>>.Ok ok => Result<string, GreetError>.Success(ok.Value + " (root " + grant.Roots[0] + ")"),
            Result<string, CallError<GreetError>>.Err { Error: CallError<GreetError>.App app } => Result<string, GreetError>.Failure(app.Error),
            Result<string, CallError<GreetError>>.Err { Error: CallError<GreetError>.Boundary b } =>
                Result<string, GreetError>.Failure(new GreetError.Failed("boundary: " + b.Error.GetType().Name)),
            _ => throw new InvalidOperationException(),
        };
    }
}

public static class Program
{
    public static int Main(string[] args)
    {
        var manifest = new ManifestBuilder("demo.greeter-csharp", "1.0.0", "lyric-e2e")
            .ImplementGreeter(new GreeterContributions { Commands = new List<string> { "greet" }, Priority = 7 })
            .RequireFiles(new FilesGrant { Roots = new List<string> { "${workspace}" } })
            .OptionalNotify();
        return PluginServer.Run(args, manifest, ctx => new[] { GreeterPoint.Dispatcher(new DemoGreeter(ctx)) });
    }
}
