//! An `impl` method's body is verified like a function's, with the receiver
//! `self` a parameter and the impl's type parameters in scope: the
//! assertion in `Pen.pig` fails for a pen with `n <= 1000`, and `lyric
//! prove` refutes it instead of proving only the free functions (#8231).
@proof_required
package ImplMethod

interface Pig {
  func pig(self: in Self): Int
}

record Pen {
  n: Int
}

impl Pig for Pen {
  func pig(self: in Pen): Int
    ensures: result > 100
  {
    assert(self.n > 1000)
    self.n
  }
}

func lone(x: in Int): Int
  requires: x > 0
  ensures: result > 0
{
  x
}
