// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** The JSON-RPC error codes of the plugin protocol (D207 Decision 3). */
public final class Codes {
    private Codes() {}

    public static final int PARSE_ERROR = -32700;
    public static final int INVALID_REQUEST = -32600;
    public static final int INTERNAL_ERROR = -32603;
    public static final int TIMEOUT = -32001;
    public static final int DENIED = -32040;
    public static final int NOT_GRANTED = -32041;
    public static final int STALE = -32042;
    public static final int UNSUPPORTED = -32043;
    public static final int REVOKED = -32044;
    public static final int CONTRACT_VIOLATED = -32045;
    public static final int PROTOCOL = -32046;
}
