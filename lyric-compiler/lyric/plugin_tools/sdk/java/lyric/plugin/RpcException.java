// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** A JSON-RPC error a dispatcher answers with. */
public final class RpcException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final int code;
    private final transient Json.Value data;

    public RpcException(int code, String message, Json.Value data) {
        super(message);
        this.code = code;
        this.data = data;
    }

    public int code() { return code; }

    public Json.Value data() { return data; }
}
