//! plugin_sdk_self_test.l - `Lyric.PluginSdk`, the model and generators behind
//! `lyric plugin sdk` (docs/69 §13, D207 Decisions 1, 3 and 4): reading an API
//! package's points, capabilities and boundary types, the errors for what
//! cannot cross a boundary, and the shape of the C#, Java, TypeScript and JSON
//! Schema output.  scripts/ci/plugin-sdk-e2e.sh compiles the generated SDKs and
//! drives plugins written against them through the wire protocol.
//!
//!   lyric test lyric-compiler/lyric/plugin_sdk_self_test.l
@test_module
package Lyric.PluginSdkSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.PluginSdk

func api(): String {
  "package Demo.Api\n" + "\n" + "import Std.Core\n" + "import Std.Collections\n" + "import Std.JsonValue\n" + "\n" +
    "pub enum Mood {\n  case Happy\n  case Sad\n}\n" +
    "\n" +
    "pub union Shape {\n  case Circle(radius: Double)\n  case Empty\n}\n" +
    "\n" +
    "@plugin_handle\npub type DocRef = Long\n" +
    "\n" +
    "alias Name = String\n" +
    "\n" +
    "pub type Age = Int range 0 ..= 150\n" +
    "\n" +
    "/// A greeting.\npub exposed record Greeting {\n  text: Name\n  age: Age\n  big: ULong\n  mood: Mood = Mood.Sad\n  note: Option[String]\n  data: List[Byte]\n  scores: Map[String, Long] = []\n  pair: (Int, Char)\n  extra: JsonValue\n}\n" +
    "\n" +
    "pub union GreetError {\n  case BadName(name: String)\n}\n" +
    "\n" +
    "pub exposed record Contribs {\n  commands: List[String] = []\n}\n" +
    "\n" +
    "pub exposed record FilesGrant {\n  roots: List[String]\n}\n" +
    "\n" +
    "@capability(grant = FilesGrant)\npub interface Files {\n  func readFile(path: in String): Result[String, GreetError]\n}\n" +
    "\n" +
    "@capability\npub interface Notify {\n  async func show(text: in String): Result[Unit, GreetError]\n}\n" +
    "\n" +
    "/// Greets.\n@plugin_point(version = \"1.2\", contributions = Contribs, allows(Files, Notify))\npub interface Greeter {\n  func greet(name: in String, doc: in DocRef): Result[Greeting, GreetError]\n  func shapes(s: in List[Shape]): Result[Option[Shape], GreetError]\n}\n"
}

func modelOf(src: in String): ModelResult {
  val sources: List[SdkSource] = newList()
  sources.add(SdkSource(path = "api.l", text = src))
  buildApiModel(sources)
}

func errorsText(errs: in List[String]): String = Str.joinList("\n", errs)

func hasError(r: in ModelResult, fragment: in String): Bool {
  for e in r.errors {
    if Str.contains(e, fragment) {
      return true
    }
  }
  false
}

/// A one-point API around `body` (extra declarations and the point's methods).
func withPoint(decls: in String, methods: in String): ModelResult {
  modelOf(
    "package P.Api\n\nimport Std.Core\nimport Std.Collections\n\n" + decls +
      "\n@plugin_point(version = \"1.0\")\npub interface Pt {\n" +
      methods +
      "}\n"
  )
}

func fileOf(generated: in SdkOutput, path: in String): String {
  for f in generated.files {
    if f.path == path {
      return f.content
    }
  }
  panic("no generated file " + path)
}

func declKind(m: in ApiModel, name: in String): String {
  match findDecl(m, name) {
    case Some(d) -> match d.kind {
      case KRecord(_) -> "record"
      case KUnion(_) -> "union"
      case KEnum(_) -> "enum"
      case KHandle -> "handle"
    }
    case None -> "missing"
  }
}

test "the model reads points, capabilities and reachable types" {
  val r = modelOf(api())
  assertEqualInt(r.errors.count, 0, errorsText(r.errors))
  val m = r.model
  assertEqual(m.packageName, "Demo.Api", "the API package")
  assertEqualInt(m.points.count, 1, "one point")
  val p = m.points[0]
  assertEqual(pointId(p), "Demo.Api.Greeter", "point id")
  assertEqual(p.version, "1.2", "point version")
  assertEqual(p.contributions, "Contribs", "contributions record")
  assertEqual(p.doc, "Greets.", "point doc")
  assertEqualInt(p.allows.count, 2, "allows")
  assertEqual(p.allows[0], "Demo.Api.Files", "allows qualified")
  assertEqualInt(p.methods.count, 2, "two methods")
  assertEqual(canonType(p.methods[1].ok), "Option[Shape]", "method result type")
  assertEqualInt(m.capabilities.count, 2, "two capabilities")
  assertEqual(m.capabilities[0].grant, "FilesGrant", "grant record")
  assertEqual(m.capabilities[1].grant, "", "no grant")
  assertEqual(declKind(m, "Mood"), "enum", "enum")
  assertEqual(declKind(m, "Shape"), "union", "union")
  assertEqual(declKind(m, "DocRef"), "handle", "handle")
  assertEqual(declKind(m, "Greeting"), "record", "record")
  assertEqual(declKind(m, "Name"), "missing", "an alias crosses as what it names")
  assertEqual(declKind(m, "Age"), "missing", "a range subtype crosses as its underlying type")
}

test "boundary types take their D207 encodings" {
  val r = modelOf(api())
  match findDecl(r.model, "Greeting") {
    case Some(d) -> match d.kind {
      case KRecord(fields) -> {
        assertEqual(canonType(fields[0].ty), "String", "alias expanded")
        assertEqual(canonType(fields[1].ty), "Int", "range subtype as Int")
        assertEqual(canonType(fields[2].ty), "ULong", "ULong")
        assertEqual(canonType(fields[5].ty), "List[Byte]", "bytes")
        assertEqual(canonType(fields[7].ty), "(Int, Char)", "tuple")
        assertEqual(canonType(fields[8].ty), "JsonValue", "JsonValue")
        assertTrue(fieldIsOptional(fields[3]), "a defaulted field may be missing")
        assertTrue(fieldIsOptional(fields[4]), "an Option field may be missing")
        assertFalse(fieldIsOptional(fields[0]), "a plain field is required")
        match fields[3].dflt {
          case Some(df) -> match df {
            case DefEnum(t, c) -> assertEqual(t + "." + c, "Mood.Sad", "enum default")
            case _ -> panic("expected an enum default")
          }
          case None -> panic("expected a default")
        }
        match fields[6].dflt {
          case Some(df) -> match df { case DefEmptyMap -> (); case _ -> panic("[] on a Map field is an empty map") }
          case None -> panic("expected a default")
        }
      }
      case _ -> panic("Greeting is a record")
    }
    case None -> panic("Greeting is reached")
  }
}

test "what cannot cross a boundary is an error" {
  assertTrue(hasError(withPoint("", "  func f(): Int\n"), "must return Result[T, E]"), "non-Result return")
  assertTrue(
    hasError(withPoint("", "  func f(x: in Option[Option[Int]]): Result[Unit, String]\n"), "Option[Option[T]]"),
    "nested Option"
  )
  assertTrue(
    hasError(withPoint("", "  func f(x: in Map[Int, String]): Result[Unit, String]\n"), "Map[String, T]"),
    "non-String map key"
  )
  assertTrue(
    hasError(withPoint("", "  func f(x: in (Int) -> Int): Result[Unit, String]\n"), "function type"),
    "function type"
  )
  assertTrue(hasError(withPoint("", "  func f[T](x: in T): Result[Unit, String]\n"), "generic"), "generic method")
  assertTrue(hasError(withPoint("", "  func f(x: out Int): Result[Unit, String]\n"), "out or inout"), "out parameter")
  assertTrue(
    hasError(withPoint("", "  func f(x: in Missing): Result[Unit, String]\n"), "unknown type Missing"),
    "unknown type"
  )
  assertTrue(
    hasError(
      withPoint("pub union U {\n  case A(Int)\n}\n", "  func f(x: in U): Result[Unit, String]\n"),
      "unnamed field"
    ),
    "positional union field"
  )
  assertTrue(
    hasError(
      withPoint("pub interface I {\n}\n", "  func f(x: in I): Result[Unit, String]\n"),
      "interface I cannot cross"
    ),
    "interface value"
  )
  assertTrue(
    hasError(
      withPoint("pub record R {\n  x: Int = 1 + 2\n}\n", "  func f(x: in R): Result[Unit, String]\n"),
      "default of field x"
    ),
    "computed default"
  )
  assertTrue(
    hasError(
      withPoint("@plugin_handle\npub type H = String\n", "  func f(x: in H): Result[Unit, String]\n"),
      "@plugin_handle type must be"
    ),
    "non-Long handle"
  )
}

test "annotation errors" {
  val noVersion = modelOf("package P.Api\n\nimport Std.Core\n\n@plugin_point\npub interface Pt {\n}\n")
  assertTrue(hasError(noVersion, "version = \"<major>.<minor>\""), "missing version")
  val badAllow = modelOf(
    "package P.Api\n\nimport Std.Core\n\npub interface NotCap {\n}\n\n@plugin_point(version = \"1.0\", allows(NotCap))\npub interface Pt {\n}\n"
  )
  assertTrue(hasError(badAllow, "not a @capability"), "allows names a non-capability")
  val unknownArg = modelOf("package P.Api\n\nimport Std.Core\n\n@capability(grnt = X)\npub interface C {\n}\n")
  assertTrue(hasError(unknownArg, "unknown argument grnt"), "unknown annotation argument")
  val notPub = modelOf("package P.Api\n\nimport Std.Core\n\n@capability\ninterface C {\n}\n")
  assertTrue(hasError(notPub, "pub interface"), "not pub")
  val empty = modelOf("package P.Api\n\nimport Std.Core\n\npub record R {\n  x: Int\n}\n")
  assertTrue(hasError(empty, "no @plugin_point"), "nothing to generate")
}

test "the C# SDK" {
  val r = modelOf(api())
  val generated = generateSdk(r.model, "csharp")
  assertEqualInt(generated.errors.count, 0, errorsText(generated.errors))
  assertTrue(
    Str.contains(fileOf(generated, "LyricPluginRuntime.cs"), "public sealed class PluginServer"),
    "the runtime"
  )
  val src = fileOf(generated, "Demo.Api.Plugin.cs")
  assertTrue(Str.contains(src, "namespace Demo.Api"), "namespace")
  assertTrue(Str.contains(src, "public required ulong Big { get; init; }"), "required field")
  assertTrue(Str.contains(src, "public Mood Mood { get; init; } = Mood.Sad;"), "defaulted field")
  assertTrue(Str.contains(src, "public readonly record struct DocRef(long Value);"), "handle")
  assertTrue(Str.contains(src, "public interface IGreeter"), "point interface")
  assertTrue(Str.contains(src, "Result<Greeting, GreetError> Greet(string name, DocRef doc);"), "point method")
  assertTrue(Str.contains(src, "public const string Id = \"Demo.Api.Greeter\";"), "point id")
  assertTrue(
    Str.contains(
      src,
      "public static ManifestBuilder ImplementGreeter(this ManifestBuilder manifest, Contribs contributions)"
    ),
    "manifest helper"
  )
  assertTrue(Str.contains(src, "public sealed class FilesClient"), "capability client")
  assertTrue(Str.contains(src, "public FilesGrant? Grant"), "grant accessor")
  assertTrue(
    Str.contains(src, "public static ManifestBuilder OptionalNotify(this ManifestBuilder manifest)"),
    "grantless helper"
  )
  assertTrue(Str.contains(src, "case \"greet\":"), "dispatch")
  assertTrue(Str.contains(fileOf(generated, "Demo.Api.schema.json"), "\"$schema\""), "the schema rides along")
}

test "the Java SDK" {
  val r = modelOf(api())
  val generated = generateSdk(r.model, "java")
  assertEqualInt(generated.errors.count, 0, errorsText(generated.errors))
  assertTrue(
    Str.contains(fileOf(generated, "lyric/plugin/PluginServer.java"), "public final class PluginServer"),
    "the runtime"
  )
  assertTrue(
    Str.contains(fileOf(generated, "lyric/plugin/Json.java"), "public static Value parse(String text)"),
    "the JSON reader"
  )
  val rec = fileOf(generated, "demo/api/Greeting.java")
  assertTrue(Str.contains(rec, "package demo.api;"), "Java package")
  assertTrue(
    Str.contains(
      rec,
      "public record Greeting(String text, int age, long big, Mood mood, java.util.Optional<String> note, byte[] data, java.util.Map<String, Long> scores, Tuple.Of2<Integer, Character> pair, Json.Value extra) {}"
    ),
    "record"
  )
  val shape = fileOf(generated, "demo/api/Shape.java")
  assertTrue(Str.contains(shape, "public sealed interface Shape permits Shape.Circle, Shape.Empty {"), "sealed union")
  val point = fileOf(generated, "demo/api/GreeterPoint.java")
  assertTrue(Str.contains(point, "public static final String VERSION = \"1.2\";"), "point version")
  assertTrue(
    Str.contains(
      fileOf(generated, "demo/api/Greeter.java"),
      "Result<Greeting, GreetError> greet(String name, DocRef doc);"
    ),
    "point interface"
  )
  val codec = fileOf(generated, "demo/api/Codec.java")
  assertTrue(
    Str.contains(codec, "o.has(\"mood\") ? decodeMood(o.get(\"mood\"), path + \".mood\") : Mood.Sad"),
    "default applied"
  )
  assertTrue(
    Str.contains(
      fileOf(generated, "demo/api/FilesClient.java"),
      "public Result<String, CallError<GreetError>> readFile(String path)"
    ),
    "capability client"
  )
}

test "the TypeScript SDK" {
  val r = modelOf(api())
  val generated = generateSdk(r.model, "typescript")
  assertEqualInt(generated.errors.count, 0, errorsText(generated.errors))
  assertTrue(Str.contains(fileOf(generated, "runtime.ts"), "export class JsonNumber"), "the runtime keeps number text")
  val src = fileOf(generated, "demo-api.ts")
  assertTrue(Str.contains(src, "from \"./runtime.js\";"), "ES module import")
  assertTrue(Str.contains(src, "  big: bigint;"), "ULong is a bigint")
  assertTrue(Str.contains(src, "  age: number;"), "Int is a number")
  assertTrue(Str.contains(src, "  mood?: Mood;"), "a defaulted field is optional to construct")
  assertTrue(Str.contains(src, "export type Mood = \"Happy\" | \"Sad\";"), "enum")
  assertTrue(Str.contains(src, "  | { case: \"Circle\"; radius: number }"), "union case")
  assertTrue(Str.contains(src, "export type DocRef = bigint & "), "handle")
  assertTrue(
    Str.contains(
      src,
      "greet(name: string, doc: DocRef): Result<Greeting, GreetError> | Promise<Result<Greeting, GreetError>>;"
    ),
    "point method"
  )
  assertTrue(Str.contains(src, "export class FilesClient {"), "capability client")
}

test "the JSON Schema" {
  val schema = generateSchema(modelOf(api()).model)
  assertTrue(Str.contains(schema, "\"maximum\": 18446744073709551615"), "ULong's maximum is exact")
  assertTrue(Str.contains(schema, "\"method\": \"Demo.Api.Greeter/greet\""), "point wire method")
  assertTrue(Str.contains(schema, "\"method\": \"cap/Demo.Api.Files/readFile\""), "capability wire method")
  assertTrue(Str.contains(schema, "\"contentEncoding\": \"base64\""), "bytes")
  assertTrue(Str.contains(schema, "\"x-lyric-handle\": true"), "handle")
}

test "generator-specific name clashes and unknown languages" {
  val clash = modelOf(
    "package P.Api\n\nimport Std.Core\n\npub record Codec {\n  x: Int\n}\n\n@plugin_point(version = \"1.0\")\npub interface Pt {\n  func f(c: in Codec): Result[Unit, String]\n}\n"
  )
  assertEqualInt(clash.errors.count, 0, errorsText(clash.errors))
  assertTrue(generateSdk(clash.model, "csharp").errors.count > 0, "C# reserves Codec")
  assertTrue(generateSdk(clash.model, "java").errors.count > 0, "Java reserves Codec")
  val unknown = generateSdk(clash.model, "cobol")
  assertTrue(Str.contains(errorsText(unknown.errors), "unknown SDK language"), "unknown language")
}

test "quoted strings are valid in every target language" {
  assertEqual(quoteString("a\"b\\c\nd\u{0001}"), "\"a\\\"b\\\\c\\nd\\u0001\"", "escapes")
}
