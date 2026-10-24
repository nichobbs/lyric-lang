// A plugin for the Demo.Api sample package, written against the TypeScript SDK
// that `lyric plugin sdk --lang typescript` generates (scripts/ci/plugin-sdk-e2e.sh).
import {
  DocRef,
  FilesCapability,
  FilesClient,
  type Greeter,
  GreeterPoint,
  type GreetError,
  type Greeting,
  NotifyCapability,
  NotifyClient,
  type Shape,
} from "./sdk/demo-api.js";
import { err, isOk, ManifestBuilder, ok, parseJson, type PluginContext, PluginServer, type Result } from "./sdk/runtime.js";

class DemoGreeter implements Greeter {
  private readonly files: FilesClient;
  private readonly notify: NotifyClient;

  constructor(context: PluginContext) {
    this.files = new FilesClient(context);
    this.notify = new NotifyClient(context);
  }

  greet(name: string, times: number): Result<Greeting, GreetError> {
    if (name.length === 0) return err({ case: "BadName", name });
    return ok({
      text: "hello " + name,
      count: times,
      big: 9007199254740993n,
      huge: 18446744073709551615n,
      ratio: 0.5,
      initial: name[0],
      tags: ["a", "b"],
      mood: "Happy",
      note: null,
      data: new Uint8Array([0, 1, 255]),
      scores: new Map([["min", -9223372036854775808n]]),
      pair: [times, name],
      extra: parseJson('{"k":[1,2.5,"s",null,true]}'),
      shapes: [{ case: "Circle", radius: 1.5 }, { case: "Rect", w: 2, h: 3 }, { case: "Empty" }],
    });
  }

  area(s: Shape): Result<number, GreetError> {
    switch (s.case) {
      case "Circle":
        return ok(3 * s.radius * s.radius);
      case "Rect":
        return ok(s.w * s.h);
      default:
        return ok(0);
    }
  }

  open(doc: DocRef, counts: Map<string, bigint>): Result<DocRef[], GreetError> {
    let sum = 0n;
    for (const v of counts.values()) sum += v;
    return ok([doc, DocRef(doc + sum)]);
  }

  echo(g: Greeting): Result<Greeting, GreetError> {
    return ok(g);
  }

  async readVia(path: string): Promise<Result<string, GreetError>> {
    const shown = await this.notify.show("reading " + path, 1);
    if (isOk(shown) || shown.err.kind !== "boundary" || shown.err.error.case !== "NotGranted") {
      return err({ case: "Failed", detail: "Notify should not be granted" });
    }
    const grant = this.files.grant;
    if (grant === null || grant.roots.length !== 1) return err({ case: "Failed", detail: "the Files grant is missing" });
    const read = await this.files.readFile(path);
    if (isOk(read)) return ok(read.ok + " (root " + grant.roots[0] + ")");
    if (read.err.kind === "app") return err(read.err.error);
    return err({ case: "Failed", detail: "boundary: " + read.err.error.case });
  }
}

const manifest = new ManifestBuilder("demo.greeter-typescript", "1.0.0", "lyric-e2e");
GreeterPoint.implement(manifest, { commands: ["greet"], priority: 7 });
FilesCapability.require(manifest, { roots: ["${workspace}"] });
NotifyCapability.optional(manifest);

process.exitCode = await PluginServer.run(process.argv.slice(2), manifest, (ctx) => [GreeterPoint.dispatcher(new DemoGreeter(ctx))]);
