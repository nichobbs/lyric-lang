// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** The error of a capability call: the method's own error or a boundary error. */
public sealed interface CallError<E> permits CallError.App, CallError.Boundary {
    record App<E>(E error) implements CallError<E> {}

    record Boundary<E>(BoundaryError error) implements CallError<E> {}
}
