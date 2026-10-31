//! A `@proof_required` contract that calls an imported function (#7532): the
//! callee is the function applied to its arguments, with its `@pure` body,
//! not a value of a sort the verifier does not know.
@proof_required
package ProveImportedCallees

import Std.Core
import Std.String

pub func lastIndex(s: in String): Int
  requires: not Std.String.isEmpty(s)
  ensures: result >= 0
{
  s.length - 1
}

pub func present(x: in Int): Option[Int]
  ensures: isSome(result)
{
  Some(x)
}

pub func emptyIsEmpty(s: in String): Bool
  requires: s.length == 0
  ensures: result
{
  Std.String.isEmpty(s)
}
