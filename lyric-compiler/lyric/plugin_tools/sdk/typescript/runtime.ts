// Lyric plugin SDK runtime for TypeScript on Node 18+ (D207). Written by `lyric plugin sdk`; do not edit.
//
// The process-mode side of the Lyric plugin protocol, version 1: JSON-RPC 2.0
// over stdin and stdout, one message per line, the `plugin/hello` handshake,
// the `--lyric-plugin-manifest` probe, point-call dispatch and capability
// calls back to the host. JSON numbers keep their text (`JsonNumber`), so a
// Long or ULong above 2^53 is read exactly as a bigint.

import { createInterface } from "node:readline";

// ── JSON ────────────────────────────────────────────────────────────────────

/** A JSON number, as its JSON text. */
export class JsonNumber {
  constructor(readonly raw: string) {}

  toNumber(): number {
    return Number(this.raw);
  }

  toBigInt(): bigint {
    return BigInt(this.raw);
  }

  toString(): string {
    return this.raw;
  }
}

/** A JSON value. Objects are Maps, so member names keep their order and `__proto__` is an ordinary name. */
export type JsonValue = null | boolean | string | JsonNumber | JsonValue[] | JsonObject;
export type JsonObject = Map<string, JsonValue>;

export function isJsonObject(v: JsonValue | undefined): v is JsonObject {
  return v instanceof Map;
}

const MAX_DEPTH = 128;

/** Parses one JSON document strictly (RFC 8259). */
export function parseJson(text: string): JsonValue {
  let pos = 0;
  const fail = (expected: string): never => {
    throw new SyntaxError("expected " + expected + " at position " + pos);
  };
  const ws = (): void => {
    while (pos < text.length) {
      const c = text.charCodeAt(pos);
      if (c === 0x20 || c === 0x09 || c === 0x0a || c === 0x0d) pos++;
      else break;
    }
  };
  const isDigit = (c: number): boolean => c >= 0x30 && c <= 0x39;
  const str = (): string => {
    pos++;
    let out = "";
    for (;;) {
      if (pos >= text.length) fail("'\"'");
      const c = text.charCodeAt(pos++);
      if (c === 0x22) return out;
      if (c < 0x20) throw new SyntaxError("control character in a string at position " + (pos - 1));
      if (c !== 0x5c) {
        out += String.fromCharCode(c);
        continue;
      }
      const e = text[pos++];
      switch (e) {
        case '"': out += '"'; break;
        case "\\": out += "\\"; break;
        case "/": out += "/"; break;
        case "b": out += "\b"; break;
        case "f": out += "\f"; break;
        case "n": out += "\n"; break;
        case "r": out += "\r"; break;
        case "t": out += "\t"; break;
        case "u": {
          const hex = text.slice(pos, pos + 4);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) fail("four hex digits");
          out += String.fromCharCode(parseInt(hex, 16));
          pos += 4;
          break;
        }
        default:
          fail("an escape");
      }
    }
  };
  const num = (): JsonNumber => {
    const start = pos;
    if (text[pos] === "-") pos++;
    if (text[pos] === "0") pos++;
    else if (pos < text.length && text.charCodeAt(pos) >= 0x31 && text.charCodeAt(pos) <= 0x39) {
      while (pos < text.length && isDigit(text.charCodeAt(pos))) pos++;
    } else fail("a digit");
    if (text[pos] === ".") {
      pos++;
      const d = pos;
      while (pos < text.length && isDigit(text.charCodeAt(pos))) pos++;
      if (pos === d) fail("a digit");
    }
    if (text[pos] === "e" || text[pos] === "E") {
      pos++;
      if (text[pos] === "+" || text[pos] === "-") pos++;
      const d = pos;
      while (pos < text.length && isDigit(text.charCodeAt(pos))) pos++;
      if (pos === d) fail("a digit");
    }
    return new JsonNumber(text.slice(start, pos));
  };
  const value = (depth: number): JsonValue => {
    if (depth > MAX_DEPTH) throw new SyntaxError("document nested deeper than " + MAX_DEPTH);
    ws();
    const c = text[pos];
    if (c === "{") {
      pos++;
      const o: JsonObject = new Map();
      ws();
      if (text[pos] === "}") {
        pos++;
        return o;
      }
      for (;;) {
        ws();
        if (text[pos] !== '"') fail("a member name");
        const name = str();
        ws();
        if (text[pos] !== ":") fail("':'");
        pos++;
        o.set(name, value(depth + 1));
        ws();
        if (text[pos] === ",") {
          pos++;
          continue;
        }
        if (text[pos] === "}") {
          pos++;
          return o;
        }
        fail("',' or '}'");
      }
    }
    if (c === "[") {
      pos++;
      const a: JsonValue[] = [];
      ws();
      if (text[pos] === "]") {
        pos++;
        return a;
      }
      for (;;) {
        a.push(value(depth + 1));
        ws();
        if (text[pos] === ",") {
          pos++;
          continue;
        }
        if (text[pos] === "]") {
          pos++;
          return a;
        }
        fail("',' or ']'");
      }
    }
    if (c === '"') return str();
    if (text.startsWith("true", pos)) {
      pos += 4;
      return true;
    }
    if (text.startsWith("false", pos)) {
      pos += 5;
      return false;
    }
    if (text.startsWith("null", pos)) {
      pos += 4;
      return null;
    }
    if (c === "-" || (c !== undefined && isDigit(c.charCodeAt(0)))) return num();
    return fail("a value");
  };
  const v = value(0);
  ws();
  if (pos !== text.length) throw new SyntaxError("trailing content at position " + pos);
  return v;
}

/** Writes compact JSON text. */
export function writeJson(v: JsonValue): string {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "string") return JSON.stringify(v);
  if (v instanceof JsonNumber) return v.raw;
  if (Array.isArray(v)) return "[" + v.map(writeJson).join(",") + "]";
  const parts: string[] = [];
  for (const [k, x] of v) parts.push(JSON.stringify(k) + ":" + writeJson(x));
  return "{" + parts.join(",") + "}";
}

/** Builds a JSON object from name/value pairs, in order. */
export function obj(...members: [string, JsonValue][]): JsonObject {
  return new Map(members);
}

// ── Results and errors ──────────────────────────────────────────────────────

/** The Lyric `Unit` value; encoded as `null`. */
export type Unit = null;

/** A Lyric `Result[T, E]`; encoded as `{"ok": T}` or `{"err": E}`. */
export type Result<T, E> = { readonly ok: T } | { readonly err: E };

export function ok<T, E = never>(value: T): Result<T, E> {
  return { ok: value };
}

export function err<E, T = never>(error: E): Result<T, E> {
  return { err: error };
}

export function isOk<T, E>(r: Result<T, E>): r is { readonly ok: T } {
  return "ok" in r;
}

/** A failure of the boundary itself rather than of the method (D207 Decision 7). */
export type BoundaryError =
  | { case: "Denied"; reason: string }
  | { case: "NotGranted"; capability: string }
  | { case: "Stale" }
  | { case: "Unsupported"; method: string }
  | { case: "Revoked"; capability: string }
  | { case: "ContractViolated"; detail: string }
  | { case: "Timeout"; timeoutMs: number }
  | { case: "Crashed"; detail: string }
  | { case: "Protocol"; detail: string };

/** The error of a capability call: the method's own error or a boundary error. */
export type CallError<E> = { kind: "app"; error: E } | { kind: "boundary"; error: BoundaryError };

/** The JSON-RPC error codes of the plugin protocol (D207 Decision 3). */
export const Codes = {
  ParseError: -32700,
  InvalidRequest: -32600,
  InternalError: -32603,
  Timeout: -32001,
  Denied: -32040,
  NotGranted: -32041,
  Stale: -32042,
  Unsupported: -32043,
  Revoked: -32044,
  ContractViolated: -32045,
  Protocol: -32046,
} as const;

/** A value that does not match its boundary type; answered with `Codes.Protocol`. */
export class PluginProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PluginProtocolError";
  }
}

/** A JSON-RPC error a dispatcher answers with. */
export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data: JsonValue | undefined = undefined,
  ) {
    super(message);
    this.name = "RpcError";
  }
}

// ── Scalar codecs (D207 Decision 4) ─────────────────────────────────────────

function kindName(j: JsonValue | undefined): string {
  if (j === undefined) return "nothing";
  if (j === null) return "null";
  if (typeof j === "boolean") return "a boolean";
  if (typeof j === "string") return "a string";
  if (j instanceof JsonNumber) return "a number";
  if (Array.isArray(j)) return "an array";
  return "an object";
}

function kind(path: string, expected: string, j: JsonValue | undefined): PluginProtocolError {
  return new PluginProtocolError(path + ": expected " + expected + ", found " + kindName(j));
}

function integer(j: JsonValue | undefined, path: string, what: string, min: bigint, max: bigint): bigint {
  if (!(j instanceof JsonNumber)) throw kind(path, what, j);
  if (!/^-?[0-9]+$/.test(j.raw)) throw new PluginProtocolError(path + ": expected " + what + ", found the non-integer " + j.raw);
  const v = BigInt(j.raw);
  if (v < min || v > max) throw new PluginProtocolError(path + ": " + j.raw + " is out of range for " + what);
  return v;
}

const INT_MIN = -(2n ** 31n);
const INT_MAX = 2n ** 31n - 1n;
const LONG_MIN = -(2n ** 63n);
const LONG_MAX = 2n ** 63n - 1n;
const UINT_MAX = 2n ** 32n - 1n;
const ULONG_MAX = 2n ** 64n - 1n;

function safeInteger(v: number, what: string, min: bigint, max: bigint): JsonNumber {
  if (!Number.isInteger(v)) throw new PluginProtocolError(what + " must be an integer, found " + v);
  const b = BigInt(v);
  if (b < min || b > max) throw new PluginProtocolError(v + " is out of range for " + what);
  return new JsonNumber(b.toString());
}

function rangedBig(v: bigint, what: string, min: bigint, max: bigint): JsonNumber {
  if (typeof v !== "bigint") throw new PluginProtocolError(what + " must be a bigint");
  if (v < min || v > max) throw new PluginProtocolError(v + " is out of range for " + what);
  return new JsonNumber(v.toString());
}

export const Wire = {
  expectObject(j: JsonValue | undefined, path: string): JsonObject {
    if (j instanceof Map) return j;
    throw kind(path, "an object", j);
  },
  expectArray(j: JsonValue | undefined, path: string): JsonValue[] {
    if (Array.isArray(j)) return j;
    throw kind(path, "an array", j);
  },
  expectTuple(j: JsonValue | undefined, path: string, count: number): JsonValue[] {
    const a = Wire.expectArray(j, path);
    if (a.length !== count) throw new PluginProtocolError(path + ": expected an array of " + count + " elements, found " + a.length);
    return a;
  },
  has(o: JsonObject, name: string): boolean {
    return o.has(name);
  },
  required(o: JsonObject, name: string, path: string): JsonValue {
    if (!o.has(name)) throw new PluginProtocolError(path + ': missing required member "' + name + '"');
    return o.get(name) as JsonValue;
  },
  caseName(o: JsonObject, path: string): string {
    return Wire.decodeString(Wire.required(o, "case", path), path + ".case");
  },
  unknownCase(path: string, typeName: string, name: string): PluginProtocolError {
    return new PluginProtocolError(path + ': "' + name + '" is not a case of ' + typeName);
  },
  encodeBool(v: boolean): JsonValue {
    if (typeof v !== "boolean") throw new PluginProtocolError("expected a boolean");
    return v;
  },
  decodeBool(j: JsonValue | undefined, path: string): boolean {
    if (typeof j === "boolean") return j;
    throw kind(path, "a boolean", j);
  },
  encodeByte(v: number): JsonValue {
    return safeInteger(v, "a Byte", 0n, 255n);
  },
  decodeByte(j: JsonValue | undefined, path: string): number {
    return Number(integer(j, path, "a Byte (0 to 255)", 0n, 255n));
  },
  encodeInt(v: number): JsonValue {
    return safeInteger(v, "an Int", INT_MIN, INT_MAX);
  },
  decodeInt(j: JsonValue | undefined, path: string): number {
    return Number(integer(j, path, "an Int (a 32-bit integer)", INT_MIN, INT_MAX));
  },
  encodeUInt(v: number): JsonValue {
    return safeInteger(v, "a UInt", 0n, UINT_MAX);
  },
  decodeUInt(j: JsonValue | undefined, path: string): number {
    return Number(integer(j, path, "a UInt (0 to 4294967295)", 0n, UINT_MAX));
  },
  encodeLong(v: bigint): JsonValue {
    return rangedBig(v, "a Long", LONG_MIN, LONG_MAX);
  },
  decodeLong(j: JsonValue | undefined, path: string): bigint {
    return integer(j, path, "a Long (a 64-bit integer)", LONG_MIN, LONG_MAX);
  },
  encodeULong(v: bigint): JsonValue {
    return rangedBig(v, "a ULong", 0n, ULONG_MAX);
  },
  decodeULong(j: JsonValue | undefined, path: string): bigint {
    return integer(j, path, "a ULong (0 to 18446744073709551615)", 0n, ULONG_MAX);
  },
  encodeFloat(v: number): JsonValue {
    if (typeof v !== "number" || !Number.isFinite(v)) throw new PluginProtocolError("a non-finite Float cannot be encoded as JSON");
    return new JsonNumber(String(Math.fround(v)));
  },
  decodeFloat(j: JsonValue | undefined, path: string): number {
    if (!(j instanceof JsonNumber)) throw kind(path, "a Float", j);
    const f = Math.fround(Number(j.raw));
    if (!Number.isFinite(f)) throw new PluginProtocolError(path + ": " + j.raw + " is out of range for a Float");
    return f;
  },
  encodeDouble(v: number): JsonValue {
    if (typeof v !== "number" || !Number.isFinite(v)) throw new PluginProtocolError("a non-finite Double cannot be encoded as JSON");
    return new JsonNumber(String(v));
  },
  decodeDouble(j: JsonValue | undefined, path: string): number {
    if (!(j instanceof JsonNumber)) throw kind(path, "a Double", j);
    const d = Number(j.raw);
    if (!Number.isFinite(d)) throw new PluginProtocolError(path + ": " + j.raw + " is out of range for a Double");
    return d;
  },
  encodeChar(v: string): JsonValue {
    if (typeof v !== "string" || [...v].length !== 1) throw new PluginProtocolError("a Char must be a one-character string");
    return v;
  },
  decodeChar(j: JsonValue | undefined, path: string): string {
    const s = Wire.decodeString(j, path);
    if ([...s].length !== 1) throw new PluginProtocolError(path + ": expected a one-character string");
    return s;
  },
  encodeString(v: string): JsonValue {
    if (typeof v !== "string") throw new PluginProtocolError("expected a string");
    return v;
  },
  decodeString(j: JsonValue | undefined, path: string): string {
    if (typeof j === "string") return j;
    throw kind(path, "a string", j);
  },
  encodeUnit(_v: Unit): JsonValue {
    return null;
  },
  decodeUnit(j: JsonValue | undefined, path: string): Unit {
    if (j === null) return null;
    throw kind(path, "null", j);
  },
  encodeBytes(v: Uint8Array): JsonValue {
    return Buffer.from(v).toString("base64");
  },
  decodeBytes(j: JsonValue | undefined, path: string): Uint8Array {
    const s = Wire.decodeString(j, path);
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) throw new PluginProtocolError(path + ": not a base64 string");
    return new Uint8Array(Buffer.from(s, "base64"));
  },
  encodeJson(v: JsonValue): JsonValue {
    return v === undefined ? null : v;
  },
  decodeJson(j: JsonValue | undefined, _path: string): JsonValue {
    return j === undefined ? null : j;
  },
};

// ── Manifest ────────────────────────────────────────────────────────────────

/** Builds the plugin manifest (D207 Decision 5) the probe prints. */
export class ManifestBuilder {
  private readonly points: JsonValue[] = [];
  private readonly requiredList: JsonValue[] = [];
  private readonly optionalList: JsonValue[] = [];
  private readonly payloads: JsonValue[] = [];
  readonly requiredCapabilities: string[] = [];

  constructor(
    readonly id: string,
    readonly version: string,
    readonly publisher: string,
  ) {}

  point(point: string, version: string, contributions: JsonValue): this {
    this.points.push(obj(["point", point], ["version", version], ["contributions", contributions]));
    return this;
  }

  require(capability: string, grant: JsonValue): this {
    this.requiredList.push(obj(["name", capability], ["grant", grant]));
    this.requiredCapabilities.push(capability);
    return this;
  }

  optional(capability: string, grant: JsonValue): this {
    this.optionalList.push(obj(["name", capability], ["grant", grant]));
    return this;
  }

  dotnetPayload(dll: string): this {
    this.payloads.push(obj(["mode", "process"], ["runtime", "dotnet"], ["command", ["dotnet", "exec", dll]]));
    return this;
  }

  jvmPayload(jar: string): this {
    this.payloads.push(obj(["mode", "process"], ["runtime", "jvm"], ["command", ["java", "-jar", jar]]));
    return this;
  }

  nativePayload(os: string, arch: string, ...command: string[]): this {
    this.payloads.push(obj(["mode", "process"], ["os", os], ["arch", arch], ["command", command]));
    return this;
  }

  wasmPayload(module: string): this {
    this.payloads.push(obj(["mode", "wasm"], ["module", module]));
    return this;
  }

  toJson(): JsonObject {
    const o = obj(
      ["schema", new JsonNumber("1")],
      ["id", this.id],
      ["version", this.version],
      ["publisher", this.publisher],
      ["points", [...this.points]],
      ["capabilities", obj(["required", [...this.requiredList]], ["optional", [...this.optionalList]])],
    );
    if (this.payloads.length > 0) o.set("payloads", [...this.payloads]);
    return o;
  }

  toJsonString(): string {
    return writeJson(this.toJson());
  }
}

// ── Server ──────────────────────────────────────────────────────────────────

/** The plugin side of one plugin point: generated per point. */
export interface PointDispatcher {
  readonly pointId: string;
  readonly version: string;
  readonly methods: readonly string[];
  /** Runs `method` and returns `{"ok": ...}` or `{"err": ...}`. */
  dispatch(method: string, params: JsonObject): Promise<JsonValue>;
}

/** The grants the host gave this plugin, and the connection to call it on. */
export class PluginContext {
  constructor(
    private readonly server: PluginServer,
    private readonly grants: Map<string, JsonValue>,
  ) {}

  isGranted(capability: string): boolean {
    return this.grants.has(capability);
  }

  /** The grant value of a granted capability (`null` when it has no grant type). */
  grantOf(capability: string): JsonValue {
    return this.grants.get(capability) ?? null;
  }

  /** Calls the host and returns the JSON-RPC result or the boundary error the host answered. */
  callHost(method: string, params: JsonObject): Promise<Result<JsonValue, BoundaryError>> {
    return this.server.call(method, params);
  }

  /** Calls method `method` of capability `capability`. */
  async call<T, E>(
    capability: string,
    method: string,
    params: JsonObject,
    decodeOk: (j: JsonValue | undefined, path: string) => T,
    decodeErr: (j: JsonValue | undefined, path: string) => E,
  ): Promise<Result<T, CallError<E>>> {
    if (!this.isGranted(capability)) return err({ kind: "boundary", error: { case: "NotGranted", capability } });
    const answer = await this.callHost("cap/" + capability + "/" + method, params);
    if (!isOk(answer)) return err({ kind: "boundary", error: answer.err });
    try {
      const o = Wire.expectObject(answer.ok, "result");
      if (o.size === 1 && o.has("ok")) return ok(decodeOk(o.get("ok"), "result.ok"));
      if (o.size === 1 && o.has("err")) return err({ kind: "app", error: decodeErr(o.get("err"), "result.err") });
      throw new PluginProtocolError('result: expected {"ok": ...} or {"err": ...}');
    } catch (e) {
      if (e instanceof PluginProtocolError) return err({ kind: "boundary", error: { case: "Protocol", detail: e.message } });
      throw e;
    }
  }
}

export const MANIFEST_FLAG = "--lyric-plugin-manifest";
export const PROTOCOL_VERSION = 1;

type Waiter = (response: JsonObject | null) => void;

/** The process-mode plugin server: the JSON-RPC loop over stdin and stdout. */
export class PluginServer {
  private readonly pending = new Map<number, Waiter>();
  private readonly dispatchers = new Map<string, PointDispatcher>();
  private readonly inFlight = new Set<Promise<void>>();
  private nextId = 0;
  private closed = false;
  private handshakeDone = false;

  private constructor(
    private readonly manifest: ManifestBuilder,
    private readonly bind: (ctx: PluginContext) => PointDispatcher[],
  ) {}

  /**
   * The plugin's entry point: answers the manifest probe, or serves the protocol on
   * stdin and stdout until the host shuts the plugin down. Resolves to the exit code.
   */
  static async run(args: string[], manifest: ManifestBuilder, bind: (ctx: PluginContext) => PointDispatcher[]): Promise<number> {
    if (args.length === 1 && args[0] === MANIFEST_FLAG) {
      await new Promise<void>((resolve) => process.stdout.write(manifest.toJsonString() + "\n", () => resolve()));
      return 0;
    }
    if (args.length !== 0) {
      process.stderr.write("a Lyric plugin takes no arguments other than " + MANIFEST_FLAG + "; the host speaks to it on stdin and stdout\n");
      return 2;
    }
    return new PluginServer(manifest, bind).serve();
  }

  private async serve(): Promise<number> {
    const rl = createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
    for await (const line of rl) {
      if (line.trim().length === 0) continue;
      if (!this.handleLine(line)) break;
    }
    rl.close();
    this.closed = true;
    for (const [id, waiter] of this.pending) {
      this.pending.delete(id);
      waiter(null);
    }
    await Promise.all([...this.inFlight]);
    await new Promise<void>((resolve) => process.stdout.write("", () => resolve()));
    return 0;
  }

  /** Handles one message; false when the plugin should stop reading. */
  private handleLine(line: string): boolean {
    let msg: JsonValue;
    try {
      msg = parseJson(line);
    } catch (e) {
      this.sendError(null, Codes.ParseError, "parse error: " + (e as Error).message);
      return true;
    }
    if (!(msg instanceof Map)) {
      this.sendError(null, Codes.InvalidRequest, "a message must be a JSON object");
      return true;
    }
    const hasId = msg.has("id");
    const id = hasId ? (msg.get("id") as JsonValue) : null;
    if (msg.has("method")) {
      const method = msg.get("method");
      if (typeof method !== "string") {
        if (hasId) this.sendError(id, Codes.InvalidRequest, "method must be a string");
        return true;
      }
      const ps = msg.get("params");
      if (method === "plugin/shutdown") return false;
      if (!this.handshakeDone) {
        if (method === "plugin/hello" && hasId) this.hello(id, ps);
        else if (hasId) this.sendError(id, Codes.Protocol, "the plugin/hello handshake must come first");
        return true;
      }
      if (method === "plugin/hello") {
        if (hasId) this.sendError(id, Codes.Protocol, "the handshake has already completed");
        return true;
      }
      if (method === "$/cancelRequest" || !hasId) return true;
      if (ps !== undefined && ps !== null && !(ps instanceof Map)) {
        this.sendError(id, Codes.Protocol, "params must be an object keyed by parameter name");
        return true;
      }
      const params: JsonObject = ps instanceof Map ? ps : new Map();
      const task = this.callPoint(id, method, params);
      this.inFlight.add(task);
      void task.finally(() => this.inFlight.delete(task));
      return true;
    }
    if (hasId && (msg.has("result") || msg.has("error"))) {
      if (id instanceof JsonNumber && /^[0-9]+$/.test(id.raw)) {
        const n = Number(id.raw);
        const waiter = this.pending.get(n);
        if (waiter !== undefined) {
          this.pending.delete(n);
          waiter(msg);
        }
      }
      return true;
    }
    if (hasId) this.sendError(id, Codes.InvalidRequest, "not a JSON-RPC request or response");
    return true;
  }

  private hello(id: JsonValue, ps: JsonValue | undefined): void {
    if (!(ps instanceof Map)) {
      this.sendError(id, Codes.Protocol, "plugin/hello params must be an object");
      return;
    }
    const proto = ps.get("protocol");
    if (!(proto instanceof JsonNumber) || proto.raw !== String(PROTOCOL_VERSION)) {
      this.sendError(id, Codes.Protocol, "this plugin speaks protocol " + PROTOCOL_VERSION);
      return;
    }
    const grants = new Map<string, JsonValue>();
    const gs = ps.get("grants");
    if (Array.isArray(gs)) {
      for (const g of gs) {
        const cap = g instanceof Map ? g.get("capability") : undefined;
        if (!(g instanceof Map) || typeof cap !== "string") {
          this.sendError(id, Codes.Protocol, 'each grant must be {"capability": <name>, "grant": <value>}');
          return;
        }
        grants.set(cap, g.has("grant") ? (g.get("grant") as JsonValue) : null);
      }
    }
    for (const need of this.manifest.requiredCapabilities) {
      if (!grants.has(need)) {
        this.sendError(id, Codes.NotGranted, "the required capability " + need + " was not granted", obj(["capability", need]));
        return;
      }
    }
    const ctx = new PluginContext(this, grants);
    try {
      for (const d of this.bind(ctx)) this.dispatchers.set(d.pointId, d);
    } catch (e) {
      this.sendError(id, Codes.InternalError, "the plugin failed to start: " + (e as Error).message);
      return;
    }
    const points: JsonObject = new Map();
    for (const d of this.dispatchers.values()) {
      points.set(d.pointId, obj(["version", d.version], ["methods", [...d.methods]]));
    }
    this.handshakeDone = true;
    this.sendResult(id, obj(["protocol", new JsonNumber(String(PROTOCOL_VERSION))], ["id", this.manifest.id], ["points", points]));
  }

  private async callPoint(id: JsonValue, method: string, params: JsonObject): Promise<void> {
    const slash = method.lastIndexOf("/");
    const d = slash > 0 ? this.dispatchers.get(method.slice(0, slash)) : undefined;
    if (d === undefined) {
      this.sendError(id, Codes.Unsupported, "this plugin does not implement " + method, obj(["method", method]));
      return;
    }
    try {
      this.sendResult(id, await d.dispatch(method.slice(slash + 1), params));
    } catch (e) {
      if (e instanceof PluginProtocolError) this.sendError(id, Codes.Protocol, e.message);
      else if (e instanceof RpcError) this.sendError(id, e.code, e.message, e.data);
      else this.sendError(id, Codes.InternalError, "the plugin failed: " + String(e instanceof Error ? e.name + ": " + e.message : e));
    }
  }

  call(method: string, params: JsonObject): Promise<Result<JsonValue, BoundaryError>> {
    if (this.closed) return Promise.resolve(err({ case: "Crashed", detail: "the host closed the connection" }));
    const id = ++this.nextId;
    return new Promise((resolve) => {
      this.pending.set(id, (response) => {
        if (response === null) resolve(err({ case: "Crashed", detail: "the host closed the connection" }));
        else if (response.has("error")) resolve(err(toBoundaryError(response.get("error"), method)));
        else resolve(ok(response.has("result") ? (response.get("result") as JsonValue) : null));
      });
      this.send(obj(["jsonrpc", "2.0"], ["id", new JsonNumber(String(id))], ["method", method], ["params", params]));
    });
  }

  private sendResult(id: JsonValue, value: JsonValue): void {
    this.send(obj(["jsonrpc", "2.0"], ["id", id], ["result", value]));
  }

  private sendError(id: JsonValue, code: number, message: string, data?: JsonValue): void {
    const error = obj(["code", new JsonNumber(String(code))], ["message", message]);
    if (data !== undefined) error.set("data", data);
    this.send(obj(["jsonrpc", "2.0"], ["id", id], ["error", error]));
  }

  private send(message: JsonObject): void {
    process.stdout.write(writeJson(message) + "\n");
  }
}

function toBoundaryError(error: JsonValue | undefined, method: string): BoundaryError {
  const o = error instanceof Map ? error : new Map<string, JsonValue>();
  const codeNode = o.get("code");
  const code = codeNode instanceof JsonNumber ? Number(codeNode.raw) : 0;
  const messageNode = o.get("message");
  const message = typeof messageNode === "string" ? messageNode : "";
  const dataNode = o.get("data");
  const data = dataNode instanceof Map ? dataNode : new Map<string, JsonValue>();
  const dataString = (key: string, fallback: string): string => {
    const v = data.get(key);
    return typeof v === "string" ? v : fallback;
  };
  switch (code) {
    case Codes.Timeout: {
      const t = data.get("timeoutMs");
      return { case: "Timeout", timeoutMs: t instanceof JsonNumber ? Number(t.raw) : 0 };
    }
    case Codes.Denied:
      return { case: "Denied", reason: message };
    case Codes.NotGranted:
      return { case: "NotGranted", capability: dataString("capability", message) };
    case Codes.Stale:
      return { case: "Stale" };
    case Codes.Unsupported:
      return { case: "Unsupported", method: dataString("method", method) };
    case Codes.Revoked:
      return { case: "Revoked", capability: dataString("capability", message) };
    case Codes.ContractViolated:
      return { case: "ContractViolated", detail: message };
    case Codes.Protocol:
      return { case: "Protocol", detail: message };
    default:
      return { case: "Protocol", detail: "the host answered error " + code + ": " + message };
  }
}
