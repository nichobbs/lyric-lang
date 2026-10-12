//! Imports a dependency that is not built: the build cannot type-check it,
//! so `lyric prove` stops and says to build or restore it first (#8227).
@proof_required
package App

import Mylib

func twice(n: in Int): Int
  requires: n >= 0 and n <= 1000
  ensures: result == n * 2
{
  n * 2
}

func useIt(): Int {
  Mylib.eight()
}
