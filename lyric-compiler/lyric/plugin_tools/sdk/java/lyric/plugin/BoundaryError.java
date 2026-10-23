// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** A failure of the boundary itself rather than of the method (D207 Decision 7). */
public sealed interface BoundaryError {
    record Denied(String reason) implements BoundaryError {}

    record NotGranted(String capability) implements BoundaryError {}

    record Stale() implements BoundaryError {}

    record Unsupported(String method) implements BoundaryError {}

    record Revoked(String capability) implements BoundaryError {}

    record ContractViolated(String detail) implements BoundaryError {}

    record Timeout(int timeoutMs) implements BoundaryError {}

    record Crashed(String detail) implements BoundaryError {}

    record Protocol(String detail) implements BoundaryError {}
}
