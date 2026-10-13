//! A false claim about a generic record's field is refuted, not reported
//! as untranslatable (#8340).
@proof_required
package BoxesRefuted

pub record Box[T] {
  n: Int
  v: T
}

pub func big[T](b: in Box[T]): Int
  ensures: result > 100
{
  b.n
}
