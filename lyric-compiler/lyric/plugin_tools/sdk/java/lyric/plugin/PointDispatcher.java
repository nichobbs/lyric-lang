// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.util.List;

/** The plugin side of one plugin point: generated per point. */
public interface PointDispatcher {
    String pointId();

    String version();

    List<String> methods();

    /** Runs {@code method} and returns {@code {"ok": ...}} or {@code {"err": ...}}. */
    Json.Value dispatch(String method, Json.Obj params);
}
