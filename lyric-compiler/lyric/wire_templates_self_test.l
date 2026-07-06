//! wire_templates_self_test.l — end-to-end RUNTIME regression test for
//! docs/58 (D121) wire templates and `contributes[T]`, plus the #5021
//! MSIL wire ABI (`<Wire>.bootstrap(...)` / exposed accessors).
//!
//! Runs real expanded wires and asserts runtime values on BOTH targets
//! (like `bitwise_self_test.l`): `--target dotnet` compiles in-process
//! through the self-hosted `Msil.Bridge` (whose wire lowering now emits
//! the JVM-parity bootstrap/accessor ABI), `--target jvm` through the
//! self-hosted `Jvm.Bridge` `compileToJarBundled` and runs under `java`.
//!
//! Deliberately does NOT use config templates: module-level config
//! blocks only emit runtime state on the .NET target today (the JVM
//! config-emission gap is pre-existing, tracked as #3228) —
//! config-template runtime behaviour is covered by
//! `config_templates_self_test.l` on `--target dotnet`.
//!
//! Imports only `Std.*`, so no compiler-package linking is needed.
//!
//! Covers: `pub wire` template declaration + `include` splicing
//! (same-package short-form resolution), `@provided` bare passthrough
//! and explicit mapping, `contributes[T]` collection synthesis with
//! cross-scope ordering (consumer entry ordered against template
//! entries via `wraps:`/`inside:`), `overridable`-gated replace and
//! remove, aliased inclusion with `Alias.member` access, and multiple
//! independent wires per file.
@test_module
package Lyric.WireTemplatesSelfTest

import Std.Core
import Std.Collections
import Std.Testing

interface Middleware {
  func label(): String
}

record Cors {
  tag: String
}

impl Middleware for Cors {
  func label(): String {
    "cors:" + self.tag
  }
}

record Logging {
  tag: String
}

impl Middleware for Logging {
  func label(): String {
    "log:" + self.tag
  }
}

record Auth {
  tag: String
}

impl Middleware for Auth {
  func label(): String {
    "auth:" + self.tag
  }
}

record Router {
  labels: String
  tag: String
}

func joinLabels(ms: in List[Middleware]): String {
  var s = ""
  var i = 0
  while i < ms.count {
    if i > 0 {
      s = s + ","
    }
    // Bind through an interface-annotated local: the JVM backend erases
    // `List[T]` elements to Object, and a direct `ms[i].label()` would
    // mis-route through auto-FFI on java.lang.Object instead of Lyric
    // interface dispatch.
    val m: Middleware = ms[i]
    s = s + m.label()
    i = i + 1
  }
  s
}

func makeRouter(tag: in String, ms: in List[Middleware]): Router {
  Router(labels = joinLabels(ms), tag = tag)
}

pub wire ServerModule {
  @provided tag: String
  contributes[Middleware] cors = Cors(tag = tag)
  contributes[Middleware] logging = Logging(tag = tag)
  singleton internalNote: String = "note-" + tag
  singleton router: Router = makeRouter(internalNote, Middleware)
  expose router
  overridable cors
}

// Consumer 1: plain include, consumer contribution ordered against the
// template's entries, bare `@provided` passthrough.
wire ProdApp {
  @provided tag: String
  include ServerModule
  contributes[Middleware] auth = Auth(tag = tag)
    inside: logging
    wraps: cors
  singleton banner: String = "prod-" + tag
  expose router
  expose banner
}

// Consumer 2: explicit provided mapping, replace of the overridable
// `cors` entry, aliased access to the exposed router.
wire StagingApp {
  @provided stagingTag: String
  include ServerModule as Core {
    @provided tag: stagingTag
    cors = Auth(tag = "swapped")
  }
  singleton stagingRouter: Router = Core.router
  expose stagingRouter
}

// Consumer 3: remove the overridable entry entirely.
wire MinimalApp {
  @provided tag: String
  include ServerModule {
    remove cors
  }
  expose router
}

test "included template boots; collection order spans template and consumer entries" {
  ProdApp.bootstrap("t1")
  val r = ProdApp.router()
  // Template entries in declaration order (cors, logging), consumer's auth
  // constrained inside logging and wrapping cors: logging, auth, cors.
  assertEqual(r.labels, "log:t1,auth:t1,cors:t1", "collection order and provided passthrough")
  assertEqual(r.tag, "note-t1", "internal (mangled) template member wired through")
  assertEqual(ProdApp.banner(), "prod-t1", "consumer's own singleton exposed alongside")
}

test "explicit provided mapping and overridable replace" {
  StagingApp.bootstrap("s1")
  val r = StagingApp.stagingRouter()
  // cors replaced by Auth(tag = "swapped"); template order (cors, logging)
  // is unchanged by replacement.
  assertEqual(r.labels, "auth:swapped,log:s1", "replace keeps position, swaps implementation")
  assertEqual(r.tag, "note-s1", "provided mapping reaches internal members")
}

test "overridable remove drops the entry from the collection" {
  MinimalApp.bootstrap("m1")
  val r = MinimalApp.router()
  assertEqual(r.labels, "log:m1", "removed entry absent from the collection")
}

test "re-bootstrap rebinds provided values" {
  ProdApp.bootstrap("t2")
  val r = ProdApp.router()
  assertEqual(r.labels, "log:t2,auth:t2,cors:t2", "second bootstrap rebuilds the graph")
}
