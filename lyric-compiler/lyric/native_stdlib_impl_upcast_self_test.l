//! native_stdlib_impl_upcast_self_test.l - a record whose `impl` lives in a
//! bundled stdlib package, constructed in user code and upcast to the
//! interface, gets its vtable on --target native.
//!
//! A bundled package's impl is lowered only once reachable code constructs
//! its record, and the reachability walk matched the construction's call key
//! only as written in the record's own package or fully qualified
//! (`Std.Plugin.GrantAllRequested()`). From another package the record is
//! usually named without its package, so the impl was never lowered and
//! codegen failed with "no vtable registered for record
//! 'Std.Plugin.GrantAllRequested' implementing interface
//! 'Std.Plugin.GrantPolicy'". The walk now also resolves the name against the
//! caller's direct imports.
//!
//! Every construction here is unqualified, and no user code calls the
//! interface's method: either of those would make the impl reachable by
//! another route and hide the bug. The policy runs inside `registerPlugin`.
@test_module
package Lyric.NativeStdlibImplUpcastSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Plugin

val pointId: String = "Acme.Api.Tool"

func manifest(): PluginManifest {
  val points: List[PluginPointDecl] = newList()
  points.add(PluginPointDecl(point = pointId, version = "1.0", contributions = None))
  val here = currentPluginPlatform()
  val payloads: List[PluginPayload] = newList()
  payloads.add(NativePayload(os = here.os, arch = here.arch, command = ["bin/tool"]))
  PluginManifest(
    id = "acme.tool",
    version = "1.0.0",
    publisher = "acme",
    points = points,
    required = newList(),
    optional = newList(),
    payloads = payloads
  )
}

func hostPoints(): List[PluginPointInfo] {
  val points: List[PluginPointInfo] = newList()
  points.add(
    PluginPointInfo(id = pointId, version = "1.0", allows = newList(), hasContributions = false, protocol = None)
  )
  points
}

func registers(host: in PluginHost): Bool {
  match registerPlugin(host, manifest(), "/plugins/acme") {
    case Some(issue) -> {
      assertTrue(false, "unexpected issue: " + pluginLoadIssueMessage(issue))
      false
    }
    case None -> pluginManifests(host).count == 1
  }
}

test "an unqualified stdlib record passed straight into an interface-typed field" {
  val host = newPluginHost(PluginHostConfig(points = hostPoints(), providers = newList(), policy = GrantAllRequested()))
  assertTrue(registers(host), "the policy granted the plugin")
}

test "an unqualified stdlib record bound to an interface-typed val" {
  val policy: GrantPolicy = GrantAllRequested()
  val cfg = PluginHostConfig(points = hostPoints(), providers = newList(), policy = policy)
  assertTrue(registers(newPluginHost(cfg)), "the policy granted the plugin")
}
