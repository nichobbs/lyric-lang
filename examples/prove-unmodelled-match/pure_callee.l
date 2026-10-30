//! A `@pure` function whose value comes from a match the verifier does not
//! model is not unfolded at its calls, so `a`'s postcondition, which needs
//! its body, is reported as V0027 — not refuted with a counterexample the
//! body would rule out (#8230).
@proof_required
package PureCallee

pub union Shape {
  case Circle(r: Int)
  case Square(s: Int)
}

@pure
func pick(s: in Shape): Int {
  match s {
    case Circle(_) -> 1
    case Square(_) -> 2
  }
}

pub func a(s: in Shape): Int
  ensures: result == 1
{
  pick(s)
}
