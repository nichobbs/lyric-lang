//! A postcondition that depends on a `match` whose arms the verifier does
//! not model — a constructor pattern and bare cases of a union another file
//! declares — is not proved: `lyric prove` reports V0027 at the goal and
//! fails, where it used to discharge `ensures: result` although `f(Other)`
//! returns false (#8230).
@proof_required
package P

pub func f(o: in Opt): Bool
  ensures: result
{
  match o {
    case Has(_) -> true
    case Nothing -> true
    case Other -> false
  }
}

// The match's value reaches no obligation here, so it is proved.
pub func label(o: in Opt): Int {
  match o {
    case Has(_) -> 1
    case Nothing -> 2
    case Other -> 3
  }
}
