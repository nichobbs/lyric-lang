// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** A value that does not match its boundary type; answered with {@link Codes#PROTOCOL}. */
public final class ProtocolException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public ProtocolException(String message) {
        super(message);
    }
}
