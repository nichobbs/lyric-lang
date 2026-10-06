//! A file of entry P that declares another package.  The build rejects it
//! (B0013, #8234); `lyric prove` still counts its types in P's scope, so
//! this `Option` is not taken for the standard library's in `b_logic.l`
//! (#8108).
package Q

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
