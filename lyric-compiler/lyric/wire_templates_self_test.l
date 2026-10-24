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
//! remove, aliased inclusion with `Alias.member` access, multiple
//! independent wires per file, direct contributes with no include (the
//! mint-toolchain LocalVarSig regression shape), a collection whose
//! name doubles as the entries' constructor (false-W0001 regression),
//! an aliased-include `reorder` adjustment (#5284), a nested
//! include with transitive re-expose (#5289), and the docs/69 §14 entry
//! forms: `contributes[T] each` blocks (ordering, empty block, include-site
//! remove and reorder) and keyed entries reached through `<T>ByKey`.
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

// Consumer 4: aliased include with a reorder adjustment.  The ordering
// clause's sibling name (`logging`) must be remapped through the alias
// mangling exactly like the entries themselves — before the #5284 fix it
// dangled, producing a spurious W0022 and silently dropping the reorder.
wire ReorderApp {
  @provided tag: String
  include ServerModule as Core {
    @provided tag: tag
    reorder cors inside: logging
  }
  singleton reorderRouter: Router = Core.router
  expose reorderRouter
}

// Consumer 4b: contributes directly in a plain wire with NO include at
// all — the minimal shape of the CI-only mint-toolchain failure (the
// bootstrap's contributes-entry locals emitted a malformed LocalVarSig).
wire DirectApp {
  @provided tag: String
  contributes[Middleware] cors = Cors(tag = tag)
  contributes[Middleware] logging = Logging(tag = tag)
  singleton directRouter: Router = makeRouter(tag, Middleware)
  expose directRouter
}

func corsCount(ms: in List[Cors]): Int {
  ms.count
}

// Consumer 4c: the collection's element-type name doubles as the entries'
// constructor (`contributes[Cors] first = Cors(...)`).  The ctor call head
// must not count as a dependency on the synthesised collection, or the
// topo sort manufactures a false entry→collection→entry W0001 cycle.
wire SameNameApp {
  @provided tag: String
  contributes[Cors] first = Cors(tag = tag)
  contributes[Cors] second = Cors(tag = tag)
  singleton total: Int = corsCount(Cors)
  expose total
}

// Mid-level template: itself includes ServerModule and contributes an
// extra entry — nested-include runtime coverage (#5289).
pub wire ExtendedModule {
  @provided tag: String
  include ServerModule
  contributes[Middleware] extra = Auth(tag = tag)
  expose router
}

// Consumer 5: includes the mid-level template; the exposed `router` must
// re-expose transitively through both include levels.
wire NestedApp {
  @provided tag: String
  include ExtendedModule
  expose router
}

func pluginMiddlewares(tag: in String): List[Middleware] {
  val ms: List[Middleware] = newList()
  ms.add(Auth(tag = tag + "-a"))
  ms.add(Auth(tag = tag + "-b"))
  ms
}

func noMiddlewares(): List[Middleware] {
  val ms: List[Middleware] = newList()
  ms
}

// `contributes[T] each` (docs/69 §14): the block's elements join the
// collection together, in list order; the block is ordered by its name and
// other entries order themselves against it.
wire EachApp {
  @provided tag: String
  contributes[Middleware] cors = Cors(tag = tag)
  contributes[Middleware] each plugins = pluginMiddlewares(tag)
    inside: logging
  contributes[Middleware] each nothing = noMiddlewares()
  contributes[Middleware] last = Cors(tag = "z")
    inside: plugins
  contributes[Middleware] logging = Logging(tag = tag)
  singleton eachRouter: Router = makeRouter(tag, Middleware)
  expose eachRouter
}

// A template whose `each` block an including wire removes as a whole.
pub wire PluginModule {
  @provided tag: String
  contributes[Middleware] base = Logging(tag = tag)
  contributes[Middleware] each extras = pluginMiddlewares(tag)
  singleton pluginRouter: Router = makeRouter(tag, Middleware)
  expose pluginRouter
  overridable extras
}

wire NoPluginsApp {
  @provided tag: String
  include PluginModule {
    remove extras
  }
  expose pluginRouter
}

wire ReorderedPluginsApp {
  @provided tag: String
  include PluginModule {
    reorder extras wraps: base
  }
  expose pluginRouter
}

func labelFor(m: in Map[String, Middleware], k: in String): String {
  match mapGet(m, k) {
    case Some(found) -> {
      val mw: Middleware = found
      mw.label()
    }
    case None -> "missing"
  }
}

func keyTotal(m: in Map[String, Middleware]): Int {
  m.count
}

// Keyed contributions (docs/69 §14): every entry is in the ordered list,
// and the keyed ones are also reachable through `MiddlewareByKey`.
wire KeyedApp {
  @provided tag: String
  contributes[Middleware] key "cors" cors = Cors(tag = tag)
  contributes[Middleware] plain = Auth(tag = tag)
  contributes[Middleware] key "log" logging = Logging(tag = tag)
  contributes[Middleware] each plugins = pluginMiddlewares(tag)
  singleton keyedRouter: Router = makeRouter(tag, Middleware)
  singleton keyCount: Int = keyTotal(MiddlewareByKey)
  singleton logLabel: String = labelFor(MiddlewareByKey, "log")
  singleton corsLabel: String = labelFor(MiddlewareByKey, "cors")
  singleton absentLabel: String = labelFor(MiddlewareByKey, "auth")
  expose keyedRouter
  expose keyCount
  expose logLabel
  expose corsLabel
  expose absentLabel
}

// A binding initialiser that branches (#8372): the JVM bootstrap needs a
// StackMapTable frame at each branch target.
wire BranchApp {
  @provided flag: Bool
  singleton picked: String = if flag { "yes" } else { "no" }
  singleton twice: String = if flag { "y" + picked } else { "n" + picked }
  expose picked
  expose twice
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

test "direct contributes in a plain wire, no include" {
  DirectApp.bootstrap("d1")
  val r = DirectApp.directRouter()
  assertEqual(r.labels, "cors:d1,log:d1", "collection synthesised without any template involvement")
  assertEqual(r.tag, "d1", "provided passthrough")
}

test "collection named after the entries' constructor type" {
  SameNameApp.bootstrap("s2")
  assertEqualInt(SameNameApp.total(), 2, "ctor call head is not a collection dependency (no false W0001)")
}

test "aliased include reorder remaps ordering-clause names" {
  ReorderApp.bootstrap("r1")
  val r = ReorderApp.reorderRouter()
  // Template order is (cors, logging); `reorder cors inside: logging`
  // moves cors after logging.
  assertEqual(r.labels, "log:r1,cors:r1", "reorder repositions the entry under an alias (#5284)")
}

test "nested include splices transitively and re-exposes" {
  NestedApp.bootstrap("n1")
  val r = NestedApp.router()
  // ServerModule's entries (cors, logging) arrive through the nested
  // include first, then ExtendedModule's own contribution.
  assertEqual(r.labels, "cors:n1,log:n1,auth:n1", "entries from both include levels in order")
  assertEqual(r.tag, "note-n1", "provided value reaches the innermost template")
}

test "each block joins the collection in list order and keeps its position" {
  EachApp.bootstrap("e1")
  val r = EachApp.eachRouter()
  // cors first; plugins inside logging; last inside plugins; the empty
  // block contributes nothing.
  assertEqual(r.labels, "cors:e1,log:e1,auth:e1-a,auth:e1-b,cors:z", "block spliced as one ordered entry")
}

test "an including wire removes or reorders an each block as a whole" {
  NoPluginsApp.bootstrap("p1")
  assertEqual(NoPluginsApp.pluginRouter().labels, "log:p1", "removed block contributes nothing")
  ReorderedPluginsApp.bootstrap("p2")
  assertEqual(ReorderedPluginsApp.pluginRouter().labels, "auth:p2-a,auth:p2-b,log:p2", "reordered block moves together")
}

test "keyed contributions are in the list and reachable by key" {
  KeyedApp.bootstrap("k1")
  assertEqual(
    KeyedApp.keyedRouter().labels,
    "cors:k1,auth:k1,log:k1,auth:k1-a,auth:k1-b",
    "keyed entries keep their place in the ordered list"
  )
  assertEqualInt(KeyedApp.keyCount(), 2, "only keyed entries are in the map")
  assertEqual(KeyedApp.logLabel(), "log:k1", "lookup by key")
  assertEqual(KeyedApp.corsLabel(), "cors:k1", "second key")
  assertEqual(KeyedApp.absentLabel(), "missing", "an unkeyed entry is not in the map")
}

test "wire binding initialisers may branch" {
  BranchApp.bootstrap(true)
  assertEqual(BranchApp.picked(), "yes", "then branch")
  assertEqual(BranchApp.twice(), "yyes", "second branching binding")
  BranchApp.bootstrap(false)
  assertEqual(BranchApp.picked(), "no", "else branch")
  assertEqual(BranchApp.twice(), "nno", "second binding rebinds")
}
