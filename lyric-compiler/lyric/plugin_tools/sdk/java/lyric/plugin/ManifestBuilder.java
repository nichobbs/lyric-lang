// Lyric plugin SDK runtime for Java (D207). Written by `lyric plugin sdk`; do not edit.
package lyric.plugin;

import java.util.ArrayList;
import java.util.List;

/** Builds the plugin manifest (D207 Decision 5) the probe prints. */
public final class ManifestBuilder {
    private final String id;
    private final String version;
    private final String publisher;
    private final List<Json.Value> points = new ArrayList<>();
    private final List<Json.Value> required = new ArrayList<>();
    private final List<Json.Value> optional = new ArrayList<>();
    private final List<Json.Value> payloads = new ArrayList<>();
    private final List<String> requiredNames = new ArrayList<>();

    public ManifestBuilder(String id, String version, String publisher) {
        this.id = id;
        this.version = version;
        this.publisher = publisher;
    }

    public String id() { return id; }

    public String version() { return version; }

    public String publisher() { return publisher; }

    public List<String> requiredCapabilities() { return List.copyOf(requiredNames); }

    public ManifestBuilder point(String point, String version, Json.Value contributions) {
        points.add(new Json.Obj().put("point", Json.str(point)).put("version", Json.str(version)).put("contributions", contributions));
        return this;
    }

    public ManifestBuilder require(String capability, Json.Value grant) {
        required.add(new Json.Obj().put("name", Json.str(capability)).put("grant", grant));
        requiredNames.add(capability);
        return this;
    }

    public ManifestBuilder optional(String capability, Json.Value grant) {
        optional.add(new Json.Obj().put("name", Json.str(capability)).put("grant", grant));
        return this;
    }

    private static Json.Arr strings(String... parts) {
        Json.Arr a = new Json.Arr();
        for (String p : parts) a.items().add(Json.str(p));
        return a;
    }

    public ManifestBuilder dotnetPayload(String dll) {
        payloads.add(new Json.Obj().put("mode", Json.str("process")).put("runtime", Json.str("dotnet")).put("command", strings("dotnet", "exec", dll)));
        return this;
    }

    public ManifestBuilder jvmPayload(String jar) {
        payloads.add(new Json.Obj().put("mode", Json.str("process")).put("runtime", Json.str("jvm")).put("command", strings("java", "-jar", jar)));
        return this;
    }

    public ManifestBuilder nativePayload(String os, String arch, String... command) {
        payloads.add(new Json.Obj().put("mode", Json.str("process")).put("os", Json.str(os)).put("arch", Json.str(arch)).put("command", strings(command)));
        return this;
    }

    public ManifestBuilder wasmPayload(String module) {
        payloads.add(new Json.Obj().put("mode", Json.str("wasm")).put("module", Json.str(module)));
        return this;
    }

    public Json.Obj toJson() {
        Json.Obj caps = new Json.Obj().put("required", new Json.Arr(new ArrayList<>(required))).put("optional", new Json.Arr(new ArrayList<>(optional)));
        Json.Obj o = new Json.Obj()
                .put("schema", Json.Num.of(1))
                .put("id", Json.str(id))
                .put("version", Json.str(version))
                .put("publisher", Json.str(publisher))
                .put("points", new Json.Arr(new ArrayList<>(points)))
                .put("capabilities", caps);
        if (!payloads.isEmpty()) o.put("payloads", new Json.Arr(new ArrayList<>(payloads)));
        return o;
    }

    public String toJsonString() { return Json.write(toJson()); }
}
