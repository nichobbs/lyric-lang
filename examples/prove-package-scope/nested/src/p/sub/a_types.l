//! The build reads a package directory recursively: this nested file's
//! `Option` is in scope in `../b_logic.l` (#8108).
package P

record Option[T] {
  isSome: Bool
  value: T
}

func main(): Unit {
  println(toString(f(Option(isSome = false, value = 1), Option(isSome = false, value = 2))))
}
