//! Type-checks only where `extraLimit` exists: `lyric prove` refuses it
//! as a build without the feature does, and proves it with `--features extra` (#8227).
@proof_required
package P

func twice(n: in Int): Int
  requires: n >= 0 and n <= 1000
  ensures: result == n * 2
{
  n * 2
}

func limit(): Int {
  extraLimit()
}
