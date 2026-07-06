//! wire_expand_self_test.l — exercises the self-hosted `Lyric.WireExpand`
//! library (docs/58 / D121).  Runs in CI via native `lyric test`:
//!
//!   lyric test lyric-compiler/lyric/wire_expand_self_test.l
//!
//! The compiler-package imports resolve by linking the already-compiled
//! stage-1 bundle DLLs as restored dependencies (#2364), like
//! `weaver_self_test.l`.
//!
//! Covers the three docs/58 pieces at the AST level:
//!   - config templates: `pub config` → synthesised record; `config X
//!     from T { … }` materialisation, override validation (W0010–W0014);
//!   - `contributes[T]`: entry lowering, List[T] synthesis, declaration
//!     order, `wraps:`/`inside:` adjustment, cycle/unknown diagnostics
//!     (W0020–W0022), `sealed` enforcement (W0023);
//!   - wire templates: `pub wire` collection + drop, `include` splicing
//!     (expose propagation, internal-name mangling, `@provided`
//!     mapping/passthrough, replace/remove gating, reorder, aliasing,
//!     nested includes, cycles — W0015–W0019, W0024, W0025).
//!
//! Runtime behaviour of expanded wires is covered separately by
//! `wire_templates_self_test.l` on both targets.
@test_module
package Lyric.WireExpandSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser
import Lyric.WireExpand

// ─────────────────────────────────────────────────────────────────────────────
// Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func dotted(p: in ModulePath): String {
  var s = ""
  var i = 0
  while i < p.segments.count {
    if i > 0 {
      s = s + "."
    }
    s = s + p.segments[i]
    i = i + 1
  }
  s
}

func expandSrc(src: in String): WireExpandResult {
  val pr = parse(src)
  val wires: Map[String, CollectedWireTemplate] = newMap()
  val configs: Map[String, CollectedConfigTemplate] = newMap()
  collectWireTemplates(pr.file.items, dotted(pr.file.packageDecl.path), wires, configs)
  expandFile(pr.file, wires, configs)
}

// Two-package expansion: collect templates from both, expand the consumer.
func expandTwo(libSrc: in String, appSrc: in String): WireExpandResult {
  val libPr = parse(libSrc)
  val appPr = parse(appSrc)
  val wires: Map[String, CollectedWireTemplate] = newMap()
  val configs: Map[String, CollectedConfigTemplate] = newMap()
  collectWireTemplates(libPr.file.items, dotted(libPr.file.packageDecl.path), wires, configs)
  collectWireTemplates(appPr.file.items, dotted(appPr.file.packageDecl.path), wires, configs)
  expandFile(appPr.file, wires, configs)
}

func hasDiag(res: in WireExpandResult, code: in String): Bool {
  var i = 0
  while i < res.diagnostics.count {
    if res.diagnostics[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

func diagCount(res: in WireExpandResult): Int {
  res.diagnostics.count
}

func firstWire(res: in WireExpandResult, name: in String): WireDecl {
  var i = 0
  while i < res.file.items.count {
    match res.file.items[i].kind {
      case IWire(decl) -> {
        if decl.name == name {
          return decl
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstWire: no wire named '" + name + "'")
}

func wireCount(res: in WireExpandResult): Int {
  var n = 0
  var i = 0
  while i < res.file.items.count {
    match res.file.items[i].kind {
      case IWire(_) -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

func recordCount(res: in WireExpandResult, name: in String): Int {
  var n = 0
  var i = 0
  while i < res.file.items.count {
    match res.file.items[i].kind {
      case IRecord(decl) -> {
        if decl.name == name {
          n = n + 1
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

func firstConfig(res: in WireExpandResult, name: in String): ConfigDecl {
  var i = 0
  while i < res.file.items.count {
    match res.file.items[i].kind {
      case IConfig(decl) -> {
        if decl.name == name {
          return decl
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("firstConfig: no config named '" + name + "'")
}

func configCount(res: in WireExpandResult): Int {
  var n = 0
  var i = 0
  while i < res.file.items.count {
    match res.file.items[i].kind {
      case IConfig(_) -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

func configFieldDefaultStr(cd: in ConfigDecl, field: in String): String {
  var i = 0
  while i < cd.fields.count {
    if cd.fields[i].name == field {
      match cd.fields[i].default {
        case Some(e) -> {
          match e.kind {
            case ELiteral(lit) -> {
              match lit {
                case LString(s) -> return s
                case LInt(_, _, raw) -> return raw
                case _ -> return "<other-literal>"
              }
            }
            case _ -> return "<expr>"
          }
        }
        case None -> return "<required>"
      }
    }
    i = i + 1
  }
  "<missing>"
}

// The name of a wire member (mirrors codegen's naming rules).
func memberName(m: in WireMember): String {
  match m {
    case WMSingleton(n, _, _, _) -> n
    case WMLocal(n, _, _, _) -> n
    case WMProvided(n, _, _) -> n
    case WMExpose(n, _) -> n
    case _ -> ""
  }
}

func hasMemberNamed(decl: in WireDecl, name: in String): Bool {
  var i = 0
  while i < decl.members.count {
    if memberName(decl.members[i]) == name {
      return true
    }
    i = i + 1
  }
  false
}

func findLocalInit(decl: in WireDecl, name: in String): Expr {
  var i = 0
  while i < decl.members.count {
    match decl.members[i] {
      case WMLocal(n, _, init, _) -> {
        if n == name {
          return init
        }
      }
      case WMSingleton(n2, _, init2, _) -> {
        if n2 == name {
          return init2
        }
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  panic("findLocalInit: no member named '" + name + "'")
}

// The bare-name elements of a synthesised `[a, b, c]` list member.
func listElemNames(decl: in WireDecl, name: in String): List[String] {
  val init = findLocalInit(decl, name)
  val names: List[String] = newList()
  match init.kind {
    case EList(exprs) -> {
      var i = 0
      while i < exprs.count {
        match exprs[i].kind {
          case EPath(p) -> names.add(p.segments[p.segments.count - 1])
          case _ -> names.add("<expr>")
        }
        i = i + 1
      }
    }
    case _ -> panic("listElemNames: member '" + name + "' init is not a list literal")
  }
  names
}

// Render the head name of a call-shaped init (`Ctor(...)` / `f(...)`).
func callHeadName(e: in Expr): String {
  match e.kind {
    case ECall(fn, _) -> {
      match fn.kind {
        case EPath(p) -> p.segments[p.segments.count - 1]
        case _ -> "<non-path>"
      }
    }
    case _ -> "<non-call>"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §1. Config templates.
// ─────────────────────────────────────────────────────────────────────────────
test "pub config template becomes a pub record twin" {
  val src = "package P\n" + "pub config StaticFiles {\n" + "  root: String = \"./public\"\n" +
    "  cacheSeconds: Int = 3600\n" +
    "}\n"
  val res = expandSrc(src)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  assertEqualInt(recordCount(res, "StaticFiles"), 1, "record twin synthesised")
  assertEqualInt(configCount(res), 0, "template itself is not an env-backed config block")
}

test "config from materialises template fields with overrides applied" {
  val src = "package P\n" + "pub config StaticFiles {\n" + "  root: String = \"./public\"\n" +
    "  cacheSeconds: Int = 3600\n" +
    "}\n" +
    "config Assets from StaticFiles {\n" +
    "  root: String = \"./wwwroot\"\n" +
    "}\n"
  val res = expandSrc(src)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val cd = firstConfig(res, "Assets")
  assertEqualInt(cd.fields.count, 2, "all template fields materialised")
  assertEqual(configFieldDefaultStr(cd, "root"), "./wwwroot", "override wins")
  assertEqual(configFieldDefaultStr(cd, "cacheSeconds"), "3600", "non-overridden keeps template default")
}

test "config from with unknown template is W0010" {
  val src = "package P\n" + "config Assets from NoSuchTemplate {\n" + "  root: String = \"x\"\n" + "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0010"), "unknown template reported")
}

test "config override of a field the template lacks is W0011" {
  val src = "package P\n" + "pub config T { root: String = \"a\" }\n" + "config C from T { bogus: String = \"b\" }\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0011"), "unknown override field reported")
}

test "config override with mismatched type is W0012" {
  val src = "package P\n" + "pub config T { root: String = \"a\" }\n" + "config C from T { root: Int = 3 }\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0012"), "type mismatch reported")
}

test "pub on a config instantiation is W0013" {
  val src = "package P\n" + "pub config T { root: String = \"a\" }\n" + "pub config C from T { root: String = \"b\" }\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0013"), "pub instantiation rejected")
}

test "config template with disallowed field type is W0014" {
  val src = "package P\n" + "pub config T { xs: List[String] = [] }\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0014"), "disallowed template field type reported")
}

test "cross-package config template resolves through the collected map" {
  val lib = "package Web\n" + "pub config StaticFiles { root: String = \"./public\" }\n"
  val app = "package App\n" + "import Web\n" + "config Assets from Web.StaticFiles { root: String = \"./www\" }\n"
  val res = expandTwo(lib, app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val cd = firstConfig(res, "Assets")
  assertEqual(configFieldDefaultStr(cd, "root"), "./www", "cross-package override applied")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. contributes[T].
// ─────────────────────────────────────────────────────────────────────────────
test "contributes entries become typed locals plus a List[T] member" {
  val src = "package P\n" + "interface Mw { func wrap(x: in Int): Int }\n" + "record A { v: Int }\n" +
    "record B { v: Int }\n" +
    "wire W {\n" +
    "  contributes[Mw] a = A(v = 1)\n" +
    "  contributes[Mw] b = B(v = 2)\n" +
    "  expose Mw\n" +
    "}\n"
  val res = expandSrc(src)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "W")
  assertTrue(hasMemberNamed(w, "a"), "entry a lowered to a member")
  assertTrue(hasMemberNamed(w, "b"), "entry b lowered to a member")
  val order = listElemNames(w, "Mw")
  assertEqualInt(order.count, 2, "two collection elements")
  assertEqual(order[0], "a", "declaration order first")
  assertEqual(order[1], "b", "declaration order second")
}

test "wraps and inside adjust collection order" {
  val src = "package P\n" + "interface Mw { func wrap(x: in Int): Int }\n" + "record A { v: Int }\n" + "wire W {\n" +
    "  contributes[Mw] a = A(v = 1)\n" +
    "  contributes[Mw] b = A(v = 2)\n" +
    "  contributes[Mw] c = A(v = 3)\n" +
    "    inside: a\n" +
    "    wraps: b\n" +
    "}\n"
  val res = expandSrc(src)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val order = listElemNames(firstWire(res, "W"), "Mw")
  assertEqualInt(order.count, 3, "three collection elements")
  assertEqual(order[0], "a", "a outermost")
  assertEqual(order[1], "c", "c inside a, wrapping b")
  assertEqual(order[2], "b", "b innermost")
}

test "ordering constraint cycle is W0021" {
  val src = "package P\n" + "interface Mw { func wrap(x: in Int): Int }\n" + "record A { v: Int }\n" + "wire W {\n" +
    "  contributes[Mw] a = A(v = 1)\n" +
    "    wraps: b\n" +
    "  contributes[Mw] b = A(v = 2)\n" +
    "    wraps: a\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0021"), "ordering cycle reported")
}

test "ordering reference to unknown entry is W0022" {
  val src = "package P\n" + "interface Mw { func wrap(x: in Int): Int }\n" + "record A { v: Int }\n" + "wire W {\n" +
    "  contributes[Mw] a = A(v = 1)\n" +
    "    wraps: ghost\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0022"), "unknown ordering reference reported")
}

test "mixing contributes[T] with a plain binding named T is W0020" {
  val src = "package P\n" + "interface Mw { func wrap(x: in Int): Int }\n" + "record A { v: Int }\n" + "wire W {\n" +
    "  bind Mw -> A(v = 9)\n" +
    "  contributes[Mw] a = A(v = 1)\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0020"), "instance/collection ambiguity reported")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Wire templates: include.
// ─────────────────────────────────────────────────────────────────────────────
func libTemplate(): String {
  "package Web\n" + "record Router { tag: String }\n" + "record Cors { tag: String }\n" +
    "interface Mw { func wrap(x: in Int): Int }\n" +
    "pub wire ServerModule {\n" +
    "  @provided cfg: String\n" +
    "  singleton helper: Cors = Cors(tag = cfg)\n" +
    "  contributes[Mw] cors = Cors(tag = \"cors\")\n" +
    "  contributes[Mw] logging = Cors(tag = \"log\")\n" +
    "  singleton router: Router = Router(tag = cfg)\n" +
    "  expose router\n" +
    "  overridable cors\n" +
    "}\n"
}

test "pub wire template is dropped from the declaring file" {
  val res = expandSrc(libTemplate())
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  assertEqualInt(wireCount(res), 0, "template item dropped")
}

test "include splices exposed members bare and internals mangled" {
  val app = "package App\n" + "import Web\n" + "record AppCfg { v: Int }\n" + "wire Prod {\n" +
    "  @provided cfg: String\n" +
    "  include Web.ServerModule\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  assertTrue(hasMemberNamed(w, "router"), "exposed member spliced under its bare name")
  assertTrue(hasMemberNamed(w, "__incl1_helper"), "non-exposed member mangled")
  assertTrue(not hasMemberNamed(w, "helper"), "non-exposed bare name absent")
  // The collection joins consumer scope bare.
  val order = listElemNames(w, "Mw")
  assertEqualInt(order.count, 2, "template contributes present")
}

test "include with unknown template is W0015" {
  val app = "package App\n" + "wire Prod {\n" + "  include No.Such.Module\n" + "}\n"
  val res = expandSrc(app)
  assertTrue(hasDiag(res, "W0015"), "unknown template reported")
}

test "consumer contributes joins template collection and orders against template entries" {
  val app = "package App\n" + "import Web\n" + "record Auth { tag: String }\n" + "wire Prod {\n" +
    "  @provided cfg: String\n" +
    "  include Web.ServerModule\n" +
    "  contributes[Mw] auth = Auth(tag = \"auth\")\n" +
    "    inside: logging\n" +
    "    wraps: cors\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val order = listElemNames(firstWire(res, "Prod"), "Mw")
  assertEqualInt(order.count, 3, "three entries after join")
  assertEqual(order[0], "logging", "logging outermost")
  assertEqual(order[1], "auth", "auth inside logging, wrapping cors")
  assertEqual(order[2], "cors", "cors innermost")
}

test "replace of an overridable entry substitutes the init" {
  val app = "package App\n" + "import Web\n" + "record MyCors { tag: String }\n" + "wire Prod {\n" +
    "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    cors = MyCors(tag = \"mine\")\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  assertEqual(callHeadName(findLocalInit(w, "cors")), "MyCors", "replacement init in place")
}

test "replace of a non-overridable entry is W0018" {
  val app = "package App\n" + "import Web\n" + "record X { tag: String }\n" + "wire Prod {\n" +
    "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    logging = X(tag = \"x\")\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertTrue(hasDiag(res, "W0018"), "non-overridable replace rejected")
}

test "remove of an overridable entry drops it from the collection" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    remove cors\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val order = listElemNames(firstWire(res, "Prod"), "Mw")
  assertEqualInt(order.count, 1, "one entry left")
  assertEqual(order[0], "logging", "cors removed")
}

test "remove of an unknown entry is W0019" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    remove ghost\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertTrue(hasDiag(res, "W0019"), "unknown remove target reported")
}

test "provided mapping to an unknown template input is W0025" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    @provided ghost: cfg\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertTrue(hasDiag(res, "W0025"), "unknown provided mapping reported")
}

test "unmapped provided with no same-named binding is W0017" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.ServerModule\n" + "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertTrue(hasDiag(res, "W0017"), "unresolved provided passthrough reported")
}

test "explicit provided mapping renames references in spliced inits" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided appCfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    @provided cfg: appCfg\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  val init = findLocalInit(w, "router")
  // Router(tag = cfg) must have become Router(tag = appCfg).
  var sawAppCfg = false
  match init.kind {
    case ECall(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> {
            match value.kind {
              case EPath(p) -> {
                if p.segments[p.segments.count - 1] == "appCfg" {
                  sawAppCfg = true
                }
              }
              case _ -> {
              }
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
  assertTrue(sawAppCfg, "provided reference renamed to the mapped binding")
}

test "aliased include mangles exposed names and rewrites Alias.member access" {
  val app = "package App\n" + "import Web\n" + "record Wrap { r: Router }\n" + "wire Prod {\n" +
    "  @provided cfg: String\n" +
    "  include Web.ServerModule as Public\n" +
    "  singleton wrapped: Wrap = Wrap(r = Public.router)\n" +
    "  expose wrapped\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  assertTrue(hasMemberNamed(w, "__incl_Public_router"), "aliased exposed member mangled")
  assertTrue(not hasMemberNamed(w, "router"), "bare exposed name absent under alias")
  val init = findLocalInit(w, "wrapped")
  var sawMangled = false
  match init.kind {
    case ECall(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> {
            match value.kind {
              case EPath(p) -> {
                if p.segments[p.segments.count - 1] == "__incl_Public_router" {
                  sawMangled = true
                }
              }
              case _ -> {
              }
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
  assertTrue(sawMangled, "Alias.member access rewritten to the mangled member")
}

test "unaliased double include of the same template collides with W0024" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule\n" +
    "  include Web.ServerModule\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertTrue(hasDiag(res, "W0024"), "bare-name collision reported")
}

test "include cycle is W0016" {
  val lib = "package Web\n" + "record R { v: Int }\n" + "pub wire A {\n" + "  include Web.B\n" +
    "  singleton ra: R = R(v = 1)\n" +
    "  expose ra\n" +
    "}\n" +
    "pub wire B {\n" +
    "  include Web.A\n" +
    "  singleton rb: R = R(v = 2)\n" +
    "  expose rb\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.A\n" + "}\n"
  val res = expandTwo(lib, app)
  assertTrue(hasDiag(res, "W0016"), "include cycle reported")
}

test "nested include splices the inner template too" {
  val lib = "package Web\n" + "record R { v: Int }\n" + "record S { v: Int }\n" + "pub wire Inner {\n" +
    "  singleton innerVal: S = S(v = 7)\n" +
    "  expose innerVal\n" +
    "}\n" +
    "pub wire Outer {\n" +
    "  include Web.Inner\n" +
    "  singleton outerVal: R = R(v = 1)\n" +
    "  expose outerVal\n" +
    "  expose innerVal\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.Outer\n" + "  expose outerVal\n" + "}\n"
  val res = expandTwo(lib, app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  assertTrue(hasMemberNamed(w, "outerVal"), "outer exposed member present")
  assertTrue(hasMemberNamed(w, "innerVal"), "inner exposed member propagated through outer")
}

test "sealed collection rejects consumer contributions with W0023" {
  val lib = "package Web\n" + "record C { tag: String }\n" + "interface Mw { func wrap(x: in Int): Int }\n" +
    "pub wire Sealed {\n" +
    "  sealed contributes[Mw] auth = C(tag = \"auth\")\n" +
    "  singleton r: C = C(tag = \"r\")\n" +
    "  expose r\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "record D { tag: String }\n" + "wire Prod {\n" + "  include Web.Sealed\n" +
    "  contributes[Mw] extra = D(tag = \"extra\")\n" +
    "  expose r\n" +
    "}\n"
  val res = expandTwo(lib, app)
  assertTrue(hasDiag(res, "W0023"), "sealed collection extension rejected")
}

test "reorder adjustment repositions an existing entry" {
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule {\n" +
    "    reorder cors wraps: logging\n" +
    "  }\n" +
    "  expose router\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val order = listElemNames(firstWire(res, "Prod"), "Mw")
  assertEqualInt(order.count, 2, "both entries present")
  assertEqual(order[0], "cors", "cors reordered to wrap logging")
  assertEqual(order[1], "logging", "logging now inner")
}

test "aliased include remaps reorder ordering-clause names" {
  // Before the #5284 fix the `inside: logging` clause was appended without
  // the alias remap, dangled (spurious W0022), and the reorder was dropped.
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  @provided cfg: String\n" +
    "  include Web.ServerModule as Core {\n" +
    "    reorder cors inside: logging\n" +
    "  }\n" +
    "}\n"
  val res = expandTwo(libTemplate(), app)
  assertEqualInt(diagCount(res), 0, "no spurious W0022 under alias (#5284)")
  // An aliased include's non-exposed contributes entries and collection are
  // isolated under the internal `__incl<N>_` prefix.
  val order = listElemNames(firstWire(res, "Prod"), "__incl1_Mw")
  assertEqualInt(order.count, 2, "both entries present")
  assertEqual(order[0], "__incl1_logging", "logging now outer (#5284)")
  assertEqual(order[1], "__incl1_cors", "cors moved inside logging (#5284)")
}

test "expose of an unknown name reports W0027" {
  val src = "package P\n" + "record R { v: Int }\n" + "wire W {\n" + "  singleton r: R = R(v = 1)\n" + "  expose r\n" +
    "  expose nonexistent\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0027"), "unknown expose target reported at expansion time (#5285)")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Config instantiation inside a wire body.
// ─────────────────────────────────────────────────────────────────────────────
test "wire-body config instantiation hoists to module scope and rewrites value use" {
  val src = "package P\n" + "pub config StaticFiles {\n" + "  root: String = \"./public\"\n" + "}\n" +
    "record Server { files: StaticFiles }\n" +
    "wire W {\n" +
    "  config Assets from StaticFiles {\n" +
    "    root: String = \"./www\"\n" +
    "  }\n" +
    "  singleton server: Server = Server(files = Assets)\n" +
    "  expose server\n" +
    "}\n"
  val res = expandSrc(src)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val cd = firstConfig(res, "Assets")
  assertEqual(configFieldDefaultStr(cd, "root"), "./www", "hoisted config carries the override")
  val w = firstWire(res, "W")
  val init = findLocalInit(w, "server")
  // Server(files = Assets) must have become Server(files = StaticFiles(root = Assets.root)).
  var sawCtor = false
  match init.kind {
    case ECall(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> {
            if callHeadName(value) == "StaticFiles" {
              sawCtor = true
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
  assertTrue(sawCtor, "value-position config use rewritten to record construction")
}

test "include-body config override wins over template instantiation default" {
  val lib = "package Web\n" + "pub config StaticFiles {\n" + "  root: String = \"./public\"\n" + "}\n" +
    "record Server { files: StaticFiles }\n" +
    "pub wire ServerModule {\n" +
    "  config Files from StaticFiles {\n" +
    "    root: String = \"./module-default\"\n" +
    "  }\n" +
    "  singleton server: Server = Server(files = Files)\n" +
    "  expose server\n" +
    "  overridable Files\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.ServerModule {\n" +
    "    Files { root = \"./consumer\" }\n" +
    "  }\n" +
    "  expose server\n" +
    "}\n"
  val res = expandTwo(lib, app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val cd = firstConfig(res, "Files")
  assertEqual(configFieldDefaultStr(cd, "root"), "./consumer", "include-body override wins")
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Review follow-ups (#5278, #5279, #5281–#5283).
// ─────────────────────────────────────────────────────────────────────────────
test "aliased include prefixes config-instance field access in spliced inits" {
  val lib = "package Web\n" + "pub config StaticFiles {\n" + "  root: String = \"./public\"\n" + "}\n" +
    "record Server { files: StaticFiles }\n" +
    "pub wire ServerModule {\n" +
    "  config Files from StaticFiles {\n" +
    "    root: String = \"./module\"\n" +
    "  }\n" +
    "  singleton server: Server = Server(files = Files)\n" +
    "  singleton banner: String = Files.root\n" +
    "  expose server\n" +
    "  expose banner\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.ServerModule as Core\n" +
    "  singleton mainServer: Server = Core.server\n" +
    "  expose mainServer\n" +
    "}\n"
  val res = expandTwo(lib, app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  // The instance hoists under the alias-prefixed name...
  val cd = firstConfig(res, "Core_Files")
  assertEqual(configFieldDefaultStr(cd, "root"), "./module", "aliased instance hoisted with its override")
  // ...and the spliced member's value-position rewrite reads fields
  // through that hoisted name, not the dangling un-prefixed one (#5278).
  val w = firstWire(res, "Prod")
  val init = findLocalInit(w, "__incl_Core_server")
  var sawPrefixedRead = false
  match init.kind {
    case ECall(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> {
            match value.kind {
              case ECall(_, ctorArgs) -> {
                var j = 0
                while j < ctorArgs.count {
                  match ctorArgs[j] {
                    case CANamed(_, fieldRead, _) -> {
                      match fieldRead.kind {
                        case EMember(recv, _) -> {
                          match recv.kind {
                            case EPath(p) -> {
                              if p.segments[p.segments.count - 1] == "Core_Files" {
                                sawPrefixedRead = true
                              }
                            }
                            case _ -> {
                            }
                          }
                        }
                        case _ -> {
                        }
                      }
                    }
                    case _ -> {
                    }
                  }
                  j = j + 1
                }
              }
              case _ -> {
              }
            }
          }
          case _ -> {
          }
        }
        i = i + 1
      }
    }
    case _ -> {
    }
  }
  assertTrue(sawPrefixedRead, "spliced config field access follows the alias-prefixed name")
  // Direct field access in a spliced init (`Files.root`) must follow the
  // hoisted name too — the exact #5278 dangling-reference shape.
  val bannerInit = findLocalInit(w, "__incl_Core_banner")
  var bannerRecv = ""
  match bannerInit.kind {
    case EMember(recv, _) -> {
      match recv.kind {
        case EPath(p) -> {
          bannerRecv = p.segments[p.segments.count - 1]
        }
        case _ -> {
        }
      }
    }
    case _ -> {
    }
  }
  assertEqual(bannerRecv, "Core_Files", "direct spliced field access renamed to the hoisted instance")
}

test "config-instance name colliding with a wire binding is W0024" {
  val src = "package P\n" + "pub config T { root: String = \"a\" }\n" + "wire W {\n" +
    "  singleton Files: String = \"occupied\"\n" +
    "  config Files from T {\n" +
    "    root: String = \"b\"\n" +
    "  }\n" +
    "  expose Files\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0024"), "config-instance name collision reported (#5279)")
}

test "overridable in a non-template wire warns W0026" {
  val src = "package P\n" + "record R { v: Int }\n" + "wire W {\n" + "  singleton r: R = R(v = 1)\n" +
    "  overridable r\n" +
    "  expose r\n" +
    "}\n"
  val res = expandSrc(src)
  assertTrue(hasDiag(res, "W0026"), "overridable outside a template warns (#5281)")
}

test "sealed collection rejects remove and reorder adjustments with W0023" {
  val lib = "package Web\n" + "record C { tag: String }\n" + "interface Mw { func wrap(x: in Int): Int }\n" +
    "pub wire Sealed {\n" +
    "  sealed contributes[Mw] auth = C(tag = \"auth\")\n" +
    "  contributes[Mw] log = C(tag = \"log\")\n" +
    "  singleton r: C = C(tag = \"r\")\n" +
    "  expose r\n" +
    "  overridable auth\n" +
    "}\n"
  val appRemove = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.Sealed {\n" + "    remove auth\n" +
    "  }\n" +
    "  expose r\n" +
    "}\n"
  val resRemove = expandTwo(lib, appRemove)
  assertTrue(hasDiag(resRemove, "W0023"), "sealed remove rejected (#5282)")
  val appReorder = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.Sealed {\n" +
    "    reorder auth inside: log\n" +
    "  }\n" +
    "  expose r\n" +
    "}\n"
  val resReorder = expandTwo(lib, appReorder)
  assertTrue(hasDiag(resReorder, "W0023"), "sealed reorder rejected (#5282)")
}

test "nested-include exposed name is reachable even when the middle template does not re-expose it" {
  // Documents the D121 Decision-3 v1 looseness (#5283): inclusion
  // flattens into one scope, so Inner's exposed name lands bare in the
  // outermost consumer although Outer never re-exposes it.
  val lib = "package Web\n" + "record R { v: Int }\n" + "record S { v: Int }\n" + "pub wire Inner {\n" +
    "  singleton innerVal: S = S(v = 7)\n" +
    "  expose innerVal\n" +
    "}\n" +
    "pub wire Outer {\n" +
    "  include Web.Inner\n" +
    "  singleton outerVal: R = R(v = 1)\n" +
    "  expose outerVal\n" +
    "}\n"
  val app = "package App\n" + "import Web\n" + "wire Prod {\n" + "  include Web.Outer\n" + "  expose outerVal\n" + "}\n"
  val res = expandTwo(lib, app)
  assertEqualInt(diagCount(res), 0, "no diagnostics")
  val w = firstWire(res, "Prod")
  assertTrue(hasMemberNamed(w, "innerVal"), "nested exposed name reachable bare (documented v1 looseness)")
}
