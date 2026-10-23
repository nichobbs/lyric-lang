// A plugin for the Demo.Api sample package, written against the Java SDK that
// `lyric plugin sdk --lang java` generates (scripts/ci/plugin-sdk-e2e.sh).
import demo.api.*;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import lyric.plugin.*;

public final class DemoPlugin {
    private DemoPlugin() {}

    static final class DemoGreeter implements Greeter {
        private final FilesClient files;
        private final NotifyClient notify;

        DemoGreeter(PluginContext context) {
            files = new FilesClient(context);
            notify = new NotifyClient(context);
        }

        @Override
        public Result<Greeting, GreetError> greet(String name, int times) {
            if (name.isEmpty()) return Result.err(new GreetError.BadName(name));
            Map<String, Long> scores = new LinkedHashMap<>();
            scores.put("min", Long.MIN_VALUE);
            return Result.ok(new Greeting(
                    "hello " + name,
                    times,
                    9007199254740993L,
                    -1L,
                    0.5f,
                    name.charAt(0),
                    List.of("a", "b"),
                    Mood.Happy,
                    Optional.empty(),
                    new byte[] {0, 1, (byte) 255},
                    scores,
                    new Tuple.Of2<>(times, name),
                    Json.parse("{\"k\":[1,2.5,\"s\",null,true]}"),
                    List.of(new Shape.Circle(1.5), new Shape.Rect(2, 3), new Shape.Empty())));
        }

        @Override
        public Result<Double, GreetError> area(Shape s) {
            if (s instanceof Shape.Circle c) return Result.ok(3.0 * c.radius() * c.radius());
            if (s instanceof Shape.Rect r) return Result.ok(r.w() * r.h());
            return Result.ok(0.0);
        }

        @Override
        public Result<List<DocRef>, GreetError> open(DocRef doc, Map<String, Long> counts) {
            long sum = 0;
            for (long v : counts.values()) sum += v;
            return Result.ok(List.of(doc, new DocRef(doc.value() + sum)));
        }

        @Override
        public Result<Greeting, GreetError> echo(Greeting g) {
            return Result.ok(g);
        }

        @Override
        public Result<String, GreetError> readVia(String path) {
            Result<Unit, CallError<GreetError>> shown = notify.show("reading " + path, 1);
            if (!(shown instanceof Result.Err<Unit, CallError<GreetError>> se
                    && se.error() instanceof CallError.Boundary<GreetError> sb
                    && sb.error() instanceof BoundaryError.NotGranted)) {
                return Result.err(new GreetError.Failed("Notify should not be granted"));
            }
            Optional<FilesGrant> grant = files.grant();
            if (grant.isEmpty() || grant.get().roots().size() != 1) {
                return Result.err(new GreetError.Failed("the Files grant is missing"));
            }
            Result<String, CallError<GreetError>> read = files.readFile(path);
            if (read instanceof Result.Ok<String, CallError<GreetError>> ok) {
                return Result.ok(ok.value() + " (root " + grant.get().roots().get(0) + ")");
            }
            CallError<GreetError> e = ((Result.Err<String, CallError<GreetError>>) read).error();
            if (e instanceof CallError.App<GreetError> app) return Result.err(app.error());
            BoundaryError b = ((CallError.Boundary<GreetError>) e).error();
            return Result.err(new GreetError.Failed("boundary: " + b.getClass().getSimpleName()));
        }
    }

    public static void main(String[] args) {
        ManifestBuilder manifest = new ManifestBuilder("demo.greeter-java", "1.0.0", "lyric-e2e");
        GreeterPoint.implement(manifest, new GreeterContributions(List.of("greet"), 7));
        FilesCapability.require(manifest, new FilesGrant(List.of("${workspace}")));
        NotifyCapability.optional(manifest);
        System.exit(PluginServer.run(args, manifest, ctx -> List.of(GreeterPoint.dispatcher(new DemoGreeter(ctx)))));
    }
}
