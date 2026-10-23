// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.util.Map;
import java.util.function.BiFunction;

/** The grants the host gave this plugin, and the connection to call it on. */
public final class PluginContext {
    private final PluginServer server;
    private final Map<String, Json.Value> grants;

    PluginContext(PluginServer server, Map<String, Json.Value> grants) {
        this.server = server;
        this.grants = grants;
    }

    public boolean isGranted(String capability) { return grants.containsKey(capability); }

    /** The grant value of a granted capability ({@code null} JSON when it has no grant type). */
    public Json.Value grantOf(String capability) {
        Json.Value g = grants.get(capability);
        return g == null ? Json.NULL : g;
    }

    /** Calls the host and returns the JSON-RPC result or the boundary error the host answered. */
    public Result<Json.Value, BoundaryError> callHost(String method, Json.Obj params) {
        return server.call(method, params);
    }

    /** Calls method {@code method} of capability {@code capability}. */
    public <T, E> Result<T, CallError<E>> call(
            String capability,
            String method,
            Json.Obj params,
            BiFunction<Json.Value, String, T> decodeOk,
            BiFunction<Json.Value, String, E> decodeErr) {
        if (!isGranted(capability)) {
            return Result.err(new CallError.Boundary<>(new BoundaryError.NotGranted(capability)));
        }
        Result<Json.Value, BoundaryError> answer = callHost("cap/" + capability + "/" + method, params);
        if (answer instanceof Result.Err<Json.Value, BoundaryError> be) {
            return Result.err(new CallError.Boundary<>(be.error()));
        }
        Json.Value node = ((Result.Ok<Json.Value, BoundaryError>) answer).value();
        try {
            Json.Obj o = Wire.expectObject(node, "result");
            if (o.members().size() == 1 && o.has("ok")) {
                return Result.ok(decodeOk.apply(o.get("ok"), "result.ok"));
            }
            if (o.members().size() == 1 && o.has("err")) {
                return Result.err(new CallError.App<>(decodeErr.apply(o.get("err"), "result.err")));
            }
            throw new ProtocolException("result: expected {\"ok\": ...} or {\"err\": ...}");
        } catch (ProtocolException e) {
            return Result.err(new CallError.Boundary<>(new BoundaryError.Protocol(e.getMessage())));
        }
    }
}
