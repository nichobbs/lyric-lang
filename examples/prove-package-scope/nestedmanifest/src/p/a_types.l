//! The outer manifest's package directory holds a project of its own
//! (`inner/lyric.toml`); the outer build still merges `inner/b_logic.l`,
//! so this `Option` is in scope there (#8108).
package P

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
