//! `Err` is the prelude's case, not a binding that matches every value:
//! `g(Ok(1))` returns false, and the postcondition is not proved (#8230).
@proof_required
package BareErr

pub func g(r: in Result[Int, String]): Bool
  ensures: result
{
  match r {
    case Err -> true
    case _ -> false
  }
}
