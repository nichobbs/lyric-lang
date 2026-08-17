//! chained_elem_jvm_self_test.l — runtime regression suite for #6493:
//! chained generic-field element access (`infos[0].arguments[0].name`),
//! where the inner list's receiver is an EXPRESSION (an indexed element's
//! field), not a variable, so the variable-keyed element typing
//! (docs/59 §4.3, #4938) cannot apply.  `staticBaseClass`'s EIndex arm
//! resolves the indexed base's element class through
//! `indexedElemTypeOverride`, making the `elem:<class>#<field>` registry
//! (#5444) reachable link by link for arbitrarily deep chains.  This was
//! the last lyric-mcp JVM blocker (mcp_serialization_tests.l).
@test_module
package Lyric.ChainedElemSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record ArgInfo {
  name: String
  required: Bool
}

record PromptInfo {
  name: String
  arguments: List[ArgInfo]
}

record Catalog {
  prompts: List[PromptInfo]
}

func mkInfos(): List[PromptInfo] {
  val args: List[ArgInfo] = newList()
  args.add(ArgInfo(name = "who", required = false))
  args.add(ArgInfo(name = "tone", required = true))
  val infos: List[PromptInfo] = newList()
  infos.add(PromptInfo(name = "greet", arguments = args))
  infos
}

test "chained element access through a variable-keyed outer list (#6493)" {
  val infos = mkInfos()
  assertEqual(infos[0].name, "greet", "outer element field (pre-existing path)")
  assertEqual(infos[0].arguments[0].name, "who", "inner element field through the chained index")
  assertFalse(infos[0].arguments[0].required, "inner element Bool field")
  assertTrue(infos[0].arguments[1].required, "second inner element")
}

test "three-link chain through a record field (#6493)" {
  val cat = Catalog(prompts = mkInfos())
  val c: List[Catalog] = newList()
  c.add(cat)
  assertEqual(c[0].prompts[0].arguments[1].name, "tone", "three chained index links resolve")
}
