//! Sound on its own; `lyric prove` still refuses it, since its package does
//! not type-check.
@proof_required
package P

func twice(n: in Int): Int
  requires: n >= 0 and n <= 1000
  ensures: result == n * 2
{
  n * 2
}
