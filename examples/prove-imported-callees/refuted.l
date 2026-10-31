//! The imported callee's body is what the proof assumes: nothing makes `s`
//! empty here, so the claim is false and is refuted, not discharged.
@proof_required
package ProveImportedCalleesRefuted

import Std.Core
import Std.String

pub func claimsEmpty(s: in String): Bool
  ensures: result
{
  Std.String.isEmpty(s)
}
