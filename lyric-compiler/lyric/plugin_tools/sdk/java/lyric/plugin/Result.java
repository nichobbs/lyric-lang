// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** A Lyric {@code Result[T, E]}; encoded as {@code {"ok": T}} or {@code {"err": E}}. */
public sealed interface Result<T, E> permits Result.Ok, Result.Err {
    record Ok<T, E>(T value) implements Result<T, E> {}

    record Err<T, E>(E error) implements Result<T, E> {}

    static <T, E> Result<T, E> ok(T value) { return new Ok<>(value); }

    static <T, E> Result<T, E> err(E error) { return new Err<>(error); }

    default boolean isOk() { return this instanceof Ok; }
}
