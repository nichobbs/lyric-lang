//! Proved with the standard library's `Option` modelled.
@proof_required
package P

func f(n: in Int): Option[Int]
  ensures: result.isSome implies result.value == n
{
  Some(n)
}
