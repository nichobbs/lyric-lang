//! A file of entry P that declares another package.  The build rejects it
//! (B0013, #8234), and so does `lyric prove`: it proves nothing of a package
//! that does not build (#8227).  Were the package proved, this `Option`
//! would count in P's scope, so `b_logic.l`'s would not be taken for the
//! standard library's (#8108).
package Q

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
