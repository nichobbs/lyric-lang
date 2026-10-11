//! Type-checks only where `platformLimit` exists: `lyric prove` refuses it
//! as a dotnet build does, and proves it with `--target jvm` (#8227).
@proof_required
package P

func twice(n: in Int): Int
  requires: n >= 0 and n <= 1000
  ensures: result == n * 2
{
  n * 2
}

func limit(): Int {
  platformLimit()
}
