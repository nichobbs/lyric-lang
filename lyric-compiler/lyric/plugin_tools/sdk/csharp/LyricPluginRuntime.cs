// Lyric plugin SDK runtime for C# (D207). Written by `lyric plugin sdk`; do not edit.
//
// The process-mode side of the Lyric plugin protocol, version 1: JSON-RPC 2.0
// over stdin and stdout, one message per line, the `plugin/hello` handshake,
// the `--lyric-plugin-manifest` probe, point-call dispatch and capability
// calls back to the host. The generated API file builds on these types.
#nullable enable
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Lyric.Plugin
{
    /// <summary>The Lyric <c>Unit</c> value; encoded as JSON <c>null</c>.</summary>
    public readonly struct Unit : IEquatable<Unit>
    {
        public static readonly Unit Value = default;
        public bool Equals(Unit other) => true;
        public override bool Equals(object? obj) => obj is Unit;
        public override int GetHashCode() => 0;
        public override string ToString() => "()";
    }

    /// <summary>A Lyric <c>Result[T, E]</c>; encoded as <c>{"ok": T}</c> or <c>{"err": E}</c>.</summary>
    public abstract record Result<T, E>
    {
        private Result() { }

        public sealed record Ok(T Value) : Result<T, E>;

        public sealed record Err(E Error) : Result<T, E>;

        public static Result<T, E> Success(T value) => new Ok(value);

        public static Result<T, E> Failure(E error) => new Err(error);

        public bool IsOk => this is Ok;
    }

    /// <summary>A failure of the boundary itself rather than of the method (D207 Decision 7).</summary>
    public abstract record BoundaryError
    {
        private BoundaryError() { }

        public sealed record Denied(string Reason) : BoundaryError;
        public sealed record NotGranted(string Capability) : BoundaryError;
        public sealed record Stale() : BoundaryError;
        public sealed record Unsupported(string Method) : BoundaryError;
        public sealed record Revoked(string Capability) : BoundaryError;
        public sealed record ContractViolated(string Detail) : BoundaryError;
        public sealed record Timeout(int TimeoutMs) : BoundaryError;
        public sealed record Crashed(string Detail) : BoundaryError;
        public sealed record Protocol(string Detail) : BoundaryError;
    }

    /// <summary>The error of a capability call: the method's own error or a boundary error.</summary>
    public abstract record CallError<E>
    {
        private CallError() { }

        public sealed record App(E Error) : CallError<E>;

        public sealed record Boundary(BoundaryError Error) : CallError<E>;
    }

    /// <summary>The JSON-RPC error codes of the plugin protocol (D207 Decision 3).</summary>
    public static class Codes
    {
        public const int ParseError = -32700;
        public const int InvalidRequest = -32600;
        public const int InternalError = -32603;
        public const int Timeout = -32001;
        public const int Denied = -32040;
        public const int NotGranted = -32041;
        public const int Stale = -32042;
        public const int Unsupported = -32043;
        public const int Revoked = -32044;
        public const int ContractViolated = -32045;
        public const int Protocol = -32046;
    }

    /// <summary>A value that does not match its boundary type; answered with <see cref="Codes.Protocol"/>.</summary>
    public sealed class PluginProtocolException : Exception
    {
        public PluginProtocolException(string message) : base(message) { }
    }

    /// <summary>A JSON-RPC error a dispatcher answers with.</summary>
    public sealed class RpcException : Exception
    {
        public RpcException(int code, string message, JsonNode? data = null) : base(message)
        {
            Code = code;
            Data_ = data;
        }

        public int Code { get; }
        public JsonNode? Data_ { get; }
    }

    /// <summary>The encoders and decoders of the scalar boundary types (D207 Decision 4).</summary>
    public static class Wire
    {
        static PluginProtocolException Kind(string path, string expected, JsonNode? j) =>
            new PluginProtocolException(path + ": expected " + expected + ", found " + KindName(j));

        static string KindName(JsonNode? j)
        {
            if (j is null) return "null";
            if (j is JsonObject) return "an object";
            if (j is JsonArray) return "an array";
            return j.GetValueKind() switch
            {
                JsonValueKind.String => "a string",
                JsonValueKind.Number => "a number",
                JsonValueKind.True => "a boolean",
                JsonValueKind.False => "a boolean",
                _ => "a value",
            };
        }

        public static JsonObject ExpectObject(JsonNode? j, string path) =>
            j as JsonObject ?? throw Kind(path, "an object", j);

        public static JsonArray ExpectArray(JsonNode? j, string path) =>
            j as JsonArray ?? throw Kind(path, "an array", j);

        public static JsonArray ExpectTuple(JsonNode? j, string path, int count)
        {
            var a = ExpectArray(j, path);
            if (a.Count != count)
                throw new PluginProtocolException(path + ": expected an array of " + count + " elements, found " + a.Count);
            return a;
        }

        public static bool Has(JsonObject o, string name) => o.ContainsKey(name);

        public static JsonNode? Required(JsonObject o, string name, string path)
        {
            if (!o.TryGetPropertyValue(name, out var v))
                throw new PluginProtocolException(path + ": missing required member \"" + name + "\"");
            return v;
        }

        public static string CaseName(JsonObject o, string path) => DecodeString(Required(o, "case", path), path + ".case");

        public static PluginProtocolException UnknownCase(string path, string typeName, string name) =>
            new PluginProtocolException(path + ": \"" + name + "\" is not a case of " + typeName);

        static JsonElement Number(JsonNode? j, string path, string expected)
        {
            if (j is JsonValue v && v.GetValueKind() == JsonValueKind.Number)
            {
                if (v.TryGetValue<JsonElement>(out var e)) return e;
                return JsonSerializer.SerializeToElement(v);
            }
            throw Kind(path, expected, j);
        }

        public static JsonNode EncodeBool(bool v) => JsonValue.Create(v);

        public static bool DecodeBool(JsonNode? j, string path)
        {
            if (j is JsonValue v && v.GetValueKind() == JsonValueKind.True) return true;
            if (j is JsonValue w && w.GetValueKind() == JsonValueKind.False) return false;
            throw Kind(path, "a boolean", j);
        }

        public static JsonNode EncodeByte(byte v) => JsonValue.Create(v);

        public static byte DecodeByte(JsonNode? j, string path) =>
            Number(j, path, "a Byte").TryGetByte(out var x) ? x : throw new PluginProtocolException(path + ": not a Byte (0 to 255)");

        public static JsonNode EncodeInt(int v) => JsonValue.Create(v);

        public static int DecodeInt(JsonNode? j, string path) =>
            Number(j, path, "an Int").TryGetInt32(out var x) ? x : throw new PluginProtocolException(path + ": not an Int (a 32-bit integer)");

        public static JsonNode EncodeLong(long v) => JsonValue.Create(v);

        public static long DecodeLong(JsonNode? j, string path) =>
            Number(j, path, "a Long").TryGetInt64(out var x) ? x : throw new PluginProtocolException(path + ": not a Long (a 64-bit integer)");

        public static JsonNode EncodeUInt(uint v) => JsonValue.Create(v);

        public static uint DecodeUInt(JsonNode? j, string path) =>
            Number(j, path, "a UInt").TryGetUInt32(out var x) ? x : throw new PluginProtocolException(path + ": not a UInt (0 to 4294967295)");

        public static JsonNode EncodeULong(ulong v) => JsonValue.Create(v);

        public static ulong DecodeULong(JsonNode? j, string path) =>
            Number(j, path, "a ULong").TryGetUInt64(out var x) ? x : throw new PluginProtocolException(path + ": not a ULong (0 to 18446744073709551615)");

        public static JsonNode EncodeFloat(float v) =>
            float.IsFinite(v) ? JsonValue.Create(v) : throw new PluginProtocolException("a non-finite Float cannot be encoded as JSON");

        public static float DecodeFloat(JsonNode? j, string path) =>
            Number(j, path, "a Float").TryGetSingle(out var x) && float.IsFinite(x) ? x : throw new PluginProtocolException(path + ": not a Float");

        public static JsonNode EncodeDouble(double v) =>
            double.IsFinite(v) ? JsonValue.Create(v) : throw new PluginProtocolException("a non-finite Double cannot be encoded as JSON");

        public static double DecodeDouble(JsonNode? j, string path) =>
            Number(j, path, "a Double").TryGetDouble(out var x) && double.IsFinite(x) ? x : throw new PluginProtocolException(path + ": not a Double");

        public static JsonNode EncodeChar(char v) => JsonValue.Create(v.ToString());

        public static char DecodeChar(JsonNode? j, string path)
        {
            var s = DecodeString(j, path);
            if (s.Length != 1 || char.IsSurrogate(s[0]))
                throw new PluginProtocolException(path + ": expected a one-character string");
            return s[0];
        }

        public static JsonNode EncodeString(string v) => JsonValue.Create(v ?? throw new PluginProtocolException("a String must not be null"));

        public static string DecodeString(JsonNode? j, string path)
        {
            if (j is JsonValue v && v.GetValueKind() == JsonValueKind.String) return v.GetValue<string>();
            throw Kind(path, "a string", j);
        }

        public static JsonNode? EncodeUnit(Unit v) => null;

        public static Unit DecodeUnit(JsonNode? j, string path) =>
            j is null ? Unit.Value : throw Kind(path, "null", j);

        public static JsonNode EncodeBytes(byte[] v) => JsonValue.Create(Convert.ToBase64String(v));

        public static byte[] DecodeBytes(JsonNode? j, string path)
        {
            var s = DecodeString(j, path);
            try { return Convert.FromBase64String(s); }
            catch (FormatException) { throw new PluginProtocolException(path + ": not a base64 string"); }
        }

        public static JsonNode? EncodeJson(JsonNode? v) => v?.DeepClone();

        public static JsonNode? DecodeJson(JsonNode? j, string path) => j?.DeepClone();
    }

    /// <summary>A JSON-RPC peer's view of the host connection.</summary>
    public sealed class PluginConnection
    {
        private readonly PluginServer server;

        internal PluginConnection(PluginServer server) { this.server = server; }

        /// <summary>Calls the host and returns the JSON-RPC result or the boundary error the host answered.</summary>
        public Result<JsonNode?, BoundaryError> CallHost(string method, JsonObject parameters) => server.Call(method, parameters);
    }

    /// <summary>The grants the host gave this plugin, and the connection to call it on.</summary>
    public sealed class PluginContext
    {
        private readonly Dictionary<string, JsonNode?> grants;

        internal PluginContext(PluginConnection connection, Dictionary<string, JsonNode?> grants)
        {
            Connection = connection;
            this.grants = grants;
        }

        public PluginConnection Connection { get; }

        public bool IsGranted(string capability) => grants.ContainsKey(capability);

        /// <summary>The grant value of a granted capability (null when it has no grant type).</summary>
        public JsonNode? GrantOf(string capability) => grants.TryGetValue(capability, out var g) ? g?.DeepClone() : null;

        /// <summary>Calls method <paramref name="method"/> of capability <paramref name="capability"/>.</summary>
        public Result<T, CallError<E>> Call<T, E>(
            string capability,
            string method,
            JsonObject parameters,
            Func<JsonNode?, string, T> decodeOk,
            Func<JsonNode?, string, E> decodeErr)
        {
            if (!IsGranted(capability))
                return Result<T, CallError<E>>.Failure(new CallError<E>.Boundary(new BoundaryError.NotGranted(capability)));
            var answer = Connection.CallHost("cap/" + capability + "/" + method, parameters);
            if (answer is Result<JsonNode?, BoundaryError>.Err be)
                return Result<T, CallError<E>>.Failure(new CallError<E>.Boundary(be.Error));
            var node = ((Result<JsonNode?, BoundaryError>.Ok)answer).Value;
            try
            {
                var o = Wire.ExpectObject(node, "result");
                if (o.Count == 1 && o.TryGetPropertyValue("ok", out var ok))
                    return Result<T, CallError<E>>.Success(decodeOk(ok, "result.ok"));
                if (o.Count == 1 && o.TryGetPropertyValue("err", out var err))
                    return Result<T, CallError<E>>.Failure(new CallError<E>.App(decodeErr(err, "result.err")));
                throw new PluginProtocolException("result: expected {\"ok\": ...} or {\"err\": ...}");
            }
            catch (PluginProtocolException e)
            {
                return Result<T, CallError<E>>.Failure(new CallError<E>.Boundary(new BoundaryError.Protocol(e.Message)));
            }
        }
    }

    /// <summary>The plugin side of one plugin point: generated per point.</summary>
    public interface IPointDispatcher
    {
        string PointId { get; }
        string Version { get; }
        IReadOnlyList<string> Methods { get; }

        /// <summary>Runs <paramref name="method"/> and returns <c>{"ok": ...}</c> or <c>{"err": ...}</c>.</summary>
        JsonNode Dispatch(string method, JsonObject? parameters);
    }

    /// <summary>Builds the plugin manifest (D207 Decision 5) the probe prints.</summary>
    public sealed class ManifestBuilder
    {
        private readonly List<JsonObject> points = new();
        private readonly List<JsonObject> required = new();
        private readonly List<JsonObject> optional = new();
        private readonly List<JsonObject> payloads = new();

        public ManifestBuilder(string id, string version, string publisher)
        {
            Id = id;
            Version = version;
            Publisher = publisher;
        }

        public string Id { get; }
        public string Version { get; }
        public string Publisher { get; }

        public IEnumerable<string> RequiredCapabilities => required.Select(r => r["name"]!.GetValue<string>());

        public ManifestBuilder Point(string point, string version, JsonNode? contributions)
        {
            points.Add(new JsonObject { ["point"] = point, ["version"] = version, ["contributions"] = contributions });
            return this;
        }

        public ManifestBuilder Require(string capability, JsonNode? grant)
        {
            required.Add(new JsonObject { ["name"] = capability, ["grant"] = grant });
            return this;
        }

        public ManifestBuilder Optional(string capability, JsonNode? grant)
        {
            optional.Add(new JsonObject { ["name"] = capability, ["grant"] = grant });
            return this;
        }

        public ManifestBuilder DotnetPayload(string dll) => Payload(new JsonObject
        {
            ["mode"] = "process",
            ["runtime"] = "dotnet",
            ["command"] = new JsonArray("dotnet", "exec", dll),
        });

        public ManifestBuilder JvmPayload(string jar) => Payload(new JsonObject
        {
            ["mode"] = "process",
            ["runtime"] = "jvm",
            ["command"] = new JsonArray("java", "-jar", jar),
        });

        public ManifestBuilder NativePayload(string os, string arch, params string[] command) => Payload(new JsonObject
        {
            ["mode"] = "process",
            ["os"] = os,
            ["arch"] = arch,
            ["command"] = new JsonArray(command.Select(c => (JsonNode?)JsonValue.Create(c)).ToArray()),
        });

        public ManifestBuilder WasmPayload(string module) => Payload(new JsonObject { ["mode"] = "wasm", ["module"] = module });

        private ManifestBuilder Payload(JsonObject p)
        {
            payloads.Add(p);
            return this;
        }

        public JsonObject ToJson()
        {
            var caps = new JsonObject
            {
                ["required"] = new JsonArray(required.Select(r => (JsonNode?)r.DeepClone()).ToArray()),
                ["optional"] = new JsonArray(optional.Select(r => (JsonNode?)r.DeepClone()).ToArray()),
            };
            var o = new JsonObject
            {
                ["schema"] = 1,
                ["id"] = Id,
                ["version"] = Version,
                ["publisher"] = Publisher,
                ["points"] = new JsonArray(points.Select(p => (JsonNode?)p.DeepClone()).ToArray()),
                ["capabilities"] = caps,
            };
            if (payloads.Count > 0)
                o["payloads"] = new JsonArray(payloads.Select(p => (JsonNode?)p.DeepClone()).ToArray());
            return o;
        }

        public string ToJsonString() => ToJson().ToJsonString();
    }

    /// <summary>The process-mode plugin server: the JSON-RPC loop over stdin and stdout.</summary>
    public sealed class PluginServer
    {
        public const string ManifestFlag = "--lyric-plugin-manifest";
        public const int ProtocolVersion = 1;

        private readonly ManifestBuilder manifest;
        private readonly Func<PluginContext, IEnumerable<IPointDispatcher>> bind;
        private readonly TextReader input;
        private readonly TextWriter output;
        private readonly object writeLock = new();
        private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonObject>> pending = new();
        private readonly List<Task> inFlight = new();
        private readonly Dictionary<string, IPointDispatcher> dispatchers = new();
        private long nextId;
        private volatile bool closed;
        private bool handshakeDone;

        private PluginServer(ManifestBuilder manifest, Func<PluginContext, IEnumerable<IPointDispatcher>> bind, TextReader input, TextWriter output)
        {
            this.manifest = manifest;
            this.bind = bind;
            this.input = input;
            this.output = output;
        }

        /// <summary>
        /// The plugin's entry point: answers the manifest probe, or serves the protocol on
        /// stdin and stdout until the host shuts the plugin down. Returns the exit code.
        /// </summary>
        public static int Run(string[] args, ManifestBuilder manifest, Func<PluginContext, IEnumerable<IPointDispatcher>> bind)
        {
            var utf8 = new UTF8Encoding(false);
            if (args.Length == 1 && args[0] == ManifestFlag)
            {
                using var stdout = new StreamWriter(Console.OpenStandardOutput(), utf8);
                stdout.Write(manifest.ToJsonString());
                stdout.Write('\n');
                return 0;
            }
            if (args.Length != 0)
            {
                Console.Error.WriteLine("a Lyric plugin takes no arguments other than " + ManifestFlag + "; the host speaks to it on stdin and stdout");
                return 2;
            }
            var reader = new StreamReader(Console.OpenStandardInput(), utf8);
            var writer = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = false, NewLine = "\n" };
            return new PluginServer(manifest, bind, reader, writer).Serve();
        }

        private int Serve()
        {
            string? line;
            while ((line = input.ReadLine()) != null)
            {
                if (line.Trim().Length == 0) continue;
                if (!HandleLine(line)) break;
            }
            closed = true;
            foreach (var entry in pending)
            {
                if (pending.TryRemove(entry.Key, out var waiter))
                    waiter.TrySetResult(ErrorObject(Codes.InternalError, "the host closed the connection"));
            }
            Task[] running;
            lock (inFlight) running = inFlight.ToArray();
            Task.WaitAll(running);
            lock (writeLock) output.Flush();
            return 0;
        }

        private static JsonObject ErrorObject(int code, string message) =>
            new JsonObject { ["error"] = new JsonObject { ["code"] = code, ["message"] = message }, ["crashed"] = true };

        /// <summary>Handles one message; false when the plugin should stop reading.</summary>
        private bool HandleLine(string line)
        {
            JsonNode? msg;
            try { msg = JsonNode.Parse(line); }
            catch (JsonException e)
            {
                SendError(null, Codes.ParseError, "parse error: " + e.Message, null);
                return true;
            }
            if (msg is not JsonObject o)
            {
                SendError(null, Codes.InvalidRequest, "a message must be a JSON object", null);
                return true;
            }
            var hasId = o.TryGetPropertyValue("id", out var id);
            if (o.TryGetPropertyValue("method", out var methodNode))
            {
                if (methodNode is not JsonValue mv || mv.GetValueKind() != JsonValueKind.String)
                {
                    if (hasId) SendError(id, Codes.InvalidRequest, "method must be a string", null);
                    return true;
                }
                var method = mv.GetValue<string>();
                o.TryGetPropertyValue("params", out var ps);
                if (method == "plugin/shutdown") return false;
                if (!handshakeDone)
                {
                    if (method == "plugin/hello" && hasId) Hello(id, ps);
                    else if (hasId) SendError(id, Codes.Protocol, "the plugin/hello handshake must come first", null);
                    return true;
                }
                if (method == "plugin/hello")
                {
                    if (hasId) SendError(id, Codes.Protocol, "the handshake has already completed", null);
                    return true;
                }
                if (method == "$/cancelRequest" || !hasId) return true;
                var callId = id?.DeepClone();
                var paramsObj = ps as JsonObject;
                if (ps is not null && paramsObj is null)
                {
                    SendError(callId, Codes.Protocol, "params must be an object keyed by parameter name", null);
                    return true;
                }
                var task = Task.Run(() => Call(callId, method, (JsonObject?)paramsObj?.DeepClone()));
                lock (inFlight)
                {
                    inFlight.RemoveAll(t => t.IsCompleted);
                    inFlight.Add(task);
                }
                return true;
            }
            if (hasId && (o.ContainsKey("result") || o.ContainsKey("error")))
            {
                if (id is JsonValue iv && iv.TryGetValue<long>(out var n) && pending.TryRemove(n, out var waiter))
                    waiter.TrySetResult(o);
                return true;
            }
            if (hasId) SendError(id, Codes.InvalidRequest, "not a JSON-RPC request or response", null);
            return true;
        }

        private void Hello(JsonNode? id, JsonNode? ps)
        {
            var callId = id?.DeepClone();
            if (ps is not JsonObject p)
            {
                SendError(callId, Codes.Protocol, "plugin/hello params must be an object", null);
                return;
            }
            if (!p.TryGetPropertyValue("protocol", out var proto) || proto is not JsonValue pv || !pv.TryGetValue<long>(out var pn) || pn != ProtocolVersion)
            {
                SendError(callId, Codes.Protocol, "this plugin speaks protocol " + ProtocolVersion, null);
                return;
            }
            var grants = new Dictionary<string, JsonNode?>();
            if (p.TryGetPropertyValue("grants", out var gs) && gs is JsonArray ga)
            {
                foreach (var g in ga)
                {
                    if (g is JsonObject go && go.TryGetPropertyValue("capability", out var cap) && cap is JsonValue cv && cv.GetValueKind() == JsonValueKind.String)
                    {
                        go.TryGetPropertyValue("grant", out var grant);
                        grants[cv.GetValue<string>()] = grant?.DeepClone();
                    }
                    else
                    {
                        SendError(callId, Codes.Protocol, "each grant must be {\"capability\": <name>, \"grant\": <value>}", null);
                        return;
                    }
                }
            }
            foreach (var need in manifest.RequiredCapabilities)
            {
                if (!grants.ContainsKey(need))
                {
                    SendError(callId, Codes.NotGranted, "the required capability " + need + " was not granted", new JsonObject { ["capability"] = need });
                    return;
                }
            }
            var ctx = new PluginContext(new PluginConnection(this), grants);
            try
            {
                foreach (var d in bind(ctx)) dispatchers[d.PointId] = d;
            }
            catch (Exception e)
            {
                SendError(callId, Codes.InternalError, "the plugin failed to start: " + e.Message, null);
                return;
            }
            var points = new JsonObject();
            foreach (var d in dispatchers.Values)
            {
                points[d.PointId] = new JsonObject
                {
                    ["version"] = d.Version,
                    ["methods"] = new JsonArray(d.Methods.Select(m => (JsonNode?)JsonValue.Create(m)).ToArray()),
                };
            }
            handshakeDone = true;
            SendResult(callId, new JsonObject { ["protocol"] = ProtocolVersion, ["id"] = manifest.Id, ["points"] = points });
        }

        private void Call(JsonNode? id, string method, JsonObject? ps)
        {
            var slash = method.LastIndexOf('/');
            var point = slash > 0 ? method.Substring(0, slash) : "";
            if (slash <= 0 || !dispatchers.TryGetValue(point, out var d))
            {
                SendError(id, Codes.Unsupported, "this plugin does not implement " + method, new JsonObject { ["method"] = method });
                return;
            }
            try
            {
                SendResult(id, d.Dispatch(method.Substring(slash + 1), ps));
            }
            catch (PluginProtocolException e)
            {
                SendError(id, Codes.Protocol, e.Message, null);
            }
            catch (RpcException e)
            {
                SendError(id, e.Code, e.Message, e.Data_);
            }
            catch (Exception e)
            {
                SendError(id, Codes.InternalError, "the plugin failed: " + e.GetType().Name + ": " + e.Message, null);
            }
        }

        internal Result<JsonNode?, BoundaryError> Call(string method, JsonObject parameters)
        {
            if (closed)
                return Result<JsonNode?, BoundaryError>.Failure(new BoundaryError.Crashed("the host closed the connection"));
            var id = Interlocked.Increment(ref nextId);
            var waiter = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
            pending[id] = waiter;
            Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters.DeepClone() });
            if (closed && pending.TryRemove(id, out _))
                return Result<JsonNode?, BoundaryError>.Failure(new BoundaryError.Crashed("the host closed the connection"));
            var response = waiter.Task.GetAwaiter().GetResult();
            if (response.ContainsKey("crashed"))
                return Result<JsonNode?, BoundaryError>.Failure(new BoundaryError.Crashed("the host closed the connection"));
            if (response.TryGetPropertyValue("error", out var error))
                return Result<JsonNode?, BoundaryError>.Failure(ToBoundaryError(error, method));
            response.TryGetPropertyValue("result", out var value);
            return Result<JsonNode?, BoundaryError>.Success(value?.DeepClone());
        }

        private static BoundaryError ToBoundaryError(JsonNode? error, string method)
        {
            var o = error as JsonObject;
            var code = 0L;
            if (o is not null && o.TryGetPropertyValue("code", out var c) && c is JsonValue cv) cv.TryGetValue<long>(out code);
            var message = o is not null && o.TryGetPropertyValue("message", out var m) && m is JsonValue mv && mv.GetValueKind() == JsonValueKind.String ? mv.GetValue<string>() : "";
            var data = o is not null && o.TryGetPropertyValue("data", out var dn) ? dn as JsonObject : null;
            string DataString(string key, string fallback) =>
                data is not null && data.TryGetPropertyValue(key, out var v) && v is JsonValue sv && sv.GetValueKind() == JsonValueKind.String ? sv.GetValue<string>() : fallback;
            switch (code)
            {
                case Codes.Timeout:
                    var ms = 0;
                    if (data is not null && data.TryGetPropertyValue("timeoutMs", out var t) && t is JsonValue tv) tv.TryGetValue<int>(out ms);
                    return new BoundaryError.Timeout(ms);
                case Codes.Denied: return new BoundaryError.Denied(message);
                case Codes.NotGranted: return new BoundaryError.NotGranted(DataString("capability", message));
                case Codes.Stale: return new BoundaryError.Stale();
                case Codes.Unsupported: return new BoundaryError.Unsupported(DataString("method", method));
                case Codes.Revoked: return new BoundaryError.Revoked(DataString("capability", message));
                case Codes.ContractViolated: return new BoundaryError.ContractViolated(message);
                case Codes.Protocol: return new BoundaryError.Protocol(message);
                default: return new BoundaryError.Protocol("the host answered error " + code.ToString(CultureInfo.InvariantCulture) + ": " + message);
            }
        }

        private void SendResult(JsonNode? id, JsonNode? value) =>
            Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["result"] = value });

        private void SendError(JsonNode? id, int code, string message, JsonNode? data)
        {
            var error = new JsonObject { ["code"] = code, ["message"] = message };
            if (data is not null) error["data"] = data.DeepClone();
            Send(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = error });
        }

        private void Send(JsonObject message)
        {
            var text = message.ToJsonString();
            lock (writeLock)
            {
                output.Write(text);
                output.Write('\n');
                output.Flush();
            }
        }
    }
}
