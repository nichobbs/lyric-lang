// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

/** Lyric tuples; encoded as JSON arrays. */
public final class Tuple {
    private Tuple() {}

    public record Of2<A, B>(A item1, B item2) {}

    public record Of3<A, B, C>(A item1, B item2, C item3) {}

    public record Of4<A, B, C, D>(A item1, B item2, C item3, D item4) {}

    public record Of5<A, B, C, D, E>(A item1, B item2, C item3, D item4, E item5) {}

    public record Of6<A, B, C, D, E, F>(A item1, B item2, C item3, D item4, E item5, F item6) {}

    public record Of7<A, B, C, D, E, F, G>(A item1, B item2, C item3, D item4, E item5, F item6, G item7) {}

    public record Of8<A, B, C, D, E, F, G, H>(A item1, B item2, C item3, D item4, E item5, F item6, G item7, H item8) {}
}
