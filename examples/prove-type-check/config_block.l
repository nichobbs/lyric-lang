//! A program with a `config { }` block, which every target compiles.
//! `lyric prove --target native` checks it with the native bridge's own front
//! end (#8311).
@proof_required
package ConfigBlockUse

config Settings {
  port: Int = 8080
}

func pick(x: in Int): Int
  requires: x != 0
  ensures: result == x
{
  x
}
