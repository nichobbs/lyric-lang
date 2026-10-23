// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;

/** The process-mode plugin server: the JSON-RPC loop over stdin and stdout (D207 Decision 3). */
public final class PluginServer {
    public static final String MANIFEST_FLAG = "--lyric-plugin-manifest";
    public static final int PROTOCOL_VERSION = 1;

    private static final Json.Obj CLOSED = new Json.Obj();

    private final ManifestBuilder manifest;
    private final Function<PluginContext, List<PointDispatcher>> bind;
    private final BufferedReader input;
    private final OutputStream output;
    private final Object writeLock = new Object();
    private final Map<Long, CompletableFuture<Json.Obj>> pending = new ConcurrentHashMap<>();
    private final Map<String, PointDispatcher> dispatchers = new LinkedHashMap<>();
    private final AtomicLong nextId = new AtomicLong();
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
    private volatile boolean closed;
    private boolean handshakeDone;

    private PluginServer(ManifestBuilder manifest, Function<PluginContext, List<PointDispatcher>> bind, BufferedReader input, OutputStream output) {
        this.manifest = manifest;
        this.bind = bind;
        this.input = input;
        this.output = output;
    }

    /**
     * The plugin's entry point: answers the manifest probe, or serves the protocol on
     * stdin and stdout until the host shuts the plugin down. Returns the exit code.
     */
    public static int run(String[] args, ManifestBuilder manifest, Function<PluginContext, List<PointDispatcher>> bind) {
        if (args.length == 1 && args[0].equals(MANIFEST_FLAG)) {
            PrintStream out = new PrintStream(System.out, true, StandardCharsets.UTF_8);
            out.print(manifest.toJsonString());
            out.print('\n');
            out.flush();
            return 0;
        }
        if (args.length != 0) {
            System.err.println("a Lyric plugin takes no arguments other than " + MANIFEST_FLAG + "; the host speaks to it on stdin and stdout");
            return 2;
        }
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        return new PluginServer(manifest, bind, in, System.out).serve();
    }

    private int serve() {
        try {
            String line;
            while ((line = input.readLine()) != null) {
                if (line.isBlank()) continue;
                if (!handleLine(line)) break;
            }
        } catch (IOException e) {
            System.err.println("plugin: reading stdin failed: " + e.getMessage());
        }
        closed = true;
        for (Long id : new ArrayList<>(pending.keySet())) {
            CompletableFuture<Json.Obj> waiter = pending.remove(id);
            if (waiter != null) waiter.complete(CLOSED);
        }
        workers.shutdown();
        try {
            workers.awaitTermination(Long.MAX_VALUE, TimeUnit.DAYS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return 0;
    }

    private static String stringMember(Json.Obj o, String name) {
        return o.get(name) instanceof Json.Str s ? s.value() : null;
    }

    /** Handles one message; false when the plugin should stop reading. */
    private boolean handleLine(String line) {
        Json.Value msg;
        try {
            msg = Json.parse(line);
        } catch (IllegalArgumentException e) {
            sendError(Json.NULL, Codes.PARSE_ERROR, "parse error: " + e.getMessage(), null);
            return true;
        }
        if (!(msg instanceof Json.Obj o)) {
            sendError(Json.NULL, Codes.INVALID_REQUEST, "a message must be a JSON object", null);
            return true;
        }
        boolean hasId = o.has("id");
        Json.Value id = hasId ? o.get("id") : Json.NULL;
        if (o.has("method")) {
            String method = stringMember(o, "method");
            if (method == null) {
                if (hasId) sendError(id, Codes.INVALID_REQUEST, "method must be a string", null);
                return true;
            }
            Json.Value ps = o.has("params") ? o.get("params") : null;
            if (method.equals("plugin/shutdown")) return false;
            if (!handshakeDone) {
                if (method.equals("plugin/hello") && hasId) hello(id, ps);
                else if (hasId) sendError(id, Codes.PROTOCOL, "the plugin/hello handshake must come first", null);
                return true;
            }
            if (method.equals("plugin/hello")) {
                if (hasId) sendError(id, Codes.PROTOCOL, "the handshake has already completed", null);
                return true;
            }
            if (method.equals("$/cancelRequest") || !hasId) return true;
            if (ps != null && !(ps instanceof Json.Obj) && !(ps instanceof Json.Null)) {
                sendError(id, Codes.PROTOCOL, "params must be an object keyed by parameter name", null);
                return true;
            }
            Json.Obj params = ps instanceof Json.Obj po ? po : new Json.Obj();
            workers.submit(() -> call(id, method, params));
            return true;
        }
        if (hasId && (o.has("result") || o.has("error"))) {
            if (id instanceof Json.Num n) {
                try {
                    CompletableFuture<Json.Obj> waiter = pending.remove(Long.parseLong(n.raw()));
                    if (waiter != null) waiter.complete(o);
                } catch (NumberFormatException e) {
                    // Not one of this plugin's request ids: ignored.
                }
            }
            return true;
        }
        if (hasId) sendError(id, Codes.INVALID_REQUEST, "not a JSON-RPC request or response", null);
        return true;
    }

    private void hello(Json.Value id, Json.Value ps) {
        if (!(ps instanceof Json.Obj p)) {
            sendError(id, Codes.PROTOCOL, "plugin/hello params must be an object", null);
            return;
        }
        if (!(p.get("protocol") instanceof Json.Num pn) || !pn.raw().equals(Integer.toString(PROTOCOL_VERSION))) {
            sendError(id, Codes.PROTOCOL, "this plugin speaks protocol " + PROTOCOL_VERSION, null);
            return;
        }
        Map<String, Json.Value> grants = new HashMap<>();
        if (p.get("grants") instanceof Json.Arr ga) {
            for (Json.Value g : ga.items()) {
                if (g instanceof Json.Obj go && go.get("capability") instanceof Json.Str cap) {
                    grants.put(cap.value(), go.has("grant") ? go.get("grant") : Json.NULL);
                } else {
                    sendError(id, Codes.PROTOCOL, "each grant must be {\"capability\": <name>, \"grant\": <value>}", null);
                    return;
                }
            }
        }
        for (String need : manifest.requiredCapabilities()) {
            if (!grants.containsKey(need)) {
                sendError(id, Codes.NOT_GRANTED, "the required capability " + need + " was not granted", new Json.Obj().put("capability", Json.str(need)));
                return;
            }
        }
        PluginContext ctx = new PluginContext(this, grants);
        try {
            for (PointDispatcher d : bind.apply(ctx)) dispatchers.put(d.pointId(), d);
        } catch (RuntimeException e) {
            sendError(id, Codes.INTERNAL_ERROR, "the plugin failed to start: " + e.getMessage(), null);
            return;
        }
        Json.Obj points = new Json.Obj();
        for (PointDispatcher d : dispatchers.values()) {
            Json.Arr methods = new Json.Arr();
            for (String m : d.methods()) methods.items().add(Json.str(m));
            points.put(d.pointId(), new Json.Obj().put("version", Json.str(d.version())).put("methods", methods));
        }
        handshakeDone = true;
        sendResult(id, new Json.Obj().put("protocol", Json.Num.of(PROTOCOL_VERSION)).put("id", Json.str(manifest.id())).put("points", points));
    }

    private void call(Json.Value id, String method, Json.Obj params) {
        int slash = method.lastIndexOf('/');
        PointDispatcher d = slash > 0 ? dispatchers.get(method.substring(0, slash)) : null;
        if (d == null) {
            sendError(id, Codes.UNSUPPORTED, "this plugin does not implement " + method, new Json.Obj().put("method", Json.str(method)));
            return;
        }
        try {
            sendResult(id, d.dispatch(method.substring(slash + 1), params));
        } catch (ProtocolException e) {
            sendError(id, Codes.PROTOCOL, e.getMessage(), null);
        } catch (RpcException e) {
            sendError(id, e.code(), e.getMessage(), e.data());
        } catch (RuntimeException e) {
            sendError(id, Codes.INTERNAL_ERROR, "the plugin failed: " + e.getClass().getSimpleName() + ": " + e.getMessage(), null);
        }
    }

    Result<Json.Value, BoundaryError> call(String method, Json.Obj params) {
        if (closed) return Result.err(new BoundaryError.Crashed("the host closed the connection"));
        long id = nextId.incrementAndGet();
        CompletableFuture<Json.Obj> waiter = new CompletableFuture<>();
        pending.put(id, waiter);
        send(new Json.Obj().put("jsonrpc", Json.str("2.0")).put("id", Json.Num.of(id)).put("method", Json.str(method)).put("params", params));
        if (closed && pending.remove(id) != null) return Result.err(new BoundaryError.Crashed("the host closed the connection"));
        Json.Obj response;
        try {
            response = waiter.get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Result.err(new BoundaryError.Crashed("interrupted while waiting for the host"));
        } catch (ExecutionException e) {
            return Result.err(new BoundaryError.Crashed(e.getMessage()));
        }
        if (response == CLOSED) return Result.err(new BoundaryError.Crashed("the host closed the connection"));
        if (response.has("error")) return Result.err(toBoundaryError(response.get("error"), method));
        return Result.ok(response.has("result") ? response.get("result") : Json.NULL);
    }

    private static BoundaryError toBoundaryError(Json.Value error, String method) {
        Json.Obj o = error instanceof Json.Obj eo ? eo : new Json.Obj();
        long code = 0;
        if (o.get("code") instanceof Json.Num n) {
            try {
                code = Long.parseLong(n.raw());
            } catch (NumberFormatException e) {
                code = 0;
            }
        }
        String message = o.get("message") instanceof Json.Str s ? s.value() : "";
        Json.Obj data = o.get("data") instanceof Json.Obj d ? d : new Json.Obj();
        String capability = data.get("capability") instanceof Json.Str c ? c.value() : message;
        if (code == Codes.TIMEOUT) {
            int ms = 0;
            if (data.get("timeoutMs") instanceof Json.Num t) {
                try {
                    ms = Integer.parseInt(t.raw());
                } catch (NumberFormatException e) {
                    ms = 0;
                }
            }
            return new BoundaryError.Timeout(ms);
        }
        if (code == Codes.DENIED) return new BoundaryError.Denied(message);
        if (code == Codes.NOT_GRANTED) return new BoundaryError.NotGranted(capability);
        if (code == Codes.STALE) return new BoundaryError.Stale();
        if (code == Codes.UNSUPPORTED) return new BoundaryError.Unsupported(data.get("method") instanceof Json.Str m ? m.value() : method);
        if (code == Codes.REVOKED) return new BoundaryError.Revoked(capability);
        if (code == Codes.CONTRACT_VIOLATED) return new BoundaryError.ContractViolated(message);
        if (code == Codes.PROTOCOL) return new BoundaryError.Protocol(message);
        return new BoundaryError.Protocol("the host answered error " + code + ": " + message);
    }

    private void sendResult(Json.Value id, Json.Value value) {
        send(new Json.Obj().put("jsonrpc", Json.str("2.0")).put("id", id).put("result", value));
    }

    private void sendError(Json.Value id, int code, String message, Json.Value data) {
        Json.Obj error = new Json.Obj().put("code", Json.Num.of(code)).put("message", Json.str(message));
        if (data != null) error.put("data", data);
        send(new Json.Obj().put("jsonrpc", Json.str("2.0")).put("id", id).put("error", error));
    }

    private void send(Json.Obj message) {
        byte[] bytes = (Json.write(message) + "\n").getBytes(StandardCharsets.UTF_8);
        synchronized (writeLock) {
            try {
                output.write(bytes);
                output.flush();
            } catch (IOException e) {
                closed = true;
            }
        }
    }
}
